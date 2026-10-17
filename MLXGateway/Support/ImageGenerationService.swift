import Foundation
import Darwin
import CoreFoundation
import ImageIO

struct ImageServiceConfiguration: Sendable, Equatable {
    let title: String
    let model: String
    let modelPath: String
    let executablePath: String
    let host: String
    let port: UInt16
    let readinessTimeout: TimeInterval
    let requestTimeout: TimeInterval

    var validationMessage: String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.hasPrefix("/"), !model.hasPrefix("file:") else { return "图像服务配置需要名称和模型 ID；模型 ID 不能是文件路径。" }
        guard modelPath.hasPrefix("/"), executablePath.hasPrefix("/") else { return "图像模型与 mlx-serve 必须使用本机绝对路径。" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelPath, isDirectory: &isDirectory), isDirectory.boolValue else { return "图像模型目录不存在。" }
        let root = URL(fileURLWithPath: modelPath)
        let required = ["model_index.json", "config.json", "transformer/config.json", "vae/config.json", "vae/diffusion_pytorch_model.safetensors", "processor/tokenizer.json", "text_encoder/config.json"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }),
              let files = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("transformer").path), files.contains(where: { $0.hasSuffix(".safetensors") }),
              let encoder = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("text_encoder").path), encoder.contains(where: { $0.hasSuffix(".safetensors") }) else {
            return "图像模型缺少 pipeline、transformer、VAE、tokenizer 或 text encoder 文件。"
        }
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { return "mlx-serve 不存在或不可执行。" }
        guard host == "127.0.0.1" || host == "localhost" || host == "::1", port > 0 else { return "图像服务只能绑定本机地址和有效端口。" }
        return nil
    }

    static func load(runtimeDirectory: String) -> ImageServiceConfiguration? {
        let url = URL(fileURLWithPath: runtimeDirectory).appendingPathComponent("image-service/gateway.json")
        guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data), let raw = object as? [String: Any],
              let title = raw["title"] as? String, let model = raw["model"] as? String,
              let modelPath = raw["model_path"] as? String, let executablePath = raw["executable_path"] as? String,
              let host = raw["host"] as? String, let portNumber = raw["port"] as? NSNumber,
              CFGetTypeID(portNumber) != CFBooleanGetTypeID(), portNumber.doubleValue.rounded() == portNumber.doubleValue,
              (1...65535).contains(portNumber.intValue) else { return nil }
        let readiness = (raw["readiness_timeout"] as? NSNumber)?.doubleValue ?? 1800
        let request = (raw["request_timeout"] as? NSNumber)?.doubleValue ?? 1800
        guard readiness.isFinite, readiness > 0, readiness <= 1800, request.isFinite, request > 0, request <= 1800 else { return nil }
        return ImageServiceConfiguration(title: title, model: model, modelPath: modelPath,
                                          executablePath: executablePath, host: host, port: UInt16(portNumber.intValue),
                                          readinessTimeout: readiness, requestTimeout: request)
    }
}

struct ImageBackendStatus: Equatable, Sendable {
    enum State: String, Sendable { case stopped, starting, ready, stopping, failed }
    var state: State = .stopped
    var pid: Int32?
    var message = "图像后端未启动。"

    var publicDescription: [String: Any] {
        ["state": state.rawValue, "pid": pid as Any? ?? NSNull(), "running": pid != nil,
         "ready": state == .ready, "message": message]
    }
}

final class ImageGenerationService: @unchecked Sendable {
    static let selectionID = "service:image-generation"
    private let queue = DispatchQueue(label: "dev.kamisato-yuna.MLXGateway.image-service")
    private let lock = NSLock()
    private let session = URLSession(configuration: .ephemeral)
    private var currentStatus = ImageBackendStatus()
    private var process: Process?
    private struct PendingTask { let task: URLSessionDataTask; let completion: @Sendable (HTTPResponse) -> Void; let process: Process? }
    private var tasks: [UUID: PendingTask] = [:]
    private var readinessTasks: [UUID: URLSessionDataTask] = [:]
    private var busy = false
    private var runtimeDirectory: String
    private var config: ImageServiceConfiguration?
    private var configError: String?
    private var runLogOffset: UInt64 = 0
    let logURL: URL

    init(runtimeDirectory: String, logURL: URL? = nil) {
        self.runtimeDirectory = runtimeDirectory
        self.logURL = logURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MLXGateway/image-backend.log")
        reload(runtimeDirectory: runtimeDirectory)
    }

