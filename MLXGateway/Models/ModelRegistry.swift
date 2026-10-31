import Foundation
import CoreFoundation

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

enum ContextLimitStore {
    static let inputMinimum = 256
    static let outputMinimum = 1
    static let maximum = 1_048_576
    static let maxDigits = 7
    struct Fields: Equatable { var input = ""; var output = "" }
    struct Limits: Equatable { var input: Int?; var output: Int? }
    enum FieldDraft: Equatable { case unlimited, limited(Int), invalid }
    enum SaveError: Error { case invalidInput, invalidOutput }

    static func digitsOnly(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(maxDigits))
    }

    static func parse(_ text: String, minimum: Int) -> FieldDraft {
        let trimmed = digitsOnly(text)
        if trimmed.isEmpty { return .unlimited }
        guard let value = Int(trimmed), (minimum...maximum).contains(value) else { return .invalid }
        return .limited(value)
    }

    static func load(from url: URL?) -> (limits: [String: Limits], message: String?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return ([:], nil) }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["limits"] as? [[String: Any]] else {
            return ([:], "text-service/context-limits.json 无法读取，已忽略上下文限制。")
        }
        var limits: [String: Limits] = [:]
        var skipped = 0
        for row in rows {
            guard let id = row["model"] as? String, !id.isEmpty, limits[id] == nil else { skipped += 1; continue }
            let inputText = row["max_input_tokens"].map { String(describing: $0) } ?? row["context_length"].map { String(describing: $0) } ?? ""
            let outputText = row["max_output_tokens"].map { String(describing: $0) } ?? ""
            let input = parse(inputText, minimum: inputMinimum)
            let output = parse(outputText, minimum: outputMinimum)
            if input == .invalid || output == .invalid { skipped += 1 }
            let parsedInput: Int? = if case .limited(let value) = input { value } else { nil }
            let parsedOutput: Int? = if case .limited(let value) = output { value } else { nil }
            let parsed = Limits(input: parsedInput, output: parsedOutput)
            if parsed.input != nil || parsed.output != nil { limits[id] = parsed }
        }
        return (limits, skipped > 0 ? "已忽略 \(skipped) 条无效的上下文限制。" : nil)
    }

    /// A blank field clears that side. A missing model id keeps its stored limits. Any invalid field writes nothing.
    static func save(drafts: [String: Fields], to url: URL) throws {
        var limits = load(from: url).limits
        for (id, fields) in drafts where !id.isEmpty {
            let input = parse(fields.input, minimum: inputMinimum)
            let output = parse(fields.output, minimum: outputMinimum)
            if input == .invalid { throw SaveError.invalidInput }
            if output == .invalid { throw SaveError.invalidOutput }
            var next = limits[id] ?? Limits()
            next.input = if case .limited(let value) = input { value } else { nil }
            next.output = if case .limited(let value) = output { value } else { nil }
            if next.input == nil, next.output == nil { limits.removeValue(forKey: id) }
            else { limits[id] = next }
        }
        let rows: [[String: Any]] = limits.keys.sorted().map { id in
            var row: [String: Any] = ["model": id]
            if let input = limits[id]?.input { row["max_input_tokens"] = input; row["context_length"] = input }
            if let output = limits[id]?.output { row["max_output_tokens"] = output }
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: ["limits": rows], options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

struct ModelSpec: Identifiable, Equatable, Sendable {
    let id: String
    let backend: BackendKind
    let capabilities: Set<String>
    let localPath: String
    /// Input cap. Nil means no declared input limit. This is not the architecture window.
    let contextLength: Int?
    /// Output cap. Nil means the request's own max_output_tokens is used, defaulting to 512.
    let maxOutputTokens: Int?
    init(id: String, backend: BackendKind, capabilities: Set<String>, localPath: String, contextLength: Int? = nil, maxOutputTokens: Int? = nil) {
        self.id = id
        self.backend = backend
        self.capabilities = capabilities
        self.localPath = localPath
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
    }
    var displayName: String { URL(fileURLWithPath: localPath).lastPathComponent }
    var subtitle: String {
        let base = backend == .mlxVLM ? "视觉模型 · 文本与图片" : "文本模型 · MLX"
        var parts: [String] = []
        if let contextLength { parts.append("输入 \(contextLength)") }
        if let maxOutputTokens { parts.append("输出 \(maxOutputTokens)") }
        return parts.isEmpty ? base : base + " · " + parts.joined(separator: " · ")
    }
    var publicDescription: [String: Any] {
        // Publish input as context_length only. Do not also publish max_input_tokens:
        // Hermes uses the first context-like key it finds.
        var description: [String: Any] = ["id": id, "object": "model", "created": 0, "owned_by": "local",
         "capabilities": Array(capabilities).sorted(), "backend": backend.rawValue,
         "limitations": ["function strict=false; requires recognized tokenizer parser",
                         backend == .mlxVLM ? "JSON requires llguidance; images use detail=auto" : "No image/PDF input or constrained JSON",
                         "Responses are retained in gateway process memory; restart clears history"]]
        var notes = description["limitations"] as? [String] ?? []
        if let contextLength {
            description["context_length"] = contextLength
            notes.append("max input is context_length \(contextLength) tokens. This is not the architecture context window and is not shared with the output cap.")
        }
        if let maxOutputTokens {
            description["max_output_tokens"] = maxOutputTokens
            notes.append("max output is \(maxOutputTokens) tokens. An explicit max_output_tokens above this cap is rejected; an omitted value is clamped to the cap.")
        }
        description["limitations"] = notes
        return description
    }
}

struct ModelRegistry: Sendable {
    static var shared: ModelRegistry {
        let paths = RuntimePaths.saved
        return ModelRegistry(modelsRoot: paths.models, contextLimitsURL: contextLimitsURL(runtimeDirectory: paths.directory))
    }
    let models: [ModelSpec]
    let scanMessage: String?
    var defaultModel: ModelSpec? { models.first }

    static func contextLimitsURL(runtimeDirectory: String) -> URL {
        URL(fileURLWithPath: RuntimePaths.expand(runtimeDirectory)).appendingPathComponent("text-service/context-limits.json")
    }

    init(models: [ModelSpec], scanMessage: String? = nil) {
        self.models = models
        self.scanMessage = scanMessage
    }

    init(modelsRoot: String, contextLimitsURL: URL? = nil) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: RuntimePaths.expand(modelsRoot)).standardizedFileURL
        let loadedLimits = ContextLimitStore.load(from: contextLimitsURL)
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
                                       capabilities: capabilities, localPath: directory.path,
                                       contextLength: loadedLimits.limits[id]?.input,
                                       maxOutputTokens: loadedLimits.limits[id]?.output))
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
        var notes: [String] = []
        if failures > 0 { notes.append("部分目录无法读取，请检查模型目录与访问权限。") }
        else if invalid > 0 { notes.append("已跳过 \(invalid) 个无效 config.json；需要有效的 model_type。") }
        if let limitMessage = loadedLimits.message { notes.append(limitMessage) }
        scanMessage = notes.isEmpty ? nil : notes.joined(separator: " ")
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
