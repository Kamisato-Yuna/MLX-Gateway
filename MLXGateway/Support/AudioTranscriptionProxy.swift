import Foundation
import CoreFoundation

/// A redirect must not silently submit a transcription to a second endpoint.
private final class AudioRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Forwards multipart uploads to a separately started, OpenAI-compatible STT service.
/// The gateway does not start or switch an inference model for an API request.
final class AudioTranscriptionProxy: @unchecked Sendable {
    struct Configuration: Codable, Equatable, Sendable {
        let baseURL: URL
        var model: String = "whisper-1"
        var timeout: TimeInterval = 180
        var displayName: String?
        var launchScript: String?

        var title: String { displayName?.isEmpty == false ? displayName! : model }

        static func fileURL(runtimeDirectory: String) -> URL {
            URL(fileURLWithPath: runtimeDirectory).appendingPathComponent("audio-service/gateway.json")
        }

        static var saved: Configuration? {
            load(runtimeDirectory: RuntimePaths.saved.directory)
        }

        static func load(runtimeDirectory: String) -> Configuration? {
            let path = fileURL(runtimeDirectory: runtimeDirectory)
            guard let data = try? Data(contentsOf: path),
                  let config = try? JSONDecoder().decode(Self.self, from: data),
                  ["http", "https"].contains(config.baseURL.scheme),
                  config.baseURL.host != nil, config.baseURL.user == nil,
                  config.baseURL.password == nil, config.baseURL.query == nil,
                  config.baseURL.fragment == nil, config.timeout > 0,
                  config.timeout.isFinite, !config.model.isEmpty else { return nil }
            return config
        }
    }

    enum Availability: Sendable { case unavailable, available, loaded }
    private let lock = NSLock()
    private var currentConfiguration: Configuration?
    var configuration: Configuration? { lock.withLock { currentConfiguration } }
    private let session: URLSession
    private let redirectPolicy = AudioRedirectPolicy()
    var enabled: Bool { configuration != nil }
    var modelDescription: [String: Any]? {
        guard let configuration else { return nil }
        return ["id": configuration.model, "object": "model", "created": 0,
                "owned_by": "local", "backend": "openai-compatible-stt",
                "capabilities": ["audio_transcription"],
                "endpoints": ["/v1/audio/transcriptions", "/audio/transcriptions"],
                "response_formats": ["json", "text", "verbose_json", "vtt"]]
    }

    init(configuration: Configuration? = .saved) {
        self.currentConfiguration = configuration
        let transport = URLSessionConfiguration.ephemeral
        transport.httpShouldSetCookies = false
        transport.urlCache = nil
        session = URLSession(configuration: transport, delegate: redirectPolicy, delegateQueue: nil)
    }

    func configure(_ configuration: Configuration?) { lock.withLock { currentConfiguration = configuration } }

    func availability(configuration: Configuration, timeout: TimeInterval = 3) async -> Availability {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("models"))
        request.timeoutInterval = min(timeout, configuration.timeout)
        let probe = request
        do {
            return try await withThrowingTaskGroup(of: Availability.self) { group in
                group.addTask {
                    let (data, response) = try await self.session.data(for: probe)
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          let models = JSONSupport.object(from: data)?["data"] as? [[String: Any]] else { return .unavailable }
                    return models.contains { $0["id"] as? String == configuration.model } ? .loaded : .available
                }
                // A slow response must not extend the wall-clock wait by trickling bytes.
                group.addTask {
                    try await Task.sleep(for: .seconds(min(timeout, configuration.timeout)))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                return try await group.next() ?? .unavailable
            }
        } catch { return .unavailable }
    }

