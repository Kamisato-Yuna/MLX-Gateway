import Foundation

enum BackendKind: String {
    case mlxLM = "mlx_lm"
    case mlxVLM = "mlx_vlm"

    var moduleName: String {
        switch self {
        case .mlxLM:
            return "mlx_lm.server"
        case .mlxVLM:
            return "mlx_vlm.server"
        }
    }
}

struct ModelSpec: Identifiable, Equatable {
    let id: String
    let backend: BackendKind
    let capabilities: Set<String>
    let localPath: String

    var publicDescription: [String: Any] {
        [
            "id": id,
            "object": "model",
            "created": 1_783_336_800,
            "owned_by": "local",
            "capabilities": Array(capabilities).sorted(),
            "backend": backend.rawValue
        ]
    }
}

struct ModelRegistry {
    static let shared = ModelRegistry()

    private let modelsRoot = "/Users/yuna/LLM-Local/qwen36-mlx-vlm/models"

    let models: [ModelSpec]

    var defaultModel: ModelSpec {
        models[0]
    }

    init() {
        models = [
            ModelSpec(
                id: "Qwen3-Coder-30B-A3B-Instruct-4bit",
                backend: .mlxLM,
                capabilities: ["chat"],
                localPath: "\(modelsRoot)/Qwen3-Coder-30B-A3B-Instruct-4bit"
            ),
            ModelSpec(
                id: "Qwen3.6-35B-A3B-4bit",
                backend: .mlxVLM,
                capabilities: ["chat", "responses", "vision"],
                localPath: "\(modelsRoot)/Qwen3.6-35B-A3B-4bit"
            ),
            ModelSpec(
                id: "Qwen3.6-27B-AEON-Ultimate-Uncensored-BF16-mlx-4Bit",
                backend: .mlxLM,
                capabilities: ["chat"],
                localPath: "\(modelsRoot)/Qwen3.6-27B-AEON-Ultimate-Uncensored-BF16-mlx-4Bit"
            )
        ]
    }

    func model(id: String?) -> ModelSpec? {
        guard let id, !id.isEmpty else {
            return defaultModel
        }
        return models.first { $0.id == id }
    }
}
