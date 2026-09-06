import Foundation
import CoreFoundation

/// The public protocol is Responses. Chat Completions is an internal MLX transport only.
enum ResponsesAdapter {
    struct InvalidRequest: Error {
        let response: HTTPResponse
    }

    static func chatRequest(_ body: [String: Any]) throws -> [String: Any] {
        let supported: Set<String> = ["model", "input", "instructions", "max_output_tokens",
                                      "temperature", "top_p", "stream", "store", "metadata"]
        for key in body.keys.sorted() where !supported.contains(key) && !(body[key] is NSNull) {
            throw unsupported("This Responses parameter is not implemented.", key)
        }
        for key in ["stream", "store"] {
            if let value = body[key], !(value is NSNull) {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw invalid("Expected a boolean.", key)
                }
                if number.boolValue {
                    throw unsupported("Only non-streaming, stateless Responses are supported; use false.", key)
                }
            }
        }
        guard let model = body["model"] as? String, !model.isEmpty else {
            throw invalid("Specify the model selected in MLX Gateway.", "model")
        }
        var messages: [[String: Any]] = []
        if let instructions = body["instructions"], !(instructions is NSNull) {
            guard let text = instructions as? String else {
                throw unsupported("Only text instructions are supported.", "instructions")
            }
            messages.append(["role": "system", "content": text])
        }
        if let text = body["input"] as? String {
            messages.append(["role": "user", "content": text])
        } else if let items = body["input"] as? [[String: Any]], !items.isEmpty {
            for item in items {
                if let type = item["type"], type as? String != "message" {
                    throw unsupported("Only text message input items are supported.", "input")
                }
                guard let role = item["role"] as? String,
                      ["user", "assistant", "system", "developer"].contains(role) else {
                    throw invalid("Input messages require a valid role.", "input")
                }
                let allowed: Set<String> = ["type", "role", "content", "id", "status"]
                guard Set(item.keys).isSubset(of: allowed) else {
                    throw unsupported("Unsupported message property.", "input")
                }
                messages.append(["role": role == "developer" ? "system" : role,
                                 "content": try textContent(item["content"], role: role)])
            }
        } else {
            throw invalid("Input must be a string or a non-empty array of text messages.", "input")
        }
        var chat: [String: Any] = ["model": model, "messages": messages, "stream": false,
                                  "temperature": 1.0, "top_p": 1.0, "max_tokens": 512]
        for (key, target, lower, upper) in [("max_output_tokens", "max_tokens", 1.0, Double(Int32.max)),
                                          ("temperature", "temperature", 0.0, 2.0),
                                          ("top_p", "top_p", 0.0, 1.0)] {
            if let value = body[key], !(value is NSNull) {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, (lower...upper).contains(number.doubleValue),
                      key != "max_output_tokens" || number.doubleValue.rounded() == number.doubleValue else {
                    throw invalid("Invalid numeric value.", key)
                }
                chat[target] = number
            }
        }
        if let metadata = body["metadata"], !(metadata is NSNull) {
            guard let entries = metadata as? [String: String], entries.count <= 16,
                  entries.allSatisfy({ $0.key.count <= 64 && $0.value.count <= 512 }) else {
                throw invalid("Metadata must contain at most 16 string pairs (64/512 characters).", "metadata")
            }
        }
        return chat
    }

    private static func textContent(_ value: Any?, role: String) throws -> String {
        if let text = value as? String { return text }
        guard let parts = value as? [[String: Any]], !parts.isEmpty else {
            throw invalid("Message content must contain text.", "input")
        }
        return try parts.map { part in
            let type = part["type"] as? String
            guard type == "input_text" || (role == "assistant" && type == "output_text") else {
                throw unsupported("Images, audio, files, refusals and tool items are not implemented.", "input")
            }
            guard let text = part["text"] as? String else {
                throw invalid("Text content requires a text string.", "input")
            }
            let allowed: Set<String> = ["type", "text", "annotations", "logprobs"]
            guard Set(part.keys).isSubset(of: allowed) else {
                throw unsupported("Unsupported text property.", "input")
            }
            return text
        }.joined(separator: "\n")
    }

    static func response(from data: Data, request: [String: Any]) -> HTTPResponse {
        guard let chat = JSONSupport.object(from: data),
              let choices = chat["choices"] as? [[String: Any]], let choice = choices.first,
              let message = choice["message"] as? [String: Any],
              message["tool_calls"] == nil || message["tool_calls"] is NSNull || (message["tool_calls"] as? [Any])?.isEmpty == true,
              let finish = choice["finish_reason"] as? String,
              ["stop", "length", "content_filter"].contains(finish),
              message["content"] is String || (finish != "stop" && (message["content"] == nil || message["content"] is NSNull)) else {
            return .error(statusCode: 502, message: "MLX returned an invalid text completion. See local service logs.", code: "invalid_backend_response")
        }
        // Thinking models may exhaust their budget before producing any final text.
        let text = message["content"] as? String ?? ""
        let incomplete = finish != "stop"
        let output: [[String: Any]] = text.isEmpty ? [] : [
            ["id": "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
             "type": "message", "role": "assistant", "status": incomplete ? "incomplete" : "completed",
             "content": [["type": "output_text", "text": text, "annotations": []]]]
        ]
        var result: [String: Any] = [
            "id": "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "object": "response", "created_at": Int(Date().timeIntervalSince1970),
            "status": incomplete ? "incomplete" : "completed",
            "error": NSNull(),
            "incomplete_details": incomplete ? ["reason": finish == "length" ? "max_output_tokens" : "content_filter"] : NSNull(),
            "model": request["model"] ?? NSNull(),
            "output": output,
            "instructions": request["instructions"] ?? NSNull(),
            "max_output_tokens": request["max_output_tokens"] ?? 512,
            "temperature": request["temperature"] ?? 1.0, "top_p": request["top_p"] ?? 1.0,
            "tools": [], "tool_choice": "none", "parallel_tool_calls": false,
            "text": ["format": ["type": "text"]], "store": false,
            "previous_response_id": NSNull(), "truncation": "disabled",
            "metadata": request["metadata"] ?? [:], "usage": NSNull()
        ]
        if let usage = chat["usage"] as? [String: Any],
           let input = usage["prompt_tokens"] as? Int, let output = usage["completion_tokens"] as? Int {
            let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
            let outputDetails = usage["completion_tokens_details"] as? [String: Any]
            result["usage"] = ["input_tokens": input, "output_tokens": output, "total_tokens": input + output,
                               "input_tokens_details": ["cached_tokens": promptDetails?["cached_tokens"] as? Int ?? 0],
                               "output_tokens_details": ["reasoning_tokens": outputDetails?["reasoning_tokens"] as? Int ?? 0]]
        }
        return .json(object: result)
    }

    private static func unsupported(_ message: String, _ param: String) -> InvalidRequest {
        InvalidRequest(response: .unsupported(message, param: param))
    }

    private static func invalid(_ message: String, _ param: String) -> InvalidRequest {
        InvalidRequest(response: .json(statusCode: 400, object: ["error": [
            "message": message, "type": "invalid_request_error", "code": "invalid_value", "param": param
        ]]))
    }
}
