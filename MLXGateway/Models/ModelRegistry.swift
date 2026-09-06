import Foundation

enum BackendKind: String, Sendable {
    case mlxLM = "mlx_lm"
    case mlxVLM = "mlx_vlm"
    var moduleName: String { self == .mlxLM ? "mlx_lm.server" : "mlx_vlm.server" }
    var symbol: String { self == .mlxVLM ? "eye" : "text.bubble" }
}

struct RuntimePaths: Equatable, Sendable {
    var directory: String
    var models: String
    var python: String

    static func expand(_ path: String) -> String {
        NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
    }

    init(directory: String, models: String? = nil, python: String? = nil) {
        self.directory = Self.expand(directory)
        self.models = Self.expand(models ?? self.directory + "/models")
        self.python = Self.expand(python ?? self.directory + "/.venv/bin/python")
    }

    static var saved: RuntimePaths {
        let defaults = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Preserve an existing local installation on upgrade; new users choose their own directory.
        let previous = home + "/LLM-Local/mlx-local-runtime"
        let fallback = FileManager.default.fileExists(atPath: previous + "/models") ? previous : home + "/MLX"
        return RuntimePaths(directory: env["MLX_GATEWAY_RUNTIME"] ?? defaults.string(forKey: "runtimeDirectory") ?? fallback,
                            models: env["MLX_GATEWAY_MODELS"] ?? (env["MLX_GATEWAY_RUNTIME"] == nil ? defaults.string(forKey: "modelsDirectory") : nil),
                            python: env["MLX_GATEWAY_PYTHON"] ?? (env["MLX_GATEWAY_RUNTIME"] == nil ? defaults.string(forKey: "pythonExecutable") : nil))
    }
}

struct ModelSpec: Identifiable, Equatable, Sendable {
    let id: String
    let backend: BackendKind
    let capabilities: Set<String>
    let localPath: String
    var displayName: String { URL(fileURLWithPath: localPath).lastPathComponent }
    var subtitle: String { backend == .mlxVLM ? "视觉模型 · 文本与图片" : "文本模型 · MLX" }
    var publicDescription: [String: Any] {
        ["id": id, "object": "model", "created": 0, "owned_by": "local",
         "capabilities": Array(capabilities).sorted(), "backend": backend.rawValue,
         "limitations": ["function strict=false; requires recognized tokenizer parser",
                         backend == .mlxVLM ? "JSON requires llguidance; images use detail=auto" : "No image/PDF input or constrained JSON",
                         "Responses are retained in gateway process memory; restart clears history"]]
    }
}

struct ModelRegistry: Sendable {
    static var shared: ModelRegistry { ModelRegistry(modelsRoot: RuntimePaths.saved.models) }
    let models: [ModelSpec]
    let scanMessage: String?
    var defaultModel: ModelSpec? { models.first }

    init(models: [ModelSpec], scanMessage: String? = nil) {
        self.models = models
        self.scanMessage = scanMessage
    }

    init(modelsRoot: String) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: RuntimePaths.expand(modelsRoot)).standardizedFileURL
        var found: [ModelSpec] = []
        var invalid = 0
        var failures = 0
        // Each model is a directory containing config.json. Also supports nested collections
        // and Hugging Face snapshots; never descends into a model's weight directory.
        func scan(_ directory: URL, relative: String, depth: Int) {
            let config = directory.appendingPathComponent("config.json")
            if fm.fileExists(atPath: config.path) {
                guard let data = try? Data(contentsOf: config),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = object["model_type"] as? String, !type.isEmpty else { invalid += 1; return }
                let vision = object["vision_config"] is [String: Any] || object["vision_tower"] is String
                    || object["image_token_index"] != nil || type.contains("vl") || type.contains("vision")
                let id = relative.isEmpty ? directory.lastPathComponent : relative
                var capabilities: Set<String> = ["responses", "text", "text_file_input", "streaming", "response_storage", "previous_response_id", "background", "cancel"]
                if vision { capabilities.formUnion(["image_input", "pdf_input", "structured_output"]) }
                if Self.hasToolParser(at: directory, vision: vision) { capabilities.insert("tools") }
                found.append(ModelSpec(id: id, backend: vision ? .mlxVLM : .mlxLM,
                                       capabilities: capabilities, localPath: directory.path))
                return
            }
            guard depth < 5 else { return }
            do {
                for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isDirectory == true, values.isSymbolicLink != true { scan(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent, depth: depth + 1) }
                }
            } catch { failures += 1 }
        }
        scan(root, relative: "", depth: 0)
        models = found.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        if failures > 0 { scanMessage = "部分目录无法读取，请检查模型目录与访问权限。" }
        else if invalid > 0 { scanMessage = "已跳过 \(invalid) 个无效 config.json；需要有效的 model_type。" }
        else { scanMessage = nil }
    }

    /// Mirrors the installed MLX tokenizer parser markers without loading weights.
    /// Unknown templates remain text-only instead of letting MLX silently ignore tools.
    private static func hasToolParser(at directory: URL, vision: Bool) -> Bool {
        let config = (try? Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json")))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let jinja = try? String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        let template = jinja ?? config["chat_template"] as? String ?? ""
        let knownParsers: Set<String> = ["minimax_m2", "gemma4", "function_gemma", "longcat", "glm47", "pythonic", "qwen3_coder", "kimi_k2", "mistral", "json_tools"]
        if !vision, let parser = config["tool_parser_type"] as? String, knownParsers.contains(parser) { return true }
        let groups = [["<minimax:tool_call>"], ["<|tool_call>", "<tool_call|>"], ["<start_function_call>"],
                      ["<longcat_tool_call>"], ["<arg_key>"], ["<|tool_list_start|>"],
                      ["<tool_call>\\n<function="], ["<tool_call>\n<function="],
                      ["<|tool_calls_section_begin|>"], ["[TOOL_CALLS]"], ["<tool_call>", "tool_call.name"]]
        if groups.contains(where: { group in group.allSatisfy { template.contains($0) } }) { return true }
        let visionGroups = [["<atem:function_calls>", "<atem:invoke"], ["<|tool_call>"], ["<|START_ACTION|>"],
                            ["]<]minimax[>[<tool_call>"], ["<mm:think>"], ["<|tool_call_start|>", "<|tool_call_end|>"]]
        return vision && visionGroups.contains(where: { group in group.allSatisfy { template.contains($0) } })
    }

    func model(id: String?) -> ModelSpec? {
        guard let id, !id.isEmpty else { return defaultModel }
        return models.first { $0.id == id }
    }
}