    var configuration: ImageServiceConfiguration? { lock.withLock { config } }
    var configurationError: String? { lock.withLock { configError } }
    var status: ImageBackendStatus { lock.withLock { currentStatus } }
    var modelDescription: [String: Any]? {
        guard let c = configuration, c.validationMessage == nil else { return nil }
        return ["id": c.model, "object": "model", "created": 0, "owned_by": "mlx-serve",
                "capabilities": ["image_generation"], "backend": "mlx-serve", "ready": status.state == .ready,
                "endpoints": ["/v1/images/generations"], "response_formats": ["b64_json"]]
    }

    func reload(runtimeDirectory: String) {
        let loaded = ImageServiceConfiguration.load(runtimeDirectory: runtimeDirectory)
        let file = URL(fileURLWithPath: runtimeDirectory).appendingPathComponent("image-service/gateway.json")
        let exists = FileManager.default.fileExists(atPath: file.path)
        lock.withLock {
            self.runtimeDirectory = runtimeDirectory
            config = loaded
            if let loaded {
                configError = loaded.validationMessage
            } else {
                configError = exists ? "image-service/gateway.json 格式无效或字段不完整。" : "缺少 image-service/gateway.json 配置。"
            }
        }
    }

    func start() {
        queue.async { [self] in
            guard let c = configuration, c.validationMessage == nil else {
                publish(.init(state: .failed, message: configurationError ?? "图像服务配置无效。")); return
            }
            if process?.isRunning == true { return }
            publish(.init(state: .starting, message: "正在启动并加载指定图像模型。"))
            do {
                try LocalEndpoint.checkAvailable(host: c.host, port: c.port)
                try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let fd = Darwin.open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw BackendError.message("无法打开图像后端日志。") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                runLogOffset = (try? handle.seekToEnd()) ?? 0
                let child = Process(); child.executableURL = URL(fileURLWithPath: c.executablePath)
                child.arguments = ["--model", c.modelPath, "--serve", "--host", c.host, "--port", String(c.port)]
                child.standardInput = FileHandle.nullDevice; child.standardOutput = handle; child.standardError = handle
                child.terminationHandler = { [weak self] child in
                    guard let service = self else { return }
                    service.queue.async { service.exited(child) }
                }
                child.environment = ProcessInfo.processInfo.environment.merging(["HF_HUB_OFFLINE": "1"]) { _, new in new }
                try child.run(); process = child
                publish(.init(state: .starting, pid: child.processIdentifier, message: "等待指定图像模型加载完成。"))
                probe(child, deadline: Date().addingTimeInterval(c.readinessTimeout), attemptedLoad: false)
            } catch {
                publish(.init(state: .failed, message: "图像后端启动失败或端口已被占用。"))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            publish(.init(state: .stopping, pid: process?.processIdentifier, message: "正在停止图像后端。"))
            readinessTasks.values.forEach { $0.cancel() }; readinessTasks.removeAll()
            cancelPending(message: "图像请求已因后端停止而取消。")
            guard let child = process, child.isRunning else { process = nil; publish(.init()); return }
            child.terminate()
            queue.asyncAfter(deadline: .now() + 3) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
                if self.process === child { self.process = nil; self.publish(.init()) }
            }
        }
    }
    func shutdown() {
        queue.sync {
            readinessTasks.values.forEach { $0.cancel() }; readinessTasks.removeAll()
            cancelPending(message: "图像请求已因后端停止而取消。")
            if let p = process, p.isRunning {
                p.terminate()
                let deadline = Date().addingTimeInterval(3)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
            }
            process = nil; publish(.init())
        }
    }
    func readLogTail() -> String { readLogTail(since: 0) }

