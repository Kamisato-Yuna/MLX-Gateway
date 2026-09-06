import Foundation

enum ResponsesClientError: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum ResponsesClientOperation: String, CaseIterable, Identifiable, Sendable {
    case create, retrieve, inputItems, cancel, delete
    var id: String { rawValue }
    var title: String {
        switch self {
        case .create: "发送请求"
        case .retrieve: "GET 响应"
        case .inputItems: "GET input_items"
        case .cancel: "请求服务端取消"
        case .delete: "DELETE 响应"
        }
    }
}

struct ResponsesClientRequest: Sendable {
    var baseURL: String
    var apiKey: String
    var operation: ResponsesClientOperation
    var body: String
    var responseID: String
    var after: String = ""
    var timeout: TimeInterval = 180

    func urlRequest() throws -> URLRequest {
        guard timeout.isFinite, (1...3600).contains(timeout) else {
            throw ResponsesClientError.message("超时必须在 1～3600 秒之间。")
        }
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw ResponsesClientError.message("填写完整 HTTP(S) API 基址（通常以 /v1 结尾），不要包含密钥、查询参数或片段。")
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        path += "/responses"
        if operation != .create {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
            guard !responseID.isEmpty, responseID.unicodeScalars.allSatisfy(allowed.contains) else {
                throw ResponsesClientError.message("响应 ID 只能包含字母、数字、下划线或连字符。")
            }
            path += "/" + responseID
            if operation == .inputItems { path += "/input_items" }
            if operation == .cancel { path += "/cancel" }
        }
        components.percentEncodedPath = path
        if operation == .inputItems {
            components.queryItems = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "order", value: "asc")]
            if !after.isEmpty { components.queryItems?.append(URLQueryItem(name: "after", value: after)) }
        }
        guard let url = components.url else { throw ResponsesClientError.message("API 基址无效。") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = operation == .delete ? "DELETE" : (operation == .create || operation == .cancel ? "POST" : "GET")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.contains("\r"), !key.contains("\n") else { throw ResponsesClientError.message("API key 不应包含换行。") }
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if operation == .create {
            guard body.utf8.count <= 32 * 1024 * 1024 else { throw ResponsesClientError.message("请求超过 32 MiB，请使用 file_id 或较小的输入。") }
            _ = try ResponsesTestJSON.object(body)
            // Send the user's exact JSON bytes: unknown extension fields are intentionally preserved.
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

struct ResponsesClientEvent: Identifiable, Sendable {
    let id: Int
    let name: String
    let serverID: String?
    let data: String
    var elapsed: Double = 0
}

enum ResponsesClientUpdate: Sendable {
    case headers(status: Int, contentType: String, requestID: String?)
    case batch(raw: Data, events: [ResponsesClientEvent])
}

struct ResponsesClient: Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumEvents = 10_000

    // Injecting an ephemeral fixture session supports tests without contacting a model.
    var configuration: URLSessionConfiguration = .ephemeral

    func perform(_ input: ResponsesClientRequest,
                 onUpdate: @escaping @Sendable (ResponsesClientUpdate) async -> Void) async throws {
        let request = try input.urlRequest()
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = input.timeout
        config.timeoutIntervalForResource = input.timeout
        let session = URLSession(configuration: config, delegate: ResponsesClientRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let started = ProcessInfo.processInfo.systemUptime
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ResponsesClientError.message("端点未返回 HTTP 响应。") }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        await onUpdate(.headers(status: http.statusCode, contentType: contentType,
                                requestID: http.value(forHTTPHeaderField: "x-request-id")))
        let streaming = contentType.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "text/event-stream"
        var parser = ResponsesClientSSEParser()
        var raw = Data()
        var events: [ResponsesClientEvent] = []
        var count = 0
        var eventCount = 0
        var lastUpdate = started
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard count < Self.maximumBytes else {
                    throw ResponsesClientError.message("响应达到 8 MiB 接收上限，已断开本地接收；保留此前原始数据。服务端是否停止未知。")
                }
                count += 1
                raw.append(byte)
                if streaming, var event = try parser.append(byte) {
                    event.elapsed = ProcessInfo.processInfo.systemUptime - started
                    eventCount += 1
                    guard eventCount <= Self.maximumEvents else {
                        throw ResponsesClientError.message("事件达到 10,000 条接收上限，已断开本地接收；服务端是否停止未知。")
                    }
                    events.append(event)
                }
                let now = ProcessInfo.processInfo.systemUptime
                // Dispatch a complete event immediately even if the server goes idle next.
                if !events.isEmpty || raw.count >= 32_768 || now - lastUpdate >= 0.05 {
                    await onUpdate(.batch(raw: raw, events: events))
                    raw.removeAll(keepingCapacity: true)
                    events.removeAll(keepingCapacity: true)
                    lastUpdate = now
                }
            }
            // SSE requires a blank line to dispatch. Never promote a partial EOF event to success.
            await onUpdate(.batch(raw: raw, events: events))
            raw.removeAll()
            events.removeAll()
            try Task.checkCancellation()
        } catch {
            await onUpdate(.batch(raw: raw, events: events))
            throw error
        }
    }
}

private final class ResponsesClientRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Report the original 3xx; never forward an in-memory key to another endpoint implicitly.
        completionHandler(nil)
    }
}
