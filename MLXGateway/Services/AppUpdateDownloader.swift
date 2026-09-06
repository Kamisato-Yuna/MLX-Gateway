import Foundation

struct AppUpdateDownloader: Sendable {
    var maximumBytes: Int64 = AppUpdateArchive.maximumArchiveBytes
    var configuration: URLSessionConfiguration = .ephemeral

    func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await AppUpdateTransfer(request: URLRequest(url: url), configuration: configuration,
                                    maximumBytes: maximumBytes, progress: progress).run()
    }
}

/// A separate delegate owns each operation. Cancellation from an earlier request cannot finish a later one.
final class AppUpdateTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var finished = false
    private let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("MLXGateway-update-\(UUID().uuidString).zip")

    init(request: URLRequest, configuration: URLSessionConfiguration, maximumBytes: Int64,
         progress: @escaping @Sendable (Double) -> Void) {
        self.request = request
        self.configuration = configuration
        self.maximumBytes = maximumBytes
        self.progress = progress
    }

    func run() async throws -> URL {
        guard let url = request.url else { throw AppUpdateError.invalidURL }
        try AppUpdateURLPolicy.validateHTTPS(url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                do {
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                         attributes: [.posixPermissions: 0o600]) else {
                        throw AppUpdateError.processFailed("无法创建下载文件。")
                    }
                    file = try FileHandle(forWritingTo: destination)
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    self.session = session
                    session.dataTask(with: request).resume()
                    lock.unlock()
                } catch { lock.unlock(); finish(.failure(error)) }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, (try? AppUpdateURLPolicy.validateHTTPS(url)) != nil else {
            completionHandler(nil)
            finish(.failure(AppUpdateError.insecureURL))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let url = response.url else { throw AppUpdateError.invalidURL }
            try AppUpdateURLPolicy.validateHTTPS(url)
            guard let http = response as? HTTPURLResponse else { throw AppUpdateError.invalidHTTPStatus(0) }
            guard (200..<300).contains(http.statusCode) else { throw AppUpdateError.invalidHTTPStatus(http.statusCode) }
            guard response.expectedContentLength <= maximumBytes else { throw AppUpdateError.downloadTooLarge }
            lock.lock()
            expected = response.expectedContentLength
            let active = !finished
            lock.unlock()
            completionHandler(active ? .allow : .cancel)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard Int64(data.count) <= maximumBytes - received else {
            lock.unlock(); finish(.failure(AppUpdateError.downloadTooLarge)); return
        }
        do {
            try file?.write(contentsOf: data)
            received += Int64(data.count)
            let value = expected > 0 ? min(1, Double(received) / Double(expected)) : 0
            lock.unlock()
            progress(value)
        } catch { lock.unlock(); finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else { finish(.success(destination)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        var outcome = result
        do { try file?.close() } catch { outcome = .failure(error) }
        file = nil
        lock.unlock()
        session?.invalidateAndCancel()
        if case .failure = outcome { try? FileManager.default.removeItem(at: destination) }
        continuation?.resume(with: outcome)
    }
}

enum AppUpdateHTTPClient {
    static func data(for request: URLRequest, session: URLSession) async throws -> Data {
        // Metadata uses the same HTTPS redirect and streaming byte limits as ZIP downloads.
        let url = try await AppUpdateTransfer(request: request, configuration: session.configuration,
                                               maximumBytes: 2_097_152, progress: { _ in }).run()
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }
}