    private func readLogTail(since offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: max(min(offset, size), size > 64 * 1024 ? size - 64 * 1024 : 0))
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    func forward(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResponse) -> Void) {
        guard request.path.split(separator: "?").first == "/v1/images/generations", request.method == "POST" else {
            completion(.error(statusCode: 404, message: "图像路由不存在。", code: "not_found")); return
        }
        guard let c = configuration else { completion(.error(statusCode: 404, message: "图像服务未配置。", code: "not_found")); return }
        guard request.body.count <= 1024 * 1024, let body = JSONSupport.object(from: request.body) else {
            completion(.error(statusCode: 400, message: "请求必须是小于 1 MiB 的 JSON 对象。", code: "invalid_request")); return
        }
        do {
            let allowed: Set<String> = ["model", "prompt", "n", "size", "response_format", "steps", "seed", "guidance_scale", "negative_prompt"]
            if body.keys.contains(where: { !allowed.contains($0) }) { throw ImageRequestError(message: "请求包含不支持的字段。") }
            guard body["model"] as? String == c.model else { throw ImageRequestError(message: "model 必须与本机图像配置一致。") }
            guard let prompt = body["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  prompt.count <= 16_000 else { throw ImageRequestError(message: "prompt 必须为非空文本且不超过 16000 字符。") }
            if let value = body["n"] { guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == 1 else { throw ImageRequestError(message: "仅支持 n=1。") } }
            if let value = body["response_format"] { guard value as? String == "b64_json" else { throw ImageRequestError(message: "仅支持 response_format=b64_json。") } }
            guard body["size"] == nil || ["512x512", "1024x1024", "1024x1536", "1536x1024"].contains(body["size"] as? String ?? "") else { throw ImageRequestError(message: "size 仅支持 512x512、1024x1024、1024x1536、1536x1024。") }
            for key in ["steps", "seed"] where body[key] != nil {
                guard let number = body[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue else { throw ImageRequestError(message: "数值参数必须是有效整数。") }
                let n = number.int64Value
                if key == "steps" { guard (1...100).contains(n) else { throw ImageRequestError(message: "steps 必须是 1 到 100 的整数。") } }
                else { guard (0...Int64(UInt32.max)).contains(n) else { throw ImageRequestError(message: "seed 超出支持范围。") } }
            }
            if let value = body["guidance_scale"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, (0...20).contains(number.doubleValue) else { throw ImageRequestError(message: "guidance_scale 必须是 0 到 20 的有限数字。") }
            }
            if let negative = body["negative_prompt"] { guard let s = negative as? String, s.count <= 4000 else { throw ImageRequestError(message: "negative_prompt 必须是 4000 字符以内的文本。") } }
            var rewritten = body; rewritten["model"] = c.model
            guard let base = LocalEndpoint.url(host: c.host, port: c.port), let url = URL(string: "/v1/images/generations", relativeTo: base) else { throw ImageRequestError(message: "图像服务地址无效。") }
            var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = c.requestTimeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = JSONSupport.data(from: rewritten)
            let outboundRequest = req
            queue.async { [self] in
                guard status.state == .ready, let child = process, child.isRunning else { completion(.error(statusCode: 503, message: "图像后端尚未就绪，请在界面手动启动。", code: "image_backend_not_ready")); return }
                guard !busy else { completion(.error(statusCode: 429, message: "图像后端正在处理另一个请求。", code: "image_backend_busy")); return }
                busy = true
                let id = UUID()
                let task = session.dataTask(with: outboundRequest) { [weak self] data, response, error in
                    guard let self else { return }
                    self.queue.async {
                        guard let pending = self.tasks.removeValue(forKey: id) else { return }
                        self.busy = false
                        guard self.status.state == .ready, self.process === pending.process else { pending.completion(.error(statusCode: 503, message: "图像请求已因后端停止而取消。", code: "image_backend_stopped")); return }
                        guard error == nil, let data, data.count <= 16 * 1024 * 1024, (response as? HTTPURLResponse)?.statusCode == 200 else {
                            pending.completion(.error(statusCode: 502, message: "图像生成失败或响应超限。", code: "image_generation_failed")); return
                        }
                        guard let result = JSONSupport.object(from: data), let entries = result["data"] as? [[String: Any]], entries.count == 1,
                              let b64 = entries[0]["b64_json"] as? String, b64.utf8.count <= 15 * 1024 * 1024,
                              let png = Data(base64Encoded: b64), self.validPNG(png) else {
                            pending.completion(.error(statusCode: 502, message: "图像后端返回无效或超限的 PNG。", code: "invalid_image_response")); return
                        }
                    pending.completion(.json(object: ["created": Int(Date().timeIntervalSince1970), "data": [["b64_json": b64]]]))
                    }
                }
                tasks[id] = PendingTask(task: task, completion: completion, process: child)
                task.resume()
            }
        } catch let error as ImageRequestError { completion(.error(statusCode: 400, message: error.message, code: "invalid_request")) }
        catch { completion(.error(statusCode: 400, message: "无效图像请求。", code: "invalid_request")) }
    }

    private func validPNG(_ data: Data) -> Bool {
        guard data.count >= 33, data.count <= 12 * 1024 * 1024,
              Array(data.prefix(8)) == [137,80,78,71,13,10,26,10], String(data: data[12..<16], encoding: .ascii) == "IHDR" else { return false }
        let w = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }, h = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard w > 0, h > 0, w <= 8192, h <= 8192, UInt64(w) * UInt64(h) <= 40_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return image.width == Int(w) && image.height == Int(h)
    }
    private func probe(_ child: Process, deadline: Date, attemptedLoad: Bool) {
        guard status.state == .starting, process === child, child.isRunning,
              let c = configuration, let base = LocalEndpoint.url(host: c.host, port: c.port),
              let url = URL(string: "/v1/models", relativeTo: base) else { return }
        var request = URLRequest(url: url); request.timeoutInterval = 2
        let id = UUID()
        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let service = self else { return }
            service.queue.async {
                service.readinessTasks[id] = nil
                guard service.status.state == .starting, service.process === child, child.isRunning else { return }
                if let data, (response as? HTTPURLResponse)?.statusCode == 200,
                   let obj = JSONSupport.object(from: data), let models = obj["data"] as? [[String: Any]],
                   let model = models.first(where: { ($0["id"] as? String) == c.model }) {
                    if model["loaded"] as? Bool == true || model["state"] as? String == "ready" {
                        service.publish(.init(state: .ready, pid: child.processIdentifier, message: "指定图像模型已加载并可用。")); return
                    }
                    if !attemptedLoad {
                        var load = URLRequest(url: base.appendingPathComponent("v1/load-model")); load.httpMethod = "POST"
                        load.timeoutInterval = max(30, min(c.readinessTimeout, 1800)); load.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        load.httpBody = JSONSupport.data(from: ["model": c.model])
                        let loadID = UUID()
                        let loadTask = service.session.dataTask(with: load) { data, response, _ in service.queue.async {
                            service.readinessTasks[loadID] = nil
                            guard service.status.state == .starting, service.process === child, child.isRunning else { return }
                            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
                               let result = JSONSupport.object(from: data)?["model"] as? [String: Any],
                               result["id"] as? String == c.model, result["loaded"] as? Bool == true, result["state"] as? String == "ready" {
                                service.publish(.init(state: .ready, pid: child.processIdentifier, message: "指定图像模型已加载并可用。")); return
                            }
                            if Date() >= deadline { service.failChild(child, message: "指定图像模型加载失败或超时。") }
                            else { service.queue.asyncAfter(deadline: .now() + 2) { service.probe(child, deadline: deadline, attemptedLoad: true) } }
                        }}
                        service.readinessTasks[loadID] = loadTask; loadTask.resume(); return
                    }
                }
                if Date() >= deadline { service.failChild(child, message: "等待指定模型加载超时。"); return }
                service.queue.asyncAfter(deadline: .now() + 2) { service.probe(child, deadline: deadline, attemptedLoad: attemptedLoad) }
            }
        }
        readinessTasks[id] = task; task.resume()
    }
    private func failChild(_ child: Process, message: String) {
        guard process === child else { return }
        publish(.init(state: .failed, pid: child.processIdentifier, message: message)); child.terminate()
        queue.asyncAfter(deadline: .now() + 3) { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }; if self.process === child { self.process = nil } }
    }
    private func exited(_ child: Process) {
        guard process === child else { return }
        process = nil
        readinessTasks.values.forEach { $0.cancel() }; readinessTasks.removeAll()
        cancelPending(message: "图像后端已退出，生成请求已取消。")
        if status.state != .stopping {
            let log = readLogTail(since: runLogOffset).lowercased()
            let message = (log.contains("insufficientmemory") || log.contains("insufficient memory") || log.contains("not enough memory"))
                ? "可用内存不足，图像模型未加载。请释放内存后重试。" : "图像后端意外退出。"
            publish(.init(state: .failed, message: message))
        } else { publish(.init()) }
    }
    private func cancelPending(message: String) {
        for item in tasks.values { item.task.cancel(); item.completion(.error(statusCode: 503, message: message, code: "image_backend_stopped")) }
        tasks.removeAll(); busy = false
    }
    private func publish(_ value: ImageBackendStatus) { lock.withLock { currentStatus = value } }
}

private struct ImageRequestError: Error { let message: String; init(message: String) { self.message = message } }
