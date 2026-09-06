import Foundation
import Darwin

struct BackendStatus: Equatable, Sendable {
    enum State: String, Sendable { case stopped, starting, ready, stopping, failed }
    var state: State = .stopped
    var modelID: String?
    var backend: String?
    var pid: Int32?
    var message = "选择一个模型，然后启动 MLX 服务。"

    var title: String {
        switch state {
        case .stopped: return "已停止"
        case .starting: return "正在加载"
        case .ready: return "服务就绪"
        case .stopping: return "正在停止"
        case .failed: return "启动失败或异常退出"
        }
    }

    var publicDescription: [String: Any] {
        ["state": state.rawValue, "active_model": modelID as Any? ?? NSNull(),
         "backend": backend as Any? ?? NSNull(), "pid": pid as Any? ?? NSNull(),
         "running": pid != nil, "ready": state == .ready]
    }
}

// Process, endpoint, requests and handles are confined to queue; status uses statusLock.
final class BackendManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.kamisato-yuna.MLXGateway.backend")
    private let statusLock = NSLock()
    private let session = URLSession(configuration: .ephemeral)
    private var currentStatus = BackendStatus()
    private var process: Process?
    private var outputHandle: FileHandle?
    private var readinessTask: URLSessionDataTask?
    private var requests: [Int: URLSessionDataTask] = [:]
    private var streams: [UUID: BackendRequestCancellation] = [:]
    private var endpoint: URL?
    private var activeModel: ModelSpec?
    private var pythonExecutable: String
    let logURL: URL

    init(pythonExecutable: String = RuntimePaths.saved.python, logURL: URL? = nil) {
        self.pythonExecutable = pythonExecutable
        self.logURL = logURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MLXGateway/backend.log")
    }

    var status: BackendStatus { statusLock.withLock { currentStatus } }

    private func publish(_ status: BackendStatus) {
        statusLock.withLock { currentStatus = status }
    }

    func configurePython(_ path: String) {
        queue.sync { pythonExecutable = path }
    }

    func start(model: ModelSpec, host: String, port: UInt16) {
        queue.async { [self] in
            if activeModel == model, endpoint == LocalEndpoint.url(host: host, port: port), process?.isRunning == true { return }
            stopLocked()
            publish(BackendStatus(state: .starting, modelID: model.id, backend: model.backend.rawValue,
                                  message: "正在启动并等待模型加载，首次启动可能需要几分钟。"))
            do {
                guard FileManager.default.isExecutableFile(atPath: pythonExecutable) else {
                    throw BackendError.message("找不到 MLX Python 环境，请检查本地安装。")
                }
                guard FileManager.default.fileExists(atPath: model.localPath + "/config.json") else {
                    throw BackendError.message("所选模型文件不完整，请检查本地模型目录。")
                }
                try LocalEndpoint.checkAvailable(host: host, port: port)
                try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                let fd = Darwin.open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw BackendError.message("无法打开本地服务日志。") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                outputHandle = handle
                log("启动 \(model.id) · \(model.backend.rawValue)")
                let child = Process()
                child.executableURL = URL(fileURLWithPath: pythonExecutable)
                child.arguments = ["-u", "-m", model.backend.moduleName, "--host", host, "--port", String(port), "--model", model.localPath]
                var environment = ProcessInfo.processInfo.environment
                environment["PYTHONUNBUFFERED"] = "1"
                environment["HF_HUB_OFFLINE"] = "1"
                child.environment = environment
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = handle
                child.standardError = handle
                child.terminationHandler = { [weak self] child in
                    guard let self else { return }
                    self.queue.async { self.didExit(child) }
                }
                try child.run()
                process = child
                activeModel = model
                endpoint = LocalEndpoint.url(host: host, port: port)
                publish(BackendStatus(state: .starting, modelID: model.id, backend: model.backend.rawValue,
                                      pid: child.processIdentifier, message: "正在加载模型，等待 MLX 健康检查。"))
                probe(child, deadline: Date().addingTimeInterval(180))
            } catch {
                log("启动失败：\(error.localizedDescription)")
                try? outputHandle?.close()
                outputHandle = nil
                publish(BackendStatus(state: .failed, modelID: model.id, backend: model.backend.rawValue,
                                      message: error.localizedDescription))
            }
        }
    }

    func stop() { queue.async { self.stopLocked() } }

    /// App termination waits for its own child only; UI start/stop never blocks the main thread.
    func shutdown() { queue.sync { stopLocked() } }

    private func stopLocked() {
        readinessTask?.cancel()
        readinessTask = nil
        streams.values.forEach { $0.cancel() }
        streams.removeAll()
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        if let child = process {
            var next = status
            next.state = .stopping
            next.message = "正在停止 MLX 服务并释放模型。"
            publish(next)
            child.terminationHandler = nil
            if child.isRunning {
                child.terminate()
                let deadline = Date().addingTimeInterval(3)
                while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            log("MLX 服务已停止")
        }
        process = nil
        endpoint = nil
        activeModel = nil
        try? outputHandle?.close()
        outputHandle = nil
        publish(BackendStatus())
    }

    private func didExit(_ child: Process) {
        guard process === child else { return }
        readinessTask?.cancel()
        streams.values.forEach { $0.cancel() }
        streams.removeAll()
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        log("MLX 服务退出，退出码 \(child.terminationStatus)")
        var next = status
        next.state = .failed
        next.pid = nil
        next.message = "MLX 服务已退出（\(child.terminationStatus)），请查看日志后重试。"
        process = nil
        endpoint = nil
        activeModel = nil
        try? outputHandle?.close()
        outputHandle = nil
        publish(next)
    }

    private func probe(_ child: Process, deadline: Date) {
        guard process === child, child.isRunning, let endpoint else { return }
        if Date() > deadline {
            stopLocked()
            publish(BackendStatus(state: .failed, message: "模型启动超时（180 秒），服务已停止，请查看日志。"))
            return
        }
        var request = URLRequest(url: endpoint.appendingPathComponent("health"))
        request.timeoutInterval = 2
        readinessTask = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                guard self.process === child, child.isRunning else { return }
                if error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                    var next = self.status
                    next.state = .ready
                    next.message = "MLX 已就绪，可以接收 Responses 请求。"
                    self.publish(next)
                    self.log("MLX 健康检查通过，服务就绪")
                } else {
                    self.queue.asyncAfter(deadline: .now() + 0.5) { self.probe(child, deadline: deadline) }
                }
            }
        }
        readinessTask?.resume()
    }

    @discardableResult
    func complete(modelID: String, chatData: Data, completion: @escaping @Sendable (HTTPResponse) -> Void) -> BackendRequestCancellation {
        let cancellation = BackendRequestCancellation()
        queue.async { [self] in
            guard let child = process, child.isRunning, status.state == .ready,
                  let model = activeModel, let endpoint else {
                completion(.error(statusCode: 503, message: "Start a model in MLX Gateway and wait until it is ready.", code: "backend_not_ready"))
                return
            }
            guard model.id == modelID else {
                completion(.error(statusCode: 409, message: "The requested model is not running. Select and start it in MLX Gateway.", code: "model_not_active"))
                return
            }
            var body = JSONSupport.object(from: chatData) ?? [:]
            // A short public ID could make MLX download/reload a different model.
            body["model"] = model.localPath
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = JSONSupport.data(from: body)
            request.timeoutInterval = 120
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                self.queue.async {
                    self.requests = self.requests.filter { $0.value.state == .running || $0.value.state == .suspended }
                    guard self.process === child, child.isRunning else {
                        completion(.error(statusCode: 503, message: "The MLX service stopped during this request.", code: "backend_stopped"))
                        return
                    }
                    guard error == nil, let response = response as? HTTPURLResponse else {
                        completion(.error(statusCode: 502, message: "MLX request failed or timed out. See local service logs.", code: "downstream_error"))
                        return
                    }
                    guard (200..<300).contains(response.statusCode) else {
                        // Backend errors can include private model paths. Keep the body local.
                        self.log("推理请求失败，MLX HTTP \(response.statusCode)")
                        completion(.error(statusCode: 502, message: "MLX returned an error. See local service logs.", code: "downstream_error"))
                        return
                    }
                    completion(HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: data ?? Data()))
                }
            }
            requests[task.taskIdentifier] = task
            cancellation.install { task.cancel() }
            task.resume()
        }
        return cancellation
    }

    @discardableResult
    func stream(modelID: String, chatData: Data, bytes: @escaping @Sendable (Data) -> Void,
                completion: @escaping @Sendable (HTTPResponse?) -> Void) -> BackendRequestCancellation {
        let cancellation = BackendRequestCancellation()
        queue.async { [self] in
            guard let child = process, child.isRunning, status.state == .ready,
                  let model = activeModel, let endpoint else {
                completion(.error(statusCode: 503, message: "Start a model in MLX Gateway and wait until it is ready.", code: "backend_not_ready")); return
            }
            guard model.id == modelID else {
                completion(.error(statusCode: 409, message: "Select and start the requested model in MLX Gateway.", code: "model_not_active")); return
            }
            var body = JSONSupport.object(from: chatData) ?? [:]
            body["model"] = model.localPath
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = JSONSupport.data(from: body)
            request.timeoutInterval = 120
            let id = UUID()
            streams[id] = cancellation
            let transfer = BackendStream(bytes: bytes) { [weak self] failure in
                guard let self else { return }
                self.queue.async {
                    self.streams.removeValue(forKey: id)
                    if self.process !== child || !child.isRunning {
                        completion(.error(statusCode: 503, message: "The MLX service stopped during this request.", code: "backend_stopped"))
                    } else { completion(failure) }
                }
            }
            transfer.start(request, cancellation: cancellation)
        }
        return cancellation
    }

    /// Truncate the existing inode. The child and gateway share an O_APPEND descriptor,
    /// so subsequent writes cannot leave a sparse hole after truncation.
    func clearLogs(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                if let handle = outputHandle { try handle.truncate(atOffset: 0) }
                else if FileManager.default.fileExists(atPath: logURL.path) {
                    let handle = try FileHandle(forWritingTo: logURL)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 0)
                }
                completion(.success(()))
            } catch { completion(.failure(BackendError.message("无法清空本地服务日志，请检查文件权限。"))) }
        }
    }

    private func log(_ message: String) {
        let line = "\n[MLX Gateway · \(Date().formatted(.iso8601))] \(message)\n"
        try? outputHandle?.write(contentsOf: Data(line.utf8))
    }

    func readLogTail() -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return "" }
        let start = end > 65_536 ? end - 65_536 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { return String(text[text.index(after: newline)...]) }
        return text
    }
}

enum BackendError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
