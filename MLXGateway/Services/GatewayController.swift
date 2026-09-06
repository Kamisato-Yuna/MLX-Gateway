import Foundation
import AppKit

@MainActor
final class GatewayController: ObservableObject {
    @Published var gatewayHost: String
    @Published var gatewayPort: String
    @Published var modelHost: String
    @Published var modelPort: String
    @Published var runtimeDirectory: String
    @Published var modelsDirectory: String
    @Published var pythonExecutable: String
    @Published var selectedModelID: String? {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "selectedModelID") }
    }
    @Published var showingSettings = false
    @Published private(set) var gatewayReady = false
    @Published private(set) var gatewayError: String?
    @Published private(set) var backend = BackendStatus()
    @Published private(set) var logs = ""
    @Published var followLogs = true
    @Published var settingsError: String?
    @Published private(set) var activeBaseURL = ""
    @Published private(set) var registry = ModelRegistry(models: [])
    @Published private(set) var scanningModels = false
    @Published private(set) var copiedValue: String?
    @Published private(set) var scanSummary = "正在读取本地模型…"
    @Published private(set) var runtimeIssue: String?

    let backendManager: BackendManager
    private var server: GatewayServer!
    private var timer: Timer?
    private var readingLogs = false
    private var terminationObserver: NSObjectProtocol?
    private var copyTask: Task<Void, Never>?
    private var appliedGatewayHost = ""
    private var appliedGatewayPort = ""
    private var appliedModelHost = ""
    private var appliedModelPort: UInt16 = 44100
    private var appliedPaths: RuntimePaths

    init() {
        let defaults = UserDefaults.standard
        let paths = RuntimePaths.saved
        appliedPaths = paths
        runtimeDirectory = paths.directory
        modelsDirectory = paths.models
        pythonExecutable = paths.python
        backendManager = BackendManager(pythonExecutable: paths.python)
        gatewayHost = defaults.string(forKey: "gatewayHost") ?? "127.0.0.1"
        gatewayPort = defaults.string(forKey: "gatewayPort") ?? "44110"
        modelHost = defaults.string(forKey: "modelHost") ?? "127.0.0.1"
        modelPort = defaults.string(forKey: "modelPort") ?? "44100"
        appliedGatewayHost = gatewayHost
        appliedGatewayPort = gatewayPort
        appliedModelHost = modelHost
        appliedModelPort = UInt16(modelPort) ?? 44100
        selectedModelID = defaults.string(forKey: "selectedModelID")
        activeBaseURL = LocalEndpoint.url(host: gatewayHost, port: UInt16(gatewayPort) ?? 44110)?
            .appendingPathComponent("v1").absoluteString ?? ""
        server = GatewayServer(registry: registry, backendManager: backendManager,
                               host: gatewayHost, port: UInt16(gatewayPort) ?? 44110)
        server.onStateChange = { [weak self] ready, error in
            Task { @MainActor in self?.gatewayReady = ready; self?.gatewayError = error }
        }
        do { try server.start() } catch { gatewayError = error.localizedDescription }
        refreshModels()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer?.invalidate()
                self?.server.stop()
                self?.backendManager.shutdown()
            }
        }
    }

    var selectedModel: ModelSpec? { registry.models.first { $0.id == selectedModelID } }
    var activeModel: ModelSpec? { registry.models.first { $0.id == backend.modelID } }
    var busy: Bool { backend.state == .starting || backend.state == .stopping }
    var canStart: Bool {
        gatewayReady && selectedModel != nil && runtimeIssue == nil && !busy && !scanningModels
            && !(backend.state == .ready && backend.modelID == selectedModelID)
    }
    var canStop: Bool { (backend.pid != nil || backend.state == .starting) && backend.state != .stopping }
    var canConfigure: Bool { backend.pid == nil && !busy && !scanningModels }
    var startTitle: String {
        if busy { return backend.state == .stopping ? "正在停止…" : "正在加载…" }
        if backend.state == .ready && backend.modelID == selectedModelID { return "模型运行中" }
        return backend.pid != nil ? "切换并启动" : "启动模型"
    }

    func startSelectedModel() {
        guard canStart, let selectedModel else { return }
        backend = BackendStatus(state: .starting, modelID: selectedModel.id, backend: selectedModel.backend.rawValue,
                                message: "正在启动所选模型。")
        backendManager.start(model: selectedModel, host: appliedModelHost, port: appliedModelPort)
    }

    func stopBackend() {
        guard canStop else { return }
        backend.state = .stopping
        backend.message = "正在停止 MLX 服务并释放模型。"
        backendManager.stop()
    }

    func refreshModels() {
        guard canConfigure else { return }
        scanningModels = true
        let paths = appliedPaths
        Task {
            let result = await Task.detached(priority: .userInitiated) { ModelRegistry(modelsRoot: paths.models) }.value
            registry = result
            server.updateRegistry(result)
            if !result.models.contains(where: { $0.id == selectedModelID }) { selectedModelID = result.defaultModel?.id }
            runtimeIssue = FileManager.default.isExecutableFile(atPath: paths.python) ? nil : "未找到可执行的 MLX Python，请在设置中选择环境。"
            scanSummary = result.scanMessage ?? (result.models.isEmpty ? "目录中没有找到模型，请检查模型目录。" : "已扫描到 \(result.models.count) 个本地模型")
            scanningModels = false
        }
    }

    func useRuntimeDirectory(_ path: String) {
        // SwiftUI may write the same text on focus; do not erase independent overrides.
        guard path != runtimeDirectory else { return }
        let paths = RuntimePaths(directory: path)
        runtimeDirectory = path
        modelsDirectory = paths.models
        pythonExecutable = paths.python
    }

    func choosePath(_ kind: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = kind == "python"
        panel.canChooseDirectories = kind != "python"
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = kind == "runtime" ? "选择 MLX 运行目录；默认使用其中的 models 和 .venv/bin/python。" : (kind == "models" ? "选择包含模型的目录，或单个模型目录。" : "选择已安装 mlx-lm / mlx-vlm 的 Python 可执行文件。")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                switch kind {
                case "runtime": self.useRuntimeDirectory(url.path)
                case "models": self.modelsDirectory = url.path
                default: self.pythonExecutable = url.path
                }
            }
        }
    }

    func applySettings() -> Bool {
        guard canConfigure else { settingsError = "请先停止 MLX 服务并等待扫描结束。"; return false }
        gatewayHost = gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        modelHost = modelHost.trimmingCharacters(in: .whitespacesAndNewlines)
        gatewayPort = gatewayPort.trimmingCharacters(in: .whitespacesAndNewlines)
        modelPort = modelPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gatewayPortValue = UInt16(gatewayPort), gatewayPortValue > 0,
              let modelPortValue = UInt16(modelPort), modelPortValue > 0,
              gatewayPortValue != modelPortValue else {
            settingsError = "端口需在 1–65535 之间，网关和 MLX 服务不能使用相同端口。"
            return false
        }
        let paths = RuntimePaths(directory: runtimeDirectory, models: modelsDirectory, python: pythonExecutable)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: paths.directory, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.fileExists(atPath: paths.models, isDirectory: &isDirectory), isDirectory.boolValue else {
            settingsError = "MLX 运行目录和模型目录必须是已存在的文件夹。"; return false
        }
        guard FileManager.default.isExecutableFile(atPath: paths.python) else {
            settingsError = "Python 不存在或不可执行，请选择环境中的 Python 文件。"; return false
        }
        do {
            let gatewayChanged = gatewayHost != appliedGatewayHost || gatewayPort != appliedGatewayPort || !gatewayReady
            if gatewayChanged { try LocalEndpoint.checkAvailable(host: gatewayHost, port: gatewayPortValue) }
            try LocalEndpoint.checkAvailable(host: modelHost, port: modelPortValue)
            if gatewayChanged {
                try server.restart(host: gatewayHost, port: gatewayPortValue)
                gatewayReady = false
                gatewayError = nil
            }
            appliedGatewayHost = gatewayHost
            appliedGatewayPort = gatewayPort
            appliedModelHost = modelHost
            appliedModelPort = modelPortValue
            appliedPaths = paths
            backendManager.configurePython(paths.python)
            activeBaseURL = LocalEndpoint.url(host: gatewayHost, port: gatewayPortValue)!.appendingPathComponent("v1").absoluteString
            for (key, value) in [("gatewayHost", gatewayHost), ("gatewayPort", gatewayPort), ("modelHost", modelHost), ("modelPort", modelPort),
                                 ("runtimeDirectory", paths.directory), ("modelsDirectory", paths.models), ("pythonExecutable", paths.python)] {
                UserDefaults.standard.set(value, forKey: key)
            }
            settingsError = nil
            refreshModels()
            return true
        } catch { settingsError = error.localizedDescription; return false }
    }

    func restoreSettings() {
        gatewayHost = appliedGatewayHost
        gatewayPort = appliedGatewayPort
        modelHost = appliedModelHost
        modelPort = String(appliedModelPort)
        runtimeDirectory = appliedPaths.directory
        modelsDirectory = appliedPaths.models
        pythonExecutable = appliedPaths.python
        settingsError = nil
    }

    private func refresh() {
        backend = backendManager.status
        guard !readingLogs else { return }
        readingLogs = true
        let manager = backendManager
        Task {
            let tail = await Task.detached(priority: .utility) { manager.readLogTail() }.value
            if logs != tail { logs = tail }
            readingLogs = false
        }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(value, forType: .string) else { return }
        copiedValue = value
        copyTask?.cancel()
        copyTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copiedValue = nil }
        }
    }

    func openLogs() {
        let url = backendManager.logURL
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
