import Foundation
import CoreFoundation

/// Responses is the public protocol. Chat Completions is only the local MLX transport.
enum ResponsesAdapter {
    struct InvalidRequest: Error { let response: HTTPResponse }
    struct Prepared {
        var request: [String: Any]
        var chat: [String: Any]
        var inputItems: [[String: Any]]
    }

    static func identifier(_ prefix: String) -> String { prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    static func present(_ value: Any?) -> Bool { value != nil && !(value is NSNull) }
    static func keys(_ object: [String: Any], _ allowed: Set<String>, _ param: String) throws {
        for key in object.keys.sorted() where !allowed.contains(key) && present(object[key]) {
            throw unsupported("This property is not implemented by the local MLX gateway.", param.isEmpty ? key : param + "." + key)
        }
    }
    static func boolean(_ body: [String: Any], _ key: String, default fallback: Bool) throws -> Bool {
        guard present(body[key]) else { return fallback }
        guard let number = body[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw invalid("Expected a boolean.", key)
        }
        return number.boolValue
    }
    static func chatRequest(_ body: [String: Any]) throws -> [String: Any] { try prepare(body).chat }

    static func prepare(_ body: [String: Any], model: ModelSpec? = nil, history: [[String: Any]] = []) throws -> Prepared {
        try keys(body, ["model", "input", "instructions", "max_output_tokens", "temperature", "top_p", "stream", "store",
                        "metadata", "tools", "tool_choice", "parallel_tool_calls", "text", "previous_response_id",
                        "background", "truncation", "include", "stream_options"], "")
        guard let modelID = body["model"] as? String, !modelID.isEmpty else {
            throw invalid("Specify the model selected in MLX Gateway.", "model")
        }
        let stream = try boolean(body, "stream", default: false)
        let background = try boolean(body, "background", default: false)
        let store = try boolean(body, "store", default: !background)
        let parallel = try boolean(body, "parallel_tool_calls", default: true)
        if present(body["previous_response_id"]), !(body["previous_response_id"] is String) {
            throw invalid("Expected a response ID.", "previous_response_id")
        }
        if present(body["truncation"]), body["truncation"] as? String != "disabled" {
            throw unsupported("Automatic context truncation is not implemented; use disabled.", "truncation")
        }
        if present(body["include"]), (body["include"] as? [Any])?.isEmpty != true {
            throw unsupported("Additional include fields are not available from MLX.", "include")
        }
        if present(body["stream_options"]) {
            guard stream, let options = body["stream_options"] as? [String: Any] else {
                throw invalid("stream_options requires stream=true and an object.", "stream_options")
            }
            try keys(options, ["include_obfuscation"], "stream_options")
            if try boolean(options, "include_obfuscation", default: false) {
                throw unsupported("Stream obfuscation is not implemented.", "stream_options.include_obfuscation")
            }
        }
        var canonical: [[String: Any]]
        if let text = body["input"] as? String {
            canonical = [["type": "message", "role": "user", "content": text]]
        } else if let items = body["input"] as? [[String: Any]] { canonical = items }
        else if !present(body["input"]), !history.isEmpty { canonical = [] }
        else { throw invalid("Input must be a string or an array of input items.", "input") }
        canonical = history + canonical
        guard !canonical.isEmpty else { throw invalid("Input must contain at least one item.", "input") }
        var messages: [[String: Any]] = []
        if present(body["instructions"]) {
            guard let instructions = body["instructions"] as? String else {
                throw unsupported("Only string instructions are supported.", "instructions")
            }
            messages.append(["role": "system", "content": instructions])
        }
        var pending = Set<String>()
        var seenCalls = Set<String>()
        for index in canonical.indices {
            var item = canonical[index]
            if present(item["type"]), !(item["type"] is String) { throw invalid("Expected an input item type string.", "input.type") }
            let type = item["type"] as? String ?? "message"
            switch type {
            case "message":
                try keys(item, ["type", "id", "status", "role", "content"], "input")
                guard let role = item["role"] as? String, ["user", "assistant", "system", "developer"].contains(role) else {
                    throw invalid("Input messages require a valid role.", "input")
                }
                let content = try content(item["content"], role: role, vision: model?.backend == .mlxVLM)
                if role == "assistant", let last = messages.indices.last, messages[last]["reasoning_content"] != nil,
                   messages[last]["content"] as? String == "" { messages[last]["content"] = content }
                else { messages.append(["role": role == "developer" ? "system" : role, "content": content]) }
                item["type"] = "message"
                if let text = item["content"] as? String {
                    item["content"] = [["type": role == "assistant" ? "output_text" : "input_text", "text": text]]
                }
                if var parts = item["content"] as? [[String: Any]] {
                    for partIndex in parts.indices {
                        if role == "assistant" {
                            parts[partIndex]["type"] = "output_text"
                            if !present(parts[partIndex]["annotations"]) { parts[partIndex]["annotations"] = [] }
                        } else if parts[partIndex]["type"] as? String == "input_image", !present(parts[partIndex]["detail"]) {
                            parts[partIndex]["detail"] = "auto"
                        }
                    }
                    item["content"] = parts
                }
            case "function_call":
                try keys(item, ["type", "id", "status", "call_id", "name", "arguments"], "input")
                guard let callID = item["call_id"] as? String, !callID.isEmpty,
                      let name = item["name"] as? String, validName(name),
                      let arguments = item["arguments"] as? String,
                      JSONSupport.object(from: Data(arguments.utf8)) != nil, seenCalls.insert(callID).inserted else {
                    throw invalid("Function calls require a unique call_id, name and JSON object arguments.", "input")
                }
                pending.insert(callID)
                let call: [String: Any] = ["id": callID, "type": "function", "function": ["name": name, "arguments": arguments]]
                if let last = messages.indices.last, messages[last]["role"] as? String == "assistant" {
                    var calls = messages[last]["tool_calls"] as? [[String: Any]] ?? []
                    calls.append(call); messages[last]["tool_calls"] = calls
                } else { messages.append(["role": "assistant", "content": "", "tool_calls": [call]]) }
            case "function_call_output":
                try keys(item, ["type", "id", "status", "call_id", "output"], "input")
                guard let callID = item["call_id"] as? String, pending.remove(callID) != nil else {
                    throw invalid("Function output must match an unresolved call_id in the input or previous response.", "input")
                }
                let output = try content(item["output"], role: "tool", vision: false)
                messages.append(["role": "tool", "tool_call_id": callID, "content": output])
            case "reasoning":
                try keys(item, ["type", "id", "status", "summary", "content"], "input")
                guard (item["summary"] as? [Any] ?? []).isEmpty,
                      let parts = item["content"] as? [[String: Any]],
                      parts.allSatisfy({ $0["type"] as? String == "reasoning_text" && $0["text"] is String && Set($0.keys).isSubset(of: ["type", "text"]) }) else {
                    throw unsupported("Only unencrypted local reasoning_text history is supported.", "input")
                }
                item["summary"] = []
                messages.append(["role": "assistant", "content": "", "reasoning_content": parts.map { $0["text"] as! String }.joined()])
            default: throw unsupported("This input item type is not executable by the local MLX backend.", "input")
            }
            if present(item["id"]), !(item["id"] is String) { throw invalid("Expected an item ID string.", "input.id") }
            if !present(item["id"]) { item["id"] = identifier(type == "message" ? "msg_" : "item_") }
            if !present(item["status"]) { item["status"] = "completed" }
            guard let status = item["status"] as? String, ["in_progress", "completed", "incomplete"].contains(status) else {
                throw invalid("Invalid input item status.", "input.status")
            }
            canonical[index] = item
        }
        guard pending.isEmpty else { throw invalid("Supply outputs for all pending function calls before requesting another response.", "input") }
        var normalized = body
        normalized["stream"] = stream; normalized["background"] = background; normalized["store"] = store
        normalized["parallel_tool_calls"] = parallel
        var chat: [String: Any] = ["model": modelID, "messages": messages, "stream": stream,
                                  "temperature": 1.0, "top_p": 1.0, "max_tokens": 512]
        for (key, target, lower, upper) in [("max_output_tokens", "max_tokens", 1.0, Double(Int32.max)),
                                          ("temperature", "temperature", 0.0, 2.0), ("top_p", "top_p", 0.0, 1.0)] {
            if present(body[key]) {
                guard let number = body[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, (lower...upper).contains(number.doubleValue),
                      key != "max_output_tokens" || number.doubleValue.rounded() == number.doubleValue else {
                    throw invalid("Invalid numeric value.", key)
                }
                chat[target] = number
            }
            normalized[key] = chat[target]
        }
        if present(body["metadata"]) {
            guard let entries = body["metadata"] as? [String: String], entries.count <= 16,
                  entries.allSatisfy({ $0.key.count <= 64 && $0.value.count <= 512 }) else {
                throw invalid("Metadata must contain at most 16 string pairs (64/512 characters).", "metadata")
            }
        }
        var tools: [[String: Any]] = []
        if present(body["tools"]) {
            guard let definitions = body["tools"] as? [[String: Any]], definitions.count <= 128 else {
                throw invalid("Expected an array of up to 128 function definitions.", "tools")
            }
            var names = Set<String>()
            for definition in definitions {
                guard definition["type"] as? String == "function" else {
                    throw unsupported("Hosted tools, MCP, custom tools, search, computer use and media generation are unavailable.", "tools")
                }
                try keys(definition, ["type", "name", "description", "parameters", "strict"], "tools")
                guard let name = definition["name"] as? String, validName(name), names.insert(name).inserted,
                      !present(definition["description"]) || definition["description"] is String,
                      !present(definition["parameters"]) || definition["parameters"] is [String: Any] else {
                    throw invalid("Invalid or duplicate function definition.", "tools")
                }
                if try boolean(definition, "strict", default: false) {
                    throw unsupported("MLX tool generation has no strict schema constraint; use strict=false. VLM text.format supports constrained JSON.", "tools.strict")
                }
                var tool = definition; tool["strict"] = false
                tool["parameters"] = definition["parameters"] ?? ["type": "object", "properties": [:]]
                tools.append(tool)
            }
        }
        if !tools.isEmpty, let model, !model.capabilities.contains("tools") {
            throw unsupported("This model's tokenizer has no recognized MLX tool parser.", "tools")
        }
        let selection = body["tool_choice"] ?? "auto"
        var selectedTools = tools
        var requiredName: String?
        var required = false
        if let mode = selection as? String {
            guard ["none", "auto", "required"].contains(mode) else { throw invalid("Invalid tool choice.", "tool_choice") }
            required = mode == "required"
            if mode == "none" { selectedTools = [] }
        } else if let choice = selection as? [String: Any], choice["type"] as? String == "function" {
            try keys(choice, ["type", "name"], "tool_choice")
            guard let name = choice["name"] as? String, tools.contains(where: { $0["name"] as? String == name }) else {
                throw invalid("Tool choice must name a defined function.", "tool_choice")
            }
            requiredName = name; required = true
            selectedTools = tools.filter { $0["name"] as? String == name }
        } else { throw unsupported("Only auto, none, required or a named function choice is supported.", "tool_choice") }
        if required, selectedTools.isEmpty { throw invalid("Required tool choice needs at least one function.", "tool_choice") }
        if !selectedTools.isEmpty {
            chat["tools"] = selectedTools.map { tool -> [String: Any] in
                var function = tool; function.removeValue(forKey: "type")
                return ["type": "function", "function": function]
            }
        }
        // mlx_lm does not read tool_choice / parallel_tool_calls. Apply the policy to
        // available tools and prompt, then validate the actual returned calls as well.
        if required || !parallel {
            var instruction = required ? "You must call \(requiredName ?? "one of the provided functions") in this response." : ""
            if !parallel { instruction += " Call at most one function in this response." }
            messages.insert(["role": "system", "content": instruction], at: 0)
            chat["messages"] = messages
        }
        if model?.backend == .mlxVLM {
            chat["tool_choice"] = requiredName.map { ["type": "function", "function": ["name": $0]] as Any } ?? selection
        }
        normalized["tools"] = tools; normalized["tool_choice"] = selection
        if present(body["text"]) {
            guard let text = body["text"] as? [String: Any] else { throw invalid("Expected a text object.", "text") }
            try keys(text, ["format"], "text")
            if present(text["format"]) {
                guard let format = text["format"] as? [String: Any], let type = format["type"] as? String else {
                    throw invalid("Expected text.format.type.", "text.format")
                }
                switch type {
                case "text": try keys(format, ["type"], "text.format")
                case "json_object", "json_schema":
                    guard model?.backend == .mlxVLM else {
                        throw unsupported("Constrained JSON output requires mlx_vlm with llguidance; mlx_lm does not implement response_format.", "text.format")
                    }
                    if type == "json_object" {
                        try keys(format, ["type"], "text.format"); chat["response_format"] = format
                    } else {
                        try keys(format, ["type", "name", "description", "schema", "strict"], "text.format")
                        guard let name = format["name"] as? String, validName(name), format["schema"] is [String: Any],
                              !present(format["description"]) || format["description"] is String else {
                            throw invalid("JSON schema format requires a name and schema object.", "text.format")
                        }
                        _ = try boolean(format, "strict", default: true)
                        var schema = format; schema.removeValue(forKey: "type")
                        chat["response_format"] = ["type": "json_schema", "json_schema": schema]
                    }
                    if !selectedTools.isEmpty { throw unsupported("Combining constrained text and function generation is not supported by MLX.", "text.format") }
                default: throw unsupported("Unsupported text format.", "text.format")
                }
            }
        }
        if stream { chat["stream_options"] = ["include_usage": true] }
        return Prepared(request: normalized, chat: chat, inputItems: canonical)
    }

    private static func content(_ value: Any?, role: String, vision: Bool) throws -> Any {
        if let text = value as? String { return text }
        guard let parts = value as? [[String: Any]], !parts.isEmpty else { throw invalid("Message content must contain text or images.", "input") }
        var mapped: [[String: Any]] = []
        var hasImage = false
        for part in parts {
            switch part["type"] as? String {
            case "input_text", "output_text":
                if part["type"] as? String == "output_text", role != "assistant" { throw invalid("output_text is only valid in assistant history.", "input") }
                try keys(part, ["type", "text", "annotations", "logprobs"], "input.content")
                guard let text = part["text"] as? String else { throw invalid("Expected a text string.", "input") }
                for field in ["annotations", "logprobs"] where present(part[field]) {
                    guard (part[field] as? [Any])?.isEmpty == true else { throw unsupported("Non-empty annotations and logprobs cannot be replayed.", "input.content.\(field)") }
                }
                mapped.append(["type": "text", "text": text])
            case "input_file":
                guard role == "user" else { throw unsupported("Inline file input is only supported in user messages.", "input") }
                let fileParts = try ResponsesFiles.parts(part, vision: vision)
                hasImage = hasImage || fileParts.contains { $0["type"] as? String == "image_url" }
                mapped += fileParts
            case "input_image":
                guard vision, role == "user" else { throw unsupported("Image input is supported only in user messages to mlx_vlm.", "input") }
                try keys(part, ["type", "image_url", "detail"], "input.content")
                guard !present(part["detail"]) || part["detail"] as? String == "auto" else {
                    throw unsupported("MLX controls image resolution; only detail=auto is supported.", "input.content.detail")
                }
                guard let url = part["image_url"] as? String, validImageURL(url) else {
                    throw invalid("Use an HTTP(S) image URL or base64 data:image URL; local file paths and file IDs are not accepted.", "input.content.image_url")
                }
                hasImage = true; mapped.append(["type": "image_url", "image_url": ["url": url]])
            default: throw unsupported("Audio, video, refusal and this content type are not supported.", "input.content")
            }
        }
        return hasImage ? mapped : mapped.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    private static func validImageURL(_ value: String) -> Bool {
        if value.hasPrefix("data:image/") {
            guard let comma = value.firstIndex(of: ","), value[..<comma].hasSuffix(";base64"),
                  ["data:image/png;base64", "data:image/jpeg;base64", "data:image/webp;base64", "data:image/gif;base64"].contains(String(value[..<comma])) else { return false }
            return Data(base64Encoded: String(value[value.index(after: comma)...]))?.isEmpty == false
        }
        guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }
    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }
    }

    static func skeleton(request: [String: Any], id: String = identifier("resp_"), status: String = "in_progress") -> [String: Any] {
        ["id": id, "object": "response", "created_at": Int(Date().timeIntervalSince1970), "completed_at": NSNull(),
         "status": status, "error": NSNull(), "incomplete_details": NSNull(), "model": request["model"] ?? NSNull(), "output": [],
         "instructions": request["instructions"] ?? NSNull(), "max_output_tokens": request["max_output_tokens"] ?? 512,
         "temperature": request["temperature"] ?? 1.0, "top_p": request["top_p"] ?? 1.0,
         "tools": request["tools"] ?? [], "tool_choice": request["tool_choice"] ?? "auto", "parallel_tool_calls": request["parallel_tool_calls"] ?? true,
         "text": request["text"] ?? ["format": ["type": "text"]], "store": request["store"] ?? true,
         "background": request["background"] ?? false, "previous_response_id": request["previous_response_id"] ?? NSNull(),
         "truncation": "disabled", "metadata": request["metadata"] ?? [:], "usage": NSNull()]
    }
    static func usage(_ value: Any?) -> Any {
        guard let usage = value as? [String: Any], let input = usage["prompt_tokens"] as? Int, let output = usage["completion_tokens"] as? Int,
              input >= 0, output >= 0, input <= Int.max - output else { return NSNull() }
        return ["input_tokens": input, "output_tokens": output, "total_tokens": input + output,
                "input_tokens_details": ["cached_tokens": (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0,
                                         "cache_write_tokens": (usage["prompt_tokens_details"] as? [String: Any])?["cache_write_tokens"] as? Int ?? 0],
                "output_tokens_details": ["reasoning_tokens": (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0]]
    }
    static func validateOutput(_ output: [[String: Any]], request: [String: Any]) throws {
        let calls = output.filter { $0["type"] as? String == "function_call" }
        let choice = request["tool_choice"] ?? "auto"
        let names = Set((request["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        let requiredName = (choice as? [String: Any])?["name"] as? String
        let required = choice as? String == "required" || requiredName != nil
        guard (!required || !calls.isEmpty), (choice as? String != "none" || calls.isEmpty),
              request["parallel_tool_calls"] as? Bool != false || calls.count <= 1 else {
            throw InvalidRequest(response: .error(statusCode: 502, message: "MLX did not satisfy the requested tool selection policy.", code: "tool_policy_violation"))
        }
        var ids = Set<String>()
        for call in calls {
            guard let name = call["name"] as? String, names.contains(name), requiredName == nil || requiredName == name,
                  let arguments = call["arguments"] as? String, JSONSupport.object(from: Data(arguments.utf8)) != nil,
                  let callID = call["call_id"] as? String, !callID.isEmpty, ids.insert(callID).inserted else {
                throw InvalidRequest(response: .error(statusCode: 502, message: "MLX returned an invalid or unrequested function call.", code: "invalid_tool_call"))
            }
        }
    }
    static func response(from data: Data, request: [String: Any]) -> HTTPResponse {
        do {
            guard let chat = JSONSupport.object(from: data), let choices = chat["choices"] as? [[String: Any]], choices.count == 1,
                  let choice = choices.first, let message = choice["message"] as? [String: Any], let finish = choice["finish_reason"] as? String,
                  ["stop", "length", "content_filter", "tool_calls"].contains(finish) else { throw malformed() }
            guard !present(message["refusal"]), !present(message["audio"]), !present(message["function_call"]) else { throw malformed() }
            var output: [[String: Any]] = []
            let itemStatus = ["stop", "tool_calls"].contains(finish) ? "completed" : "incomplete"
            if let reasoning = message["reasoning"] as? String ?? message["reasoning_content"] as? String, !reasoning.isEmpty {
                output.append(["id": identifier("rs_"), "type": "reasoning", "status": itemStatus, "summary": [], "content": [["type": "reasoning_text", "text": reasoning]]])
            }
            if present(message["content"]), !(message["content"] is String) { throw malformed() }
            if let text = message["content"] as? String, !text.isEmpty {
                output.append(["id": identifier("msg_"), "type": "message", "role": "assistant", "status": itemStatus,
                               "content": [["type": "output_text", "text": text, "annotations": [], "logprobs": []]]])
            }
            if present(message["tool_calls"]) {
                guard let calls = message["tool_calls"] as? [[String: Any]] else { throw malformed() }
                for call in calls {
                    guard call["type"] as? String == "function", let id = call["id"] as? String,
                          let function = call["function"] as? [String: Any], let name = function["name"] as? String,
                          let arguments = function["arguments"] as? String else { throw malformed() }
                    output.append(["id": identifier("fc_"), "type": "function_call", "status": itemStatus, "call_id": id, "name": name, "arguments": arguments])
                }
            }
            if finish == "tool_calls", !output.contains(where: { $0["type"] as? String == "function_call" }) { throw malformed() }
            if itemStatus == "completed" { try validateOutput(output, request: request) }
            var result = skeleton(request: request)
            result["output"] = output; result["status"] = itemStatus
            result["usage"] = usage(chat["usage"])
            if itemStatus == "completed" { result["completed_at"] = Int(Date().timeIntervalSince1970) }
            else { result["incomplete_details"] = ["reason": finish == "length" ? "max_output_tokens" : "content_filter"] }
            return .json(object: result)
        } catch let error as InvalidRequest { return error.response }
        catch { return malformed().response }
    }
    static func malformed() -> InvalidRequest { InvalidRequest(response: .error(statusCode: 502, message: "MLX returned an invalid completion. See local service logs.", code: "invalid_backend_response")) }
    static func unsupported(_ message: String, _ param: String) -> InvalidRequest { InvalidRequest(response: .unsupported(message, param: param)) }
    static func invalid(_ message: String, _ param: String) -> InvalidRequest {
        InvalidRequest(response: .json(statusCode: 400, object: ["error": ["message": message, "type": "invalid_request_error", "code": "invalid_value", "param": param]]))
    }
}
