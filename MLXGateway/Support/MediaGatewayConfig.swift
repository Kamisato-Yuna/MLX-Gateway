import Foundation

/// Optional configuration for the media/decision backend (the `mlx-serve` binary).
///
/// Unlike the text/vision backends (`mlx_lm` / `mlx_vlm`), Hunyuan3D and Laya only
/// run in the standalone `mlx-serve` binary. This struct describes *whether* and
/// *where* the gateway should manage that binary. It is intentionally independent
/// from `BackendManager` so enabling it never disturbs the core python-spawn path.
/// Defaults ship with `enabled == false`, preserving current gateway behaviour.
struct MediaGatewayConfig {
    var enabled: Bool
    var host: String
    var port: UInt16
    /// Absolute path to the `mlx-serve` executable (spawned when `enabled`).
    /// Falls back to the sibling tool under the runtime directory if empty.
    var executablePath: String
    /// Absolute model root(s) passed via repeated `--model-dir`; empty uses defaults.
    var modelDirectories: [String]
    /// `image-models` subdirectory default under the runtime directory.
    var imageModelsDirectory: String
    /// `decision-models` subdirectory default under the runtime directory.
    var decisionModelsDirectory: String
    /// Whether to expose `POST /v1/decisions` (Laya). Independently togglable.
    var decisionsEnabled: Bool
    /// Seconds to wait for the media backend to pass its health check before failing.
    var readinessTimeout: TimeInterval

    init(
        enabled: Bool = false,
        host: String = "127.0.0.1",
        port: UInt16 = 8080,
        executablePath: String = "",
        modelDirectories: [String] = [],
        imageModelsDirectory: String = "",
        decisionModelsDirectory: String = "",
        decisionsEnabled: Bool = false,
        readinessTimeout: TimeInterval = 180
    ) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.executablePath = executablePath
        self.modelDirectories = modelDirectories
        self.imageModelsDirectory = imageModelsDirectory
        self.decisionModelsDirectory = decisionModelsDirectory
        self.decisionsEnabled = decisionsEnabled
        self.readinessTimeout = readinessTimeout
    }

    /// Derive a config from gateway defaults plus a runtime directory. The media
    /// backend is off unless `enabled` or `decisionsEnabled` is explicitly set.
    static func `default`(runtimeDirectory: String = RuntimePaths.saved.directory) -> MediaGatewayConfig {
        let runtime = (runtimeDirectory as NSString).standardizingPath
        return MediaGatewayConfig(
            executablePath: (runtime as NSString)
                .appendingPathComponent(".tools/mlx-serve-macos-arm64/mlx-serve"),
            imageModelsDirectory: (runtime as NSString).appendingPathComponent("image-models"),
            decisionModelsDirectory: (runtime as NSString).appendingPathComponent("decision-models")
        )
    }

    /// Parse a plain `[String: Any]` (from UserDefaults or a settings screen).
    /// Unknown keys are ignored; individual fields fall back to current values.
    func parsed(from raw: [String: Any]?) -> MediaGatewayConfig {
        guard let raw else { return self }
        var next = self
        if let value = raw["enabled"] as? Bool { next.enabled = value }
        if let value = raw["decisions_enabled"] as? Bool { next.decisionsEnabled = value }
        if let value = raw["host"] as? String, !value.isEmpty { next.host = value }
        if let value = raw["port"] as? Int, value > 0, value <= 65535 { next.port = UInt16(value) }
        if let value = raw["executable_path"] as? String, !value.isEmpty { next.executablePath = value }
        if let value = raw["image_models_directory"] as? String, !value.isEmpty { next.imageModelsDirectory = value }
        if let value = raw["decision_models_directory"] as? String, !value.isEmpty { next.decisionModelsDirectory = value }
        if let value = raw["readiness_timeout"] as? Double, value > 0 { next.readinessTimeout = value }
        if let list = raw["model_directories"] as? [String] { next.modelDirectories = list }
        return next
    }

    /// Root directories actually passed to `mlx-serve` via repeated `--model-dir`.
    /// Falls back to `[imageModelsDirectory]` (3D) and, when decisions are on,
    /// appends `decisionModelsDirectory` so both Hunyuan3D and Laya are discoverable.
    var resolvedModelDirectories: [String] {
        if !modelDirectories.isEmpty { return modelDirectories }
        var dirs: [String] = []
        if !imageModelsDirectory.isEmpty { dirs.append(imageModelsDirectory) }
        if decisionsEnabled && !decisionModelsDirectory.isEmpty { dirs.append(decisionModelsDirectory) }
        return dirs
    }
}