    @discardableResult
    func forward(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResponse) -> Void) -> BackendRequestCancellation {
        let cancellation = BackendRequestCancellation()
        guard let configuration else {
            completion(.error(statusCode: 404, message: "Audio transcription is not configured.", code: "not_found"))
            return cancellation
        }
        guard let contentType = request.headers["content-type"],
              contentType.lowercased().hasPrefix("multipart/form-data;"),
              contentType.lowercased().contains("boundary=") else {
            completion(.error(statusCode: 400, message: "Use multipart/form-data with a boundary, file and model.", code: "bad_request"))
            return cancellation
        }
        let upload: PreparedUpload
        do { upload = try preparedBody(request.body, contentType: contentType, model: configuration.model) }
        catch let error as ResponsesAdapter.InvalidRequest { completion(error.response); return cancellation }
        catch { completion(.error(statusCode: 400, message: "Invalid multipart upload.", code: "bad_request")); return cancellation }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + min(12, configuration.timeout)
        let waitingCancellation = BackendRequestCancellation()
        let transportCancellation = BackendRequestCancellation()
        cancellation.install { waitingCancellation.cancel(); transportCancellation.cancel() }
        let waiting = Task {
            while !Task.isCancelled {
                guard self.configuration == configuration else {
                    completion(.error(statusCode: 409, message: "Audio configuration changed while waiting; no transcription was submitted.", code: "audio_configuration_changed")); return
                }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { completion(Self.readinessExpired()); return }
                let state = await availability(configuration: configuration, timeout: min(2, remaining))
                guard !Task.isCancelled else { return }
                if state == .loaded {
                    guard self.configuration == configuration else { continue }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { completion(Self.readinessExpired()); return }
                    let requestRemaining = configuration.timeout - (ProcessInfo.processInfo.systemUptime - started)
                    guard requestRemaining > 0 else { completion(Self.readinessExpired()); return }
                    // Only GET probes repeat. After this handoff a POST is attempted once.
                    send(upload: upload, contentType: contentType, configuration: configuration,
                         timeout: requestRemaining, cancellation: transportCancellation, completion: completion)
                    return
                }
                let pause = min(0.2, max(0, deadline - ProcessInfo.processInfo.systemUptime))
                do { try await Task.sleep(for: .seconds(pause)) } catch { return }
            }
        }
        waitingCancellation.install { waiting.cancel() }
        return cancellation
    }

    private static func readinessExpired() -> HTTPResponse {
        let error = HTTPResponse.error(statusCode: 503, message: "Audio backend did not become ready within the bounded wait. No transcription was submitted.", code: "audio_backend_not_ready")
        return HTTPResponse(statusCode: error.statusCode, reason: error.reason,
                            headers: error.headers.merging(["Retry-After": "1"]) { _, new in new }, body: error.body)
    }

    private struct PreparedUpload: Sendable { let body: Data; var vtt = false }

    private func send(upload: PreparedUpload, contentType: String, configuration: Configuration,
                      timeout: TimeInterval, cancellation: BackendRequestCancellation,
                      completion: @escaping @Sendable (HTTPResponse) -> Void) {
        var upstream = URLRequest(url: configuration.baseURL.appendingPathComponent("audio/transcriptions"))
        upstream.httpMethod = "POST"
        upstream.httpBody = upload.body
        upstream.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // Only upload bytes and required content headers. Client credentials stay at the gateway.
        upstream.timeoutInterval = timeout
        let task = session.dataTask(with: upstream) { data, response, error in
            guard error == nil, let response = response as? HTTPURLResponse else {
                completion(.error(statusCode: 502, message: "Audio transcription transport failed. The result may be unknown; the POST was not retried.", code: "audio_backend_unavailable"))
                return
            }
            if upload.vtt, (200..<300).contains(response.statusCode) {
                guard let vtt = Self.webVTT(from: data ?? Data()) else {
                    completion(.error(statusCode: 502, message: "Whisper did not return valid segment timestamps for WebVTT.", code: "audio_timestamps_unavailable")); return
                }
                completion(HTTPResponse(statusCode: response.statusCode, reason: "OK",
                                        headers: ["Content-Type": "text/vtt; charset=utf-8"], body: Data(vtt.utf8)))
                return
            }
            var headers: [String: String] = [:]
            if let value = response.value(forHTTPHeaderField: "Content-Type") { headers["Content-Type"] = value }
            if let value = response.value(forHTTPHeaderField: "Retry-After") { headers["Retry-After"] = value }
            completion(HTTPResponse(statusCode: response.statusCode,
                                    reason: HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                                    headers: headers, body: data ?? Data()))
        }
        cancellation.install { task.cancel() }
        task.resume()
    }

    /// Read form headers and small fields without decoding or changing audio bytes.
    private func preparedBody(_ body: Data, contentType: String, model: String) throws -> PreparedUpload {
        let parameters = contentType.split(separator: ";").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        guard let parameter = parameters.first(where: { $0.lowercased().hasPrefix("boundary=") }) else {
            throw ResponsesAdapter.invalid("Multipart boundary is required.", "file")
        }
        let boundary = String(parameter.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !boundary.isEmpty, boundary.utf8.count <= 70,
              boundary.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
            throw ResponsesAdapter.invalid("Invalid multipart boundary.", "file")
        }
        let delimiter = Data("--\(boundary)".utf8)
        let separator = Data("\r\n--\(boundary)".utf8)
        guard body.starts(with: delimiter) else { throw ResponsesAdapter.invalid("Malformed multipart upload.", "file") }
        var cursor = delimiter.count
        var fields: [String: Data] = [:]
        var formatRange: Range<Data.Index>?
        while true {
            guard body.count >= cursor + 2 else { throw ResponsesAdapter.invalid("Incomplete multipart upload.", "file") }
            if body[cursor..<(cursor + 2)] == Data("--".utf8) { break }
            guard body[cursor..<(cursor + 2)] == Data("\r\n".utf8),
                  let end = body.range(of: Data("\r\n\r\n".utf8), in: (cursor + 2)..<body.count),
                  end.lowerBound - cursor <= 16_384,
                  let header = String(data: body[(cursor + 2)..<end.lowerBound], encoding: .utf8),
                  let disposition = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-disposition:") }),
                  let namePart = disposition.components(separatedBy: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("name=\"") && $0.hasSuffix("\"") }),
                  let next = body.range(of: separator, in: end.upperBound..<body.count) else {
                throw ResponsesAdapter.invalid("Malformed multipart field.", "file")
            }
            let name = String(namePart.dropFirst(6).dropLast())
            guard fields[name] == nil else { throw ResponsesAdapter.invalid("Duplicate multipart field.", name) }
            guard ["file", "model", "language", "response_format"].contains(name) else {
                throw ResponsesAdapter.unsupported("This audio backend does not support this field.", name)
            }
            fields[name] = Data(body[end.upperBound..<next.lowerBound])
            if name == "response_format" { formatRange = end.upperBound..<next.lowerBound }
            cursor = next.upperBound
        }
        guard let file = fields["file"], !file.isEmpty else { throw ResponsesAdapter.invalid("Upload a non-empty audio file.", "file") }
        guard fields["model"] == Data(model.utf8) else { throw ResponsesAdapter.invalid("Unknown transcription model.", "model") }
        if let format = fields["response_format"] {
            let value = String(decoding: format, as: UTF8.self)
            guard ["json", "text", "verbose_json", "vtt"].contains(value) else {
                throw ResponsesAdapter.unsupported("Use json, text, verbose_json or vtt.", "response_format")
            }
            if value == "vtt", let formatRange {
                var rewritten = body
                rewritten.replaceSubrange(formatRange, with: Data("verbose_json".utf8))
                return PreparedUpload(body: rewritten, vtt: true)
            }
            return PreparedUpload(body: body)
        }
        // mlx-audio defaults to NDJSON; OpenAI clients expect a JSON object by default.
        var normalized = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8)
        normalized.append(body)
        return PreparedUpload(body: normalized)
    }

    /// Build cues only from Whisper's measured segments. Missing timing is an error.
    static func webVTT(from data: Data) -> String? {
        guard let object = JSONSupport.object(from: data), let segments = object["segments"] as? [[String: Any]] else { return nil }
        if segments.isEmpty, let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        var result = "WEBVTT\n\n"
        for (index, segment) in segments.enumerated() {
            guard let startValue = segment["start"] as? NSNumber, let endValue = segment["end"] as? NSNumber,
                  CFGetTypeID(startValue) != CFBooleanGetTypeID(), CFGetTypeID(endValue) != CFBooleanGetTypeID() else { return nil }
            let start = startValue.doubleValue, end = endValue.doubleValue
            guard
                  start.isFinite, end.isFinite, start >= 0, end > start,
                  end * 1000 < Double(Int.max), let text = segment["text"] as? String else { return nil }
            let first = Int((start * 1000).rounded()), last = Int((end * 1000).rounded())
            guard last > first else { return nil }
            let escaped = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: "\n")
            if !escaped.isEmpty { result += "\(index + 1)\n\(timestamp(first)) --> \(timestamp(last))\n\(escaped)\n\n" }
        }
        return result
    }

    private static func timestamp(_ milliseconds: Int) -> String {
        String(format: "%02lld:%02lld:%02lld.%03lld", milliseconds / 3_600_000,
               milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
