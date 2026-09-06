import Foundation
import Network

// All mutable listener/connection/registry state is confined to queue.
final class GatewayServer: @unchecked Sendable {
    private var registry: ModelRegistry
    private let backendManager: BackendManager
    private let queue = DispatchQueue(label: "dev.kamisato-yuna.MLXGateway.gateway")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let responses = ResponsesStore()
    private var connectionJobs: [ObjectIdentifier: ResponseRecord] = [:]
    private var host: String
    private var port: UInt16
    private var stateHandler: (@Sendable (Bool, String?) -> Void)?
    var onStateChange: (@Sendable (Bool, String?) -> Void)? {
        get { queue.sync { stateHandler } }
        set { queue.sync { stateHandler = newValue } }
    }

    func updateRegistry(_ registry: ModelRegistry) { queue.sync { self.registry = registry } }

    init(registry: ModelRegistry, backendManager: BackendManager, host: String, port: UInt16) {
        self.registry = registry
        self.backendManager = backendManager
        self.host = host
        self.port = port
    }

    func start() throws {
        try queue.sync { try startLocked() }
    }

    func restart(host: String, port: UInt16) throws {
        try queue.sync {
            stopLocked()
            self.host = host
            self.port = port
            try startLocked()
        }
    }

    private func startLocked() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let next = try NWListener(using: parameters)
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next, self.listener === next else { return }
            switch state {
            case .ready: self.stateHandler?(true, nil)
            case .failed(let error): self.stateHandler?(false, error.localizedDescription)
            case .waiting(let error): self.stateHandler?(false, error.localizedDescription)
            default: break
            }
        }
        next.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections[ObjectIdentifier(connection)] = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                if case .cancelled = state { self.disconnected(connection) }
                if case .failed = state { connection.cancel() }
            }
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection, buffer: Data())
        }
        listener = next
        next.start(queue: queue)
    }

    func stop() { queue.sync { stopLocked() } }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        for record in Array(responses.records.values) where !record.finished {
            fail(record, .error(statusCode: 503, message: "The gateway stopped during this request.", code: "gateway_stopped"))
        }
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        connectionJobs.removeAll()
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { connection.cancel(); return }
            guard buffer.count <= 16 * 1024 * 1024 + 65_536 else {
                self.send(.error(statusCode: 413, message: "Request body exceeds 16 MiB.", code: "request_too_large"), on: connection); return
            }
            guard let headerEnd = buffer.firstRange(of: Data([13, 10, 13, 10])) else {
                if buffer.count > 65_536 { self.send(.error(statusCode: 400, message: "HTTP headers are too large.", code: "bad_request"), on: connection) }
                else if complete { self.send(.error(statusCode: 400, message: "Malformed HTTP request.", code: "bad_request"), on: connection) }
                else { self.receiveRequest(on: connection, buffer: buffer) }
                return
            }
            guard let request = HTTPParser.parse(buffer), request.headers["transfer-encoding"] == nil,
                  let length = Int(request.headers["content-length"] ?? "0"), length >= 0 else {
                self.send(.error(statusCode: 400, message: "Use a valid Content-Length; chunked requests are not supported.", code: "bad_request"), on: connection)
                return
            }
            guard length <= 16 * 1024 * 1024 else {
                self.send(.error(statusCode: 413, message: "Request body exceeds 16 MiB.", code: "request_too_large"), on: connection); return
            }
            if buffer.count - headerEnd.upperBound < length {
                if complete { self.send(.error(statusCode: 400, message: "Incomplete body.", code: "bad_request"), on: connection) }
                else { self.receiveRequest(on: connection, buffer: buffer) }
                return
            }
            let boundedRequest = HTTPRequest(method: request.method, path: request.path, headers: request.headers,
                                             body: Data(request.body.prefix(length)))
            self.route(boundedRequest, on: connection)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.wireData(), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        do {
            guard let url = URLComponents(string: "http://gateway" + request.path) else { throw ResponsesAdapter.invalid("Invalid request URL.", "path") }
            var query: [String: String] = [:]
            for item in url.queryItems ?? [] {
                guard query[item.name] == nil, let value = item.value else { throw ResponsesAdapter.invalid("Invalid or duplicate query parameter.", item.name) }
                query[item.name] = value
            }
            let path = url.path
            if path.hasPrefix("/v1/responses/") {
                try responseRoute(request, path: path, query: query, on: connection); return
            }
            guard query.isEmpty else { throw ResponsesAdapter.unsupported("Query parameters are not supported on this route.", "query") }
            switch (request.method, path) {
            case ("GET", "/health"):
                send(.json(object: ["ok": true, "service": "MLX Gateway", "protocol": "responses"]), on: connection)
            case ("GET", "/status"):
                send(.json(object: ["gateway": ["host": host, "port": port], "backend": backendManager.status.publicDescription,
                                    "models": registry.models.map { $0.publicDescription }, "responses": Self.protocolDescription]), on: connection)
            case ("GET", "/v1/models"):
                send(.json(object: ["object": "list", "data": registry.models.map { $0.publicDescription }]), on: connection)
            case ("POST", "/v1/responses"):
                guard let body = JSONSupport.object(from: request.body) else { throw ResponsesAdapter.invalid("Expected a JSON object.", "body") }
                guard let modelID = body["model"] as? String, let model = registry.model(id: modelID) else {
                    send(.error(statusCode: 400, message: "Unknown model.", code: "model_not_found"), on: connection); return
                }
                var history: [[String: Any]] = []
                if let previous = body["previous_response_id"] as? String {
                    guard let record = responses.lookup(previous) else { send(notFound(), on: connection); return }
                    guard record.finished, ["completed", "incomplete"].contains(record.response["status"] as? String ?? "") else {
                        send(.error(statusCode: 409, message: "Previous response is not ready for continuation.", code: "response_not_complete"), on: connection); return
                    }
                    history = record.inputItems + (record.response["output"] as? [[String: Any]] ?? [])
                }
                let prepared = try ResponsesAdapter.prepare(body, model: model, history: history)
                guard JSONSupport.data(from: ["input": prepared.inputItems]).count <= 16 * 1024 * 1024 else {
                    send(.error(statusCode: 413, message: "Accumulated response context exceeds 16 MiB.", code: "context_too_large"), on: connection); return
                }
                let metric = RequestMetricsStore.shared.begin(modelID: modelID)
                let status = backendManager.status
                if status.state != .ready || status.modelID != modelID {
                    let code = status.state == .ready ? "model_not_active" : "backend_not_ready"
                    let http = status.state == .ready ? 409 : 503
                    RequestMetricsStore.shared.finish(metric, statusCode: http, error: code)
                    send(.error(statusCode: http, message: "Select and start this model in MLX Gateway and wait until it is ready.", code: code), on: connection); return
                }
                let record = ResponseRecord(prepared: prepared, metricID: metric)
                do { try responses.insert(record) }
                catch {
                    RequestMetricsStore.shared.finish(metric, statusCode: 429, error: "capacity_exceeded")
                    throw error
                }
                if record.streaming { subscribe(record, on: connection, startingAfter: nil) }
                else if record.background { send(.json(object: record.response), on: connection) }
                else { record.connection = connection; watch(record, on: connection) }
                // Queue the start after the initial background response is enqueued for sending.
                queue.async { [weak self] in self?.run(record) }
            default:
                send(.error(statusCode: 404, message: "Route not found. Use POST /v1/responses for inference.", code: "not_found"), on: connection)
            }
        } catch let error as ResponsesAdapter.InvalidRequest { send(error.response, on: connection) }
        catch { send(.error(statusCode: 400, message: "Invalid Responses request.", code: "bad_request"), on: connection) }
    }

    static var protocolDescription: [String: Any] { [
        "streaming": "incremental_sse", "function_tools": "model_tokenizer_dependent; strict=false; tool policy checked on completion",
        "structured_output": "mlx_vlm with llguidance only", "file_input": "inline base64 UTF-8 text; mlx_vlm PDF text plus all page images (8 MiB, 20 pages)", "image_input": "mlx_vlm user messages; HTTP(S) or base64; detail=auto",
        "storage": "process_memory", "stored_response_ttl_seconds": 86_400, "background_ephemeral_ttl_seconds": 600,
        "max_retained_responses": ResponsesStore.capacity, "eviction": "oldest finished response when capacity is reached",
        "max_request_bytes": 16 * 1024 * 1024, "max_output_bytes": 8 * 1024 * 1024,
        "usage_details": "Missing MLX cached/cache-write/reasoning counts use compatibility zero; these defaults are not measured counts.",
        "background": true, "cancel": "background responses; foreground disconnect cancels transport",
        "stream_resume": "background responses created with stream=true; sequence_number cursor",
        "unsupported": ["hosted_tools", "audio", "video", "hosted_file_ids", "file_urls", "binary_office_files", "strict_function_schemas", "conversations_resource", "auto_truncation", "websocket", "stream_obfuscation"],
        "cancellation_limit": "Cancels the HTTP generation request; immediate GPU interruption depends on the MLX backend."
    ] }

    private func notFound() -> HTTPResponse { .error(statusCode: 404, message: "Response not found, not stored, expired or deleted.", code: "response_not_found") }
    private func responseRoute(_ request: HTTPRequest, path: String, query: [String: String], on connection: NWConnection) throws {
        let components = path.split(separator: "/").map(String.init)
        guard components.count == 3 || components.count == 4 else { send(notFound(), on: connection); return }
        let id = components[2]
        guard let record = responses.lookup(id) else { send(notFound(), on: connection); return }
        switch (request.method, components.count == 4 ? components[3] : "") {
        case ("GET", ""):
            guard Set(query.keys).isSubset(of: ["stream", "starting_after", "include_obfuscation"]) else { throw ResponsesAdapter.unsupported("Unsupported response retrieval parameter.", "query") }
            guard query["stream"] == nil || ["true", "false"].contains(query["stream"]!) else { throw ResponsesAdapter.invalid("Expected true or false.", "stream") }
            if query["stream"] == "true" {
                guard record.background, record.streaming else { throw ResponsesAdapter.unsupported("Stream resumption requires a background response created with stream=true.", "stream") }
                if let obfuscation = query["include_obfuscation"], obfuscation != "false" { throw ResponsesAdapter.unsupported("Stream obfuscation is not implemented.", "include_obfuscation") }
                var after: Int?
                if let cursor = query["starting_after"] {
                    guard let number = Int(cursor), number >= 0, number < record.events.count else { throw ResponsesAdapter.invalid("Unknown stream sequence cursor.", "starting_after") }
                    after = number
                }
                subscribe(record, on: connection, startingAfter: after)
            } else {
                guard query["starting_after"] == nil && query["include_obfuscation"] == nil else { throw ResponsesAdapter.invalid("Streaming options require stream=true.", "stream") }
                send(.json(object: record.response), on: connection)
            }
        case ("DELETE", ""):
            guard query.isEmpty else { throw ResponsesAdapter.unsupported("Unsupported query parameter.", "query") }
            if !record.finished { fail(record, .error(statusCode: 499, message: "Response deleted.", code: "response_deleted"), cancelled: true) }
            responses.remove(id)
            send(.json(object: ["id": id, "object": "response.deleted", "deleted": true]), on: connection)
        case ("POST", "cancel"):
            guard query.isEmpty, request.body.isEmpty || JSONSupport.object(from: request.body)?.isEmpty == true else { throw ResponsesAdapter.invalid("Cancel takes no parameters.", "body") }
            guard record.background else { throw ResponsesAdapter.invalid("Only background responses can be cancelled by ID. Disconnect to cancel a foreground request.", "response_id") }
            if !record.finished { fail(record, .error(statusCode: 499, message: "Response cancelled.", code: "response_cancelled"), cancelled: true) }
            send(.json(object: record.response), on: connection)
        case ("GET", "input_items"):
            guard Set(query.keys).isSubset(of: ["limit", "order", "after", "before"]) else { throw ResponsesAdapter.unsupported("Unsupported input item query parameter.", "query") }
            let limit = Int(query["limit"] ?? "20") ?? 0
            let order = query["order"] ?? "desc"
            guard (1...100).contains(limit), ["asc", "desc"].contains(order), query["after"] == nil || query["before"] == nil else { throw ResponsesAdapter.invalid("Invalid pagination parameters.", "query") }
            var items = order == "asc" ? record.inputItems : Array(record.inputItems.reversed())
            if let cursor = query["after"] ?? query["before"] {
                guard let index = items.firstIndex(where: { $0["id"] as? String == cursor }) else { throw ResponsesAdapter.invalid("Input item cursor was not found.", "query") }
                items = query["after"] != nil ? Array(items.dropFirst(index + 1)) : Array(items.prefix(index))
            }
            let page = Array(items.prefix(limit))
            send(.json(object: ["object": "list", "data": page, "has_more": items.count > limit,
                                "first_id": page.first?["id"] ?? NSNull(), "last_id": page.last?["id"] ?? NSNull()]), on: connection)
        default: send(.error(statusCode: 404, message: "Route not found.", code: "not_found"), on: connection)
        }
    }

    private func watch(_ record: ResponseRecord, on connection: NWConnection) {
        connectionJobs[ObjectIdentifier(connection)] = record
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak connection] _, _, complete, error in
            guard let self, let connection else { return }
            if complete || error != nil { self.disconnected(connection); connection.cancel() }
            else { self.watch(record, on: connection) }
        }
    }
    private func disconnected(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections.removeValue(forKey: key)
        guard let record = connectionJobs.removeValue(forKey: key) else { return }
        record.subscribers.removeValue(forKey: key)
        if record.connection === connection { record.connection = nil }
        if !record.finished, !record.background {
            fail(record, .error(statusCode: 499, message: "The client disconnected.", code: "client_disconnected"), cancelled: true)
        }
    }
    private func subscribe(_ record: ResponseRecord, on connection: NWConnection, startingAfter: Int?) {
        let writer = SSEConnection(connection: connection, queue: queue) { [weak self, weak connection] in
            guard let self, let connection else { return }; self.disconnected(connection)
        }
        record.subscribers[ObjectIdentifier(connection)] = writer
        watch(record, on: connection)
        for event in record.events.dropFirst((startingAfter ?? -1) + 1) { writer.append(event) }
        if record.finished { writer.finish() }
    }
    private func emit(_ events: [ResponsesStream.Event], for record: ResponseRecord) {
        for event in events {
            if record.finished { break }
            if event.content { RequestMetricsStore.shared.firstToken(record.metricID) }
            if record.background {
                record.events.append(event.data); record.eventBytes += event.data.count
            }
            for subscriber in Array(record.subscribers.values) { subscriber.append(event.data) }
        }
    }
    private func run(_ record: ResponseRecord) {
        guard !record.finished else { return }
        record.response["status"] = "in_progress"
        let model = record.request["model"] as! String
        if let mapper = record.mapper {
            emit(mapper.start(), for: record)
            record.response = mapper.response
            guard !record.finished else { return }
            record.cancellation = backendManager.stream(modelID: model, chatData: record.chatData, bytes: { [weak self] bytes in
                guard let self else { return }
                self.queue.async {
                    guard !record.finished else { return }
                    do {
                        let events = try mapper.append(bytes)
                        record.response = mapper.response
                        self.emit(events, for: record)
                        if record.eventBytes > 32 * 1024 * 1024 {
                            self.fail(record, .error(statusCode: 502, message: "Background stream exceeds the local replay buffer limit.", code: "response_too_large"))
                        }
                    } catch let error as ResponsesAdapter.InvalidRequest { self.fail(record, error.response) }
                    catch { self.fail(record, ResponsesAdapter.malformed().response) }
                }
            }, completion: { [weak self] failure in
                guard let self else { return }
                self.queue.async {
                    guard !record.finished else { return }
                    if let failure { self.fail(record, failure); return }
                    do {
                        let events = try mapper.complete()
                        record.response = mapper.response
                        self.emit(events, for: record)
                        self.finish(record, status: 200)
                    } catch let error as ResponsesAdapter.InvalidRequest { self.fail(record, error.response) }
                    catch { self.fail(record, ResponsesAdapter.malformed().response) }
                }
            })
        } else {
            record.cancellation = backendManager.complete(modelID: model, chatData: record.chatData) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard !record.finished else { return }
                    guard result.statusCode == 200 else { self.fail(record, result); return }
                    guard result.body.count <= 8 * 1024 * 1024 else {
                        self.fail(record, .error(statusCode: 502, message: "MLX response exceeds the local output limit.", code: "response_too_large")); return
                    }
                    let converted = ResponsesAdapter.response(from: result.body, request: record.request)
                    guard converted.statusCode == 200, var response = JSONSupport.object(from: converted.body) else { self.fail(record, converted); return }
                    response["id"] = record.id; response["created_at"] = record.response["created_at"]
                    record.response = response
                    // A buffered completion cannot provide truthful time-to-first-token.
                    if let connection = record.connection { self.send(.json(object: response), on: connection) }
                    self.finish(record, status: 200)
                }
            }
        }
    }
    private func fail(_ record: ResponseRecord, _ failure: HTTPResponse, cancelled: Bool = false) {
        guard !record.finished else { return }
        record.cancellation?.cancel()
        if let mapper = record.mapper {
            let event = mapper.fail(failure, cancelled: cancelled)
            record.response = mapper.response
            emit([event], for: record)
        } else {
            record.response["status"] = cancelled ? "cancelled" : "failed"
            let details = JSONSupport.object(from: failure.body)?["error"] as? [String: Any] ?? [:]
            record.response["error"] = cancelled ? NSNull() : ["code": "server_error", "message": details["message"] ?? "The local request failed."]
            if let connection = record.connection { send(failure, on: connection) }
        }
        let code = (JSONSupport.object(from: failure.body)?["error"] as? [String: Any])?["code"] as? String ?? "request_failed"
        finish(record, status: failure.statusCode, error: code)
    }
    private func finish(_ record: ResponseRecord, status: Int, error: String? = nil) {
        guard !record.finished else { return }
        record.finished = true; record.finishedAt = Date(); record.cancellation = nil
        let usage = record.response["usage"] as? [String: Any]
        let incomplete = record.response["status"] as? String == "incomplete"
        RequestMetricsStore.shared.finish(record.metricID, statusCode: status, inputTokens: usage?["input_tokens"] as? Int,
                                          outputTokens: usage?["output_tokens"] as? Int, error: error ?? (incomplete ? "response_incomplete" : nil))
        for subscriber in Array(record.subscribers.values) { subscriber.finish() }
        record.connection = nil
        responses.prune()
    }
}
