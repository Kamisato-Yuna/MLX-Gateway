import Foundation
import Combine
import Darwin

@MainActor
final class AudioServiceController: ObservableObject {
    static let selectionID = "service:audio-transcription"
    enum State: String { case unconfigured, stopped, available, starting, loading, ready, stopping, failed }
    @Published private(set) var configuration: AudioTranscriptionProxy.Configuration?
    @Published private(set) var state: State = .unconfigured
    @Published private(set) var message = "配置一个 OpenAI 兼容的语音转写服务。"
    @Published private(set) var error: String?
    @Published private(set) var transcript = ""
    @Published private(set) var transcribing = false
    @Published private(set) var testFilename = ""
    @Published var draftBaseURL = ""
    @Published var draftModel = ""
    @Published var draftDisplayName = ""
    @Published var draftLaunchScript = ""
    let proxy: AudioTranscriptionProxy
    private var runtimeDirectory: String
    private var process: Process?
    private var logHandle: FileHandle?
    private var operation: Task<Void, Never>?
    private var probe: Task<Void, Never>?
    private var lastProbe = Date.distantPast
    private let session = URLSession(configuration: .ephemeral)

    init(proxy: AudioTranscriptionProxy, runtimeDirectory: String) {
        self.proxy = proxy
        self.runtimeDirectory = runtimeDirectory
        configuration = proxy.configuration
        if configuration != nil { state = .stopped; message = "正在检查已配置的语音服务。" }
        restoreDraft()
    }

    var busy: Bool { [.starting, .loading, .stopping].contains(state) }
    var canStart: Bool { configuration != nil && !busy && state != .ready && !transcribing }
    var canStop: Bool { !transcribing && state != .stopping && (process != nil || state == .ready) }
    var canConfigure: Bool { !busy && !transcribing && process == nil }
    var ownsProcess: Bool { process != nil }
    var title: String {
        switch state {
        case .unconfigured: "未配置"
        case .stopped: "服务未启动"
        case .available: "模型未加载"
        case .starting: "正在启动服务"
        case .loading: "正在加载模型"
        case .ready: "转写就绪"
        case .stopping: "正在停止"
        case .failed: "需要处理"
        }
    }
    var startTitle: String { state == .available ? "加载转写模型" : "启动转写服务" }
    var stopTitle: String { ownsProcess ? "停止转写服务" : "卸载转写模型" }
    var logURL: URL { URL(fileURLWithPath: runtimeDirectory).appendingPathComponent("audio-service/logs/gateway-managed.log") }

    func restoreDraft() {
        draftBaseURL = configuration?.baseURL.absoluteString ?? "http://127.0.0.1:44120/v1"
        draftModel = configuration?.model ?? "whisper-1"
        draftDisplayName = configuration?.displayName ?? ""
        draftLaunchScript = configuration?.launchScript ?? ""
    }

    @discardableResult func save() -> Bool {
        guard canConfigure else { return false }
        let model = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = RuntimePaths.expand(draftLaunchScript)
        guard let url = URL(string: draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !model.isEmpty, !model.hasPrefix("/"), !model.contains("\n") else {
            error = "填写有效的 http(s) Base URL 和模型 ID；地址不能包含凭证或查询参数。"; return false
        }
        if !script.isEmpty {
            guard script.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: script),
                  ["127.0.0.1", "localhost", "::1"].contains(url.host) else {
                error = "启动脚本需为可执行的本机绝对路径，且下游服务需使用回环地址。"; return false
            }
        }
        let config = AudioTranscriptionProxy.Configuration(baseURL: url, model: model,
            timeout: configuration?.timeout ?? 180,
            displayName: draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
            launchScript: script.isEmpty ? nil : script)
        do {
            let path = AudioTranscriptionProxy.Configuration.fileURL(runtimeDirectory: runtimeDirectory)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(config).write(to: path, options: .atomic)
            apply(config)
            return true
        } catch { self.error = "配置保存失败：\(error.localizedDescription)"; return false }
    }

    func useRuntimeDirectory(_ directory: String) {
        guard directory != runtimeDirectory else { return }
        shutdown()
        runtimeDirectory = directory
        apply(.load(runtimeDirectory: directory))
    }

    private func apply(_ configuration: AudioTranscriptionProxy.Configuration?) {
        probe?.cancel(); probe = nil
        self.configuration = configuration
        proxy.configure(configuration)
        transcript = ""; testFilename = ""; error = nil
        state = configuration == nil ? .unconfigured : .stopped
        restoreDraft()
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        guard operation == nil, probe == nil, let config = configuration,
              force || Date().timeIntervalSince(lastProbe) >= 3 else { return }
        lastProbe = Date()
        probe = Task { [weak self] in
            guard let self else { return }
            let availability = await proxy.availability(configuration: config)
            guard !Task.isCancelled else { return }
            switch availability {
            case .loaded: state = .ready; message = ownsProcess ? "转写模型已加载，由 MLX Gateway 管理服务进程。" : "转写模型已加载，已连接到现有服务。"
            case .available: state = .available; message = "服务可连接。手动加载模型后即可转写；请求不会自动加载模型。"
            case .unavailable:
                if state != .failed { state = .stopped; message = "下游服务未连接。可使用已配置的本地启动脚本。" }
            }
            probe = nil
        }
    }

