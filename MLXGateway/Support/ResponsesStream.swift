import Foundation

/// Incremental SSE parser: buffers only an unfinished line/event, including split UTF-8.
struct SSEParser {
    private var buffer = Data()
    private var lines: [Data] = []
    private var eventBytes = 0
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count + eventBytes <= 8 * 1024 * 1024 else { throw ResponsesAdapter.malformed() }
        var events: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 13 { line.removeLast() }
            if line.isEmpty {
                if !lines.isEmpty {
                    var event = Data()
                    for (index, line) in lines.enumerated() { if index > 0 { event.append(10) }; event.append(line) }
                    events.append(event)
                }
                lines.removeAll(keepingCapacity: true); eventBytes = 0
            } else if line.starts(with: Data("data:".utf8)) {
                line.removeFirst(5)
                if line.first == 32 { line.removeFirst() }
                eventBytes += line.count
                lines.append(line)
            }
        }
        return events
    }
    var isAtBoundary: Bool { buffer.isEmpty && lines.isEmpty }
}

/// Only used on the gateway queue. Every delta emitted here comes from a received MLX delta.
final class ResponsesStream: @unchecked Sendable {
    private var parser = SSEParser()
    private let request: [String: Any]
    private(set) var response: [String: Any]
    private(set) var sequence = 0
    private var output: [[String: Any]] = []
    private var announced = Set<Int>()
    private var toolIndices: [Int: Int] = [:]
    private var finishReason: String?
    private var ended = false
    private var outputBytes = 0
    typealias Event = (data: Data, content: Bool)
    init(request: [String: Any], response: [String: Any]) { self.request = request; self.response = response }
    private func event(_ type: String, _ fields: [String: Any] = [:], content: Bool = false) -> Event {
        var value = fields; value["type"] = type; value["sequence_number"] = sequence; sequence += 1
        let json = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        var data = Data("event: \(type)\ndata: ".utf8); data.append(json); data.append(Data("\n\n".utf8))
        return (data, content)
    }
    func start() -> [Event] {
        let created = event("response.created", ["response": response])
        response["status"] = "in_progress"
        return [created, event("response.in_progress", ["response": response])]
    }
    private func textIndex(reasoning: Bool) -> Int {
        let type = reasoning ? "reasoning" : "message"
        if let index = output.firstIndex(where: { $0["type"] as? String == type }) { return index }
        var item: [String: Any] = ["id": ResponsesAdapter.identifier(reasoning ? "rs_" : "msg_"), "type": type, "status": "in_progress", "content": []]
        if reasoning { item["summary"] = [] } else { item["role"] = "assistant" }
        output.append(item); return output.count - 1
    }
    private func announce(_ index: Int) -> [Event] {
        guard announced.insert(index).inserted else { return [] }
        return [event("response.output_item.added", ["output_index": index, "item": output[index]])]
    }
    private func appendText(_ text: String, reasoning: Bool) -> [Event] {
        guard !text.isEmpty else { return [] }
        let index = textIndex(reasoning: reasoning)
        var events = announce(index)
        let type = reasoning ? "reasoning_text" : "output_text"
        var parts = output[index]["content"] as? [[String: Any]] ?? []
        let fields: [String: Any] = ["output_index": index, "item_id": output[index]["id"]!, "content_index": 0]
        if parts.isEmpty {
            var part: [String: Any] = ["type": type, "text": ""]
            if !reasoning { part["annotations"] = []; part["logprobs"] = [] }
            parts = [part]
            if !reasoning { events.append(event("response.content_part.added", fields.merging(["part": part]) { _, new in new })) }
        }
        parts[0]["text"] = (parts[0]["text"] as? String ?? "") + text
        output[index]["content"] = parts
        events.append(event("response.\(type).delta", fields.merging(["delta": text, "logprobs": []]) { _, new in new }, content: true))
        return events
    }
    func append(_ bytes: Data) throws -> [Event] {
        var events: [Event] = []
        for frame in try parser.append(bytes) {
            guard !ended else { throw ResponsesAdapter.malformed() }
            if frame == Data("[DONE]".utf8) { ended = true; continue }
            guard let chunk = JSONSupport.object(from: frame), chunk["error"] == nil,
                  let choices = chunk["choices"] as? [[String: Any]], choices.count <= 1 else { throw ResponsesAdapter.malformed() }
            if ResponsesAdapter.present(chunk["usage"]) { response["usage"] = ResponsesAdapter.usage(chunk["usage"]) }
            guard let choice = choices.first else { continue }
            guard (choice["index"] as? Int ?? 0) == 0, let delta = choice["delta"] as? [String: Any] else { throw ResponsesAdapter.malformed() }
            guard finishReason == nil, !ResponsesAdapter.present(delta["refusal"]), !ResponsesAdapter.present(delta["audio"]),
                  !ResponsesAdapter.present(delta["function_call"]) else { throw ResponsesAdapter.malformed() }
            if let reason = choice["finish_reason"] as? String {
                guard finishReason == nil, ["stop", "length", "content_filter", "tool_calls"].contains(reason) else { throw ResponsesAdapter.malformed() }
                finishReason = reason
            }
            for key in ["content", "reasoning", "reasoning_content"] where ResponsesAdapter.present(delta[key]) {
                guard delta[key] is String else { throw ResponsesAdapter.malformed() }
            }
            let reasoning = delta["reasoning"] as? String ?? delta["reasoning_content"] as? String ?? ""
            let text = delta["content"] as? String ?? ""
            outputBytes += reasoning.utf8.count + text.utf8.count
            events += appendText(reasoning, reasoning: true)
            events += appendText(text, reasoning: false)
            if ResponsesAdapter.present(delta["tool_calls"]) {
                guard let calls = delta["tool_calls"] as? [[String: Any]] else { throw ResponsesAdapter.malformed() }
                for (position, call) in calls.enumerated() {
                    let key = call["index"] as? Int ?? position // mlx_vlm sends full calls without index.
                    guard key >= 0, key < 128, let function = call["function"] as? [String: Any] else { throw ResponsesAdapter.malformed() }
                    let index: Int
                    if let existing = toolIndices[key] { index = existing }
                    else {
                        index = output.count; toolIndices[key] = index
                        output.append(["id": ResponsesAdapter.identifier("fc_"), "type": "function_call", "status": "in_progress", "call_id": "", "name": "", "arguments": ""])
                    }
                    if let id = call["id"] as? String, !id.isEmpty {
                        let previous = output[index]["call_id"] as? String ?? ""
                        guard previous.isEmpty || previous == id else { throw ResponsesAdapter.malformed() }
                        output[index]["call_id"] = id
                    }
                    if let name = function["name"] as? String, !name.isEmpty {
                        if announced.contains(index) {
                            guard name == output[index]["name"] as? String else { throw ResponsesAdapter.malformed() }
                        } else { output[index]["name"] = (output[index]["name"] as? String ?? "") + name }
                    }
                    if let arguments = function["arguments"] as? String, !arguments.isEmpty {
                        guard !(output[index]["name"] as? String ?? "").isEmpty, !(output[index]["call_id"] as? String ?? "").isEmpty else { throw ResponsesAdapter.malformed() }
                        events += announce(index)
                        output[index]["arguments"] = (output[index]["arguments"] as? String ?? "") + arguments
                        outputBytes += arguments.utf8.count
                        events.append(event("response.function_call_arguments.delta", ["output_index": index, "item_id": output[index]["id"]!, "delta": arguments], content: true))
                    }
                }
            }
            guard outputBytes <= 8 * 1024 * 1024 else { throw ResponsesAdapter.malformed() }
        }
        response["output"] = output
        return events
    }
    func complete() throws -> [Event] {
        guard ended, parser.isAtBoundary, let finish = finishReason else { throw ResponsesAdapter.malformed() }
        let completed = finish == "stop" || finish == "tool_calls"
        if finish == "tool_calls", toolIndices.isEmpty { throw ResponsesAdapter.malformed() }
        if completed { try ResponsesAdapter.validateOutput(output, request: request) }
        var events: [Event] = []
        for index in output.indices {
            events += announce(index)
            output[index]["status"] = completed ? "completed" : "incomplete"
            let fields: [String: Any] = ["output_index": index, "item_id": output[index]["id"]!]
            if output[index]["type"] as? String == "function_call" {
                events.append(event("response.function_call_arguments.done", fields.merging(["arguments": output[index]["arguments"]!, "name": output[index]["name"]!]) { _, new in new }))
            } else if let part = (output[index]["content"] as? [[String: Any]])?.first {
                let type = part["type"] as! String
                let contentFields = fields.merging(["content_index": 0]) { _, new in new }
                events.append(event("response.\(type).done", contentFields.merging(["text": part["text"]!, "logprobs": []]) { _, new in new }))
                if type == "output_text" { events.append(event("response.content_part.done", contentFields.merging(["part": part]) { _, new in new })) }
            }
            events.append(event("response.output_item.done", ["output_index": index, "item": output[index]]))
        }
        response["output"] = output; response["status"] = completed ? "completed" : "incomplete"
        if completed { response["completed_at"] = Int(Date().timeIntervalSince1970) }
        else { response["incomplete_details"] = ["reason": finish == "length" ? "max_output_tokens" : "content_filter"] }
        events.append(event(completed ? "response.completed" : "response.incomplete", ["response": response]))
        return events
    }
    func fail(_ failure: HTTPResponse, cancelled: Bool = false) -> Event {
        response["output"] = output
        response["status"] = cancelled ? "cancelled" : "failed"
        let error = (JSONSupport.object(from: failure.body)?["error"] as? [String: Any]) ?? [:]
        if cancelled {
            response["error"] = NSNull()
            // Responses has no response.cancelled SSE event. Use the standard error
            // event to end subscribers; GET /responses/{id} exposes cancelled status.
            return event("error", ["code": error["code"] ?? "response_cancelled", "message": error["message"] ?? "Response cancelled.", "param": NSNull()])
        }
        response["error"] = ["code": "server_error", "message": error["message"] ?? "The local request failed."]
        return event("response.failed", ["response": response])
    }
}
