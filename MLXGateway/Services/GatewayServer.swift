import Foundation
import Network

// All mutable listener/connection/registry state is confined to queue.
final class GatewayServer: @unchecked Sendable {
    private var registry: ModelRegistry
    private let backendManager: BackendManager
    private let queue = DispatchQueue(label: "dev.kamisato-yuna.MLXGateway.gateway")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
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
                if case .cancelled = state { self.connections.removeValue(forKey: ObjectIdentifier(connection)) }
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
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { connection.cancel(); return }
            guard let headerEnd = buffer.firstRange(of: Data([13, 10, 13, 10])) else {
                if complete { self.send(.error(statusCode: 400, message: "Malformed HTTP request.", code: "bad_request"), on: connection) }
                else { self.receiveRequest(on: connection, buffer: buffer) }
                return
            }
            guard let request = HTTPParser.parse(buffer), request.headers["transfer-encoding"] == nil,
                  let length = Int(request.headers["content-length"] ?? "0"), length >= 0 else {
                self.send(.error(statusCode: 400, message: "Use a valid Content-Length; chunked requests are not supported.", code: "bad_request"), on: connection)
                return
            }
            if buffer.count - headerEnd.upperBound < length {
                if complete { self.send(.error(statusCode: 400, message: "Incomplete body.", code: "bad_request"), on: connection) }
                else { self.receiveRequest(on: connection, buffer: buffer) }
                return
            }
            let boundedRequest = HTTPRequest(method: request.method, path: request.path, headers: request.headers,
                                             body: Data(request.body.prefix(length)))
            self.route(boundedRequest) { response in
                self.queue.async { self.send(response, on: connection) }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.wireData(), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func route(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResponse) -> Void) {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            completion(.json(object: ["ok": true, "service": "MLX Gateway", "protocol": "responses"]))
        case ("GET", "/status"):
            completion(.json(object: ["gateway": ["host": host, "port": port],
                                      "backend": backendManager.status.publicDescription,
                                      "models": registry.models.map { $0.publicDescription }]))
        case ("GET", "/v1/models"):
            completion(.json(object: ["object": "list", "data": registry.models.map { $0.publicDescription }]))
        case ("POST", "/v1/responses"):
            guard let body = JSONSupport.object(from: request.body) else {
                completion(.error(statusCode: 400, message: "Expected a JSON object.", code: "bad_json"))
                return
            }
            do {
                let chat = try ResponsesAdapter.chatRequest(body)
                guard let modelID = body["model"] as? String, registry.model(id: modelID) != nil else {
                    completion(.error(statusCode: 400, message: "Unknown model.", code: "model_not_found"))
                    return
                }
                backendManager.complete(modelID: modelID, chatData: JSONSupport.data(from: chat)) { result in
                    completion(result.statusCode == 200 ? ResponsesAdapter.response(from: result.body, request: JSONSupport.object(from: request.body) ?? [:]) : result)
                }
            } catch let error as ResponsesAdapter.InvalidRequest {
                completion(error.response)
            } catch {
                completion(.error(statusCode: 400, message: "Invalid Responses request.", code: "bad_request"))
            }
        default:
            completion(.error(statusCode: 404, message: "Route not found. Use POST /v1/responses for inference.", code: "not_found"))
        }
    }
}
