import Foundation

/// Cancellation may arrive before the backend queue has created its URLSession task.
final class BackendRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (@Sendable () -> Void)?
    func install(_ action: @escaping @Sendable () -> Void) {
        let run = lock.withLock { if cancelled { return true }; self.action = action; return false }
        if run { action() }
    }
    func cancel() {
        let action = lock.withLock { cancelled = true; let value = self.action; self.action = nil; return value }
        action?()
    }
}

/// URLSessionDataDelegate delivers bytes as they arrive; no completion-handler buffering.
/// Mutable state below belongs to the serial delegate queue.
final class BackendStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var failure: HTTPResponse?
    private let bytes: @Sendable (Data) -> Void
    private let completion: @Sendable (HTTPResponse?) -> Void
    init(bytes: @escaping @Sendable (Data) -> Void, completion: @escaping @Sendable (HTTPResponse?) -> Void) {
        self.bytes = bytes; self.completion = completion
    }
    func start(_ request: URLRequest, cancellation: BackendRequestCancellation) {
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        cancellation.install { task.cancel() }
        task.resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            failure = .error(statusCode: 502, message: "MLX returned an error. See local service logs.", code: "downstream_error")
            completionHandler(.cancel); return
        }
        guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
            failure = .error(statusCode: 502, message: "MLX did not return an SSE stream.", code: "invalid_backend_stream")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { bytes(data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = failure ?? (error == nil ? nil : HTTPResponse.error(statusCode: 502, message: "MLX stream failed or was cancelled.", code: "downstream_error"))
        completion(result)
        session.finishTasksAndInvalidate()
        self.session = nil; self.task = nil
    }
}
