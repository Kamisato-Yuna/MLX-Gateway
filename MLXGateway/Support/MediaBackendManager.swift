import Foundation
import Darwin

/// Status of the media/decision backend (`mlx-serve` binary), mirroring `BackendStatus`.
struct MediaBackendStatus: Equatable, Sendable {
    enum State: String, Sendable { case stopped, starting, ready, stopping, failed }
    var state: State = .stopped
    var pid: Int32?
    var message = "媒体/决策后端未启用。"

    var ready: Bool { state == .ready }

    var publicDescription: [String: Any] {
        ["state": state.rawValue, "pid": pid as Any? ?? NSNull(), "running": pid != nil, "ready": state == .ready]
    }
}

/// Manages the lifecycle of the standalone `mlx-serve` binary that serves the 3D
/// (Hunyuan3D) and decision (Laya) endpoints. This intentionally does NOT reuse
/// `BackendManager`: media models cannot run under `mlx_lm` / `mlx_vlm`, so spawning
/// here uses the native `mlx-serve` executable with repeated `--model-dir` flags.
final class MediaBackendManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.kamisato-yuna.MLXGateway.media")
    private let statusLock = NSLock()
    private let session = URLSession(configuration: .ephemeral)
    private var currentStatus = MediaBackendStatus()
    private var process: Process?
    private var outputHandle: FileHandle?
    private var readinessTask: URLSessionDataTask?
    private var endpoint: URL?
    private var config: MediaGatewayConfig
    let logURL: URL

    init(config: MediaGatewayConfig = .default(), logURL: URL? = nil) {
        self.config = config
        self.logURL = logURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MLXGateway/media-backend.log")
    }

    var status: MediaBackendStatus { statusLock.withLock { currentStatus } }

    private func publish(_ status: MediaBackendStatus) {
        statusLock.withLock { currentStatus = status }
    }

    /// Whether the 3D route should be served (backend enabled), independent of ready state.
    var serve3D: Bool { config.enabled }

    /// Whether the decisions route should be served.
    var serveDecisions: Bool { config.enabled && config.decisionsEnabled }

    var baseURL: URL? { LocalEndpoint.url(host: config.host, port: config.port) }

    func update(config newConfig: MediaGatewayConfig) {
        queue.sync { config = newConfig }
    }

    func start() {
        queue.async { [self] in
            guard config.enabled else {
                publish(MediaBackendStatus(state: .stopped, message: "媒体/决策后端未启用。"))
                return
            }
            if process?.isRunning == true { return }
            stopLocked()
            publish(MediaBackendStatus(state: .starting, message: "正在启动 mlx-serve 并等待模型加载。"))
            do {
                guard FileManager.default.isExecutableFile(atPath: config.executablePath) else {
                    throw BackendError.message("找不到 mlx-serve 可执行文件：\\(config.executablePath)")
                }
                try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                let fd = Darwin.open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw BackendError.message("无法打开媒体后端日志。") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                outputHandle = handle
                log("启动 mlx-serve (port \\(config.port))")

                let child = Process()
                child.executableURL = URL(fileURLWithPath: config.executablePath)
                var args = ["--serve", "--host", config.host, "--port", String(config.port)]
                for dir in config.resolvedModelDirectories {
                    args.append("--model-dir")
                    args.append(dir)
                }
                child.arguments = args
                var environment = ProcessInfo.processInfo.environment
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
                endpoint = LocalEndpoint.url(host: config.host, port: config.port)
                publish(MediaBackendStatus(state: .starting, pid: child.processIdentifier,
                                           message: "正在加载模型，等待 mlx-serve 健康检查。"))
                probe(child, deadline: Date().addingTimeInterval(config.readinessTimeout))
            } catch {
                log("启动失败：\\(error.localizedDescription)")
                try? outputHandle?.close()
                outputHandle = nil
                publish(MediaBackendStatus(state: .failed, message: error.localizedDescription))
            }
        }
    }

    func stop() { queue.async { self.stopLocked() } }

    func shutdown() { queue.sync { stopLocked() } }

    private func stopLocked() {
        readinessTask?.cancel()
        readinessTask = nil
        if let child = process {
            var next = status
            next.state = .stopping
            next.message = "正在停止 mlx-serve。"
            publish(next)
            child.terminationHandler = nil
            if child.isRunning {
                child.terminate()
                let deadline = Date().addingTimeInterval(3)
                while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            log("mlx-serve 已停止")
        }
        process = nil
        endpoint = nil
        try? outputHandle?.close()
        outputHandle = nil
        publish(MediaBackendStatus())
    }

    private func didExit(_ child: Process) {
        guard process === child else { return }
        readinessTask?.cancel()
        log("mlx-serve 退出，退出码 \\(child.terminationStatus)")
        var next = status
        next.state = .failed
        next.pid = nil
        next.message = "mlx-serve 已退出（\\(child.terminationStatus)），请查看日志后重试。"
        process = nil
        endpoint = nil
        try? outputHandle?.close()
        outputHandle = nil
        publish(next)
    }

    private func probe(_ child: Process, deadline: Date) {
        guard process === child, child.isRunning, let endpoint else { return }
        if Date() > deadline {
            stopLocked()
            publish(MediaBackendStatus(state: .failed, message: "媒体后端启动超时，服务已停止，请查看日志。"))
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
                    next.message = "mlx-serve 已就绪。"
                    self.publish(next)
                    self.log("mlx-serve 健康检查通过")
                } else {
                    self.queue.asyncAfter(deadline: .now() + 0.5) { self.probe(child, deadline: deadline) }
                }
            }
        }
        readinessTask?.resume()
    }

    /// Proxy a media/decision request to the downstream `mlx-serve` service.
    /// `path` is the downstream path, e.g. "v1/3d/generations" or "v1/decisions".
    func forward(path: String, body: Data, completion: @escaping @Sendable (HTTPResponse) -> Void) {
        queue.async { [self] in
            guard let child = process, child.isRunning, status.state == .ready, let endpoint else {
                completion(.error(statusCode: 503, message: "Media/decision backend is not ready. Start it in MLX Gateway and wait.", code: "media_backend_not_ready"))
                return
            }
            var request = URLRequest(url: endpoint.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 300
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                self.queue.async {
                    guard self.process === child, child.isRunning else {
                        completion(.error(statusCode: 503, message: "The media backend stopped during this request.", code: "media_backend_stopped"))
                        return
                    }
                    guard error == nil, let response = response as? HTTPURLResponse else {
                        completion(.error(statusCode: 502, message: "Media backend request failed or timed out. See logs.", code: "downstream_error"))
                        return
                    }
                    guard (200..<300).contains(response.statusCode) else {
                        self.log("媒体请求失败，mlx-serve HTTP \\(response.statusCode)")
                        completion(.error(statusCode: 502, message: "mlx-serve returned an error. See logs.", code: "downstream_error"))
                        return
                    }
                    completion(HTTPResponse(statusCode: response.statusCode, reason: "OK", headers: [:], body: data ?? Data()))
                }
            }
            task.resume()
        }
    }

    private func log(_ message: String) {
        let line = "\n[Media Backend · \\(Date().formatted(.iso8601))] \\(message)\n"
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