    func start() {
        guard canStart, let config = configuration else { return }
        probe?.cancel(); probe = nil; error = nil
        state = .starting; message = "正在检查语音服务。"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { operation = nil }
            do {
                if await proxy.availability(configuration: config) == .unavailable {
                    guard let script = config.launchScript else { throw ServiceError("未配置启动脚本。请先启动下游服务，或在服务设置中选择脚本。") }
                    try launch(script)
                    let deadline = Date().addingTimeInterval(config.timeout)
                    while await proxy.availability(configuration: config) == .unavailable {
                        try Task.checkCancellation()
                        guard process?.isRunning == true else { throw ServiceError("转写进程已退出，请查看服务日志。") }
                        guard Date() < deadline else { throw ServiceError("转写服务启动超时，请查看服务日志。") }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                }
                try Task.checkCancellation()
                state = .loading; message = "正在加载转写模型。"
                try await modelOperation("POST", configuration: config)
                try Task.checkCancellation()
                guard await proxy.availability(configuration: config) == .loaded else { throw ServiceError("服务未报告该模型已加载。") }
                state = .ready; message = "转写模型已加载，可以上传音频。"
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription; state = .failed; message = "转写服务未就绪。" } }
        }
    }

    private func launch(_ script: String) throws {
        guard process == nil, FileManager.default.isExecutableFile(atPath: script) else { throw ServiceError("启动脚本不可执行，或已有受管进程。") }
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: logURL); try handle.seekToEnd()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: script)
        child.currentDirectoryURL = URL(fileURLWithPath: runtimeDirectory)
        child.standardOutput = handle; child.standardError = handle; child.standardInput = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, self.process === child else { return }
                self.operation?.cancel(); self.operation = nil
                self.process = nil
                try? self.logHandle?.close(); self.logHandle = nil
                self.state = .failed
                self.error = "转写进程已退出（\(child.terminationStatus)）。请查看服务日志后重试。"
            }
        }
        do { try child.run(); process = child; logHandle = handle }
        catch { try? handle.close(); throw error }
    }

    func stop() {
        guard canStop, let config = configuration else { return }
        operation?.cancel(); operation = nil
        probe?.cancel(); probe = nil; error = nil; state = .stopping
        operation = Task { [weak self] in
            guard let self else { return }
            defer { operation = nil }
            if process != nil {
                terminateOwnedProcess()
                state = .stopped; message = "转写服务已停止。网关仍保持监听。"
            } else {
                do {
                    try await modelOperation("DELETE", configuration: config)
                    state = .available; message = "转写模型已卸载，现有服务保持运行。"
                } catch { self.error = error.localizedDescription; state = .failed }
            }
        }
    }

    private func modelOperation(_ method: String, configuration: AudioTranscriptionProxy.Configuration) async throws {
        var parts = URLComponents(url: configuration.baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "model_name", value: configuration.model)]
        var request = URLRequest(url: parts.url!); request.httpMethod = method; request.timeoutInterval = configuration.timeout
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) || (method == "DELETE" && response.statusCode == 404) else {
            throw ServiceError("模型管理操作失败。请确认下游支持 POST /v1/models 和 DELETE /v1/models。")
        }
    }

    func transcribe(file: URL, gatewayBaseURL: String) {
        guard state == .ready, !transcribing, let config = configuration,
              let base = URL(string: gatewayBaseURL) else { return }
        transcribing = true; transcript = ""; testFilename = file.lastPathComponent; error = nil
        Task { [weak self] in
            guard let self else { return }
            defer { transcribing = false }
            do {
                let audio = try await Task.detached(priority: .userInitiated) {
                    guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1024 * 1024 - 4096 else { throw ServiceError("音频文件过大。上传总大小不能超过 16 MiB。") }
                    return try Data(contentsOf: file)
                }.value
                let boundary = "mlx-audio-\(UUID().uuidString)"
                var body = Data()
                for (name, value) in [("model", config.model), ("response_format", "json")] {
                    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
                }
                let filename = file.lastPathComponent.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
                body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
                var request = URLRequest(url: base.appendingPathComponent("audio/transcriptions"))
                request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = config.timeout
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await session.data(for: request)
                let object = JSONSupport.object(from: data)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let text = object?["text"] as? String else {
                    throw ServiceError((object?["error"] as? [String: Any])?["message"] as? String ?? "音频转写失败。请检查服务和文件格式。")
                }
                transcript = text.isEmpty ? "（未识别到文字）" : text
            } catch { self.error = error.localizedDescription }
        }
    }

    func shutdown() {
        operation?.cancel(); operation = nil; probe?.cancel(); probe = nil
        terminateOwnedProcess()
    }

    private func terminateOwnedProcess() {
        guard let child = process else { return }
        child.terminationHandler = nil
        if child.isRunning {
            child.terminate()
            let deadline = Date().addingTimeInterval(3)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        process = nil; try? logHandle?.close(); logHandle = nil
    }

    private struct ServiceError: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }
}
