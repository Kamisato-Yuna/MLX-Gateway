import Foundation

final class BackendManager {
    private let queue = DispatchQueue(label: "dev.kamisato-yuna.MLXGateway.backend")
    private var process: Process?
    private var activeModelID: String?
    private var activeBackend: BackendKind?
    private let pythonExecutable: String

    init() {
        let venvPython = "/Users/yuna/LLM-Local/qwen36-mlx-vlm/.venv/bin/python"
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            pythonExecutable = venvPython
        } else {
            pythonExecutable = "/usr/bin/python3"
        }
    }

    var publicStatus: [String: Any] {
        queue.sync {
            [
                "active_model": activeModelID as Any,
                "backend": activeBackend?.rawValue as Any,
                "running": process?.isRunning == true
            ]
        }
    }

    func ensureActive(model: ModelSpec, host: String, port: UInt16) throws {
        try queue.sync {
            if activeModelID == model.id, process?.isRunning == true {
                return
            }

            stopLocked()
            try startLocked(model: model, host: host, port: port)
        }
    }

    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    private func startLocked(model: ModelSpec, host: String, port: UInt16) throws {
        guard FileManager.default.fileExists(atPath: model.localPath) else {
            throw BackendError.modelNotFound(model.id)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonExecutable)
        process.arguments = [
            "-m",
            model.backend.moduleName,
            "--host",
            host,
            "--port",
            "\(port)",
            "--model",
            model.localPath
        ]

        let logURL = logFileURL()
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        logHandle.seekToEndOfFile()
        process.standardOutput = logHandle
        process.standardError = logHandle

        try process.run()
        self.process = process
        activeModelID = model.id
        activeBackend = model.backend
    }

    private func stopLocked() {
        guard let process else {
            activeModelID = nil
            activeBackend = nil
            return
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        self.process = nil
        activeModelID = nil
        activeBackend = nil
    }

    private func logFileURL() -> URL {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("MLXGateway")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("backend.log")
    }
}

enum BackendError: LocalizedError {
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let id):
            return "Local model directory is missing for \(id)."
        }
    }
}
