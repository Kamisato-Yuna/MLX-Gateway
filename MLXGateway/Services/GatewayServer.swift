import Foundation
import Network

final class GatewayServer {
    private let registry: ModelRegistry
    private let backendManager: BackendManager
    private let queue = DispatchQueue(label: "dev.kamisato-yuna.MLXGateway.gateway")
    private var listener: NWListener?
    private(set) var host: String
    private(set) var port: UInt16
    private(set) var modelHost: String
    private(set) var modelPort: UInt16

    init(
        registry: ModelRegistry,
        backendManager: BackendManager,
        host: String,
        port: UInt16,
        modelHost: String,
        modelPort: UInt16
    ) {
        self.registry = registry
        self.backendManager = backendManager
        self.host = host
        self.port = port
        self.modelHost = modelHost
        self.modelPort = modelPort
    }

    func start() throws {
        stop()

        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func restart(host: String, port: UInt16, modelHost: String, modelPort: UInt16) throws {
        self.host = host
        self.port = port
        self.modelHost = modelHost
        self.modelPort = modelPort
        try start()
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            guard let self else {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if !self.hasCompleteHTTPRequest(nextBuffer) {
                if isComplete {
                    let response = HTTPResponse.error(statusCode: 400, message: "Malformed HTTP request.", code: "bad_request")
                    connection.send(content: response.wireData(), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
                self.receiveRequest(on: connection, buffer: nextBuffer)
                return
            }

            let response: HTTPResponse
            if let request = HTTPParser.parse(nextBuffer) {
                response = self.route(request)
            } else {
                response = .error(statusCode: 400, message: "Malformed HTTP request.", code: "bad_request")
            }

            connection.send(content: response.wireData(), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func hasCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let headerEnd = data.firstRange(of: Data([13, 10, 13, 10])) else {
            return false
        }

        let headerData = data[..<headerEnd.lowerBound]
        guard let head = String(data: headerData, encoding: .utf8) else {
            return false
        }

        let contentLength = head
            .components(separatedBy: "\r\n")
            .dropFirst()
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      parts[0].lowercased() == "content-length" else {
                    return nil
                }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
            .first ?? 0

        let bodyStart = headerEnd.upperBound
        return data.count >= bodyStart + contentLength
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .json(object: [
                "ok": true,
                "service": "MLX Gateway",
                "gateway": "\(host):\(port)"
            ])
        case ("GET", "/status"):
            return .json(object: [
                "ok": true,
                "gateway": [
                    "host": host,
                    "port": port
                ],
                "downstream": [
                    "host": modelHost,
                    "port": modelPort
                ],
                "backend": backendManager.publicStatus,
                "models": registry.models.map { $0.publicDescription }
            ])
        case ("GET", "/v1/models"):
            return .json(object: [
                "object": "list",
                "data": registry.models.map { $0.publicDescription }
            ])
        case ("POST", "/v1/chat/completions"):
            return handleChatCompletions(request)
        case ("POST", "/v1/responses"):
            return handleResponses(request)
        case ("POST", "/v1/messages"):
            return handleAnthropicMessages(request)
        default:
            return .error(statusCode: 404, message: "Route is not implemented.", code: "not_found")
        }
    }

    private func handleChatCompletions(_ request: HTTPRequest) -> HTTPResponse {
        guard var body = JSONSupport.object(from: request.body) else {
            return .error(statusCode: 400, message: "Expected JSON request body.", code: "bad_json")
        }

        if let unsupported = unsupportedFeature(in: body) {
            return unsupported
        }

        guard let model = registry.model(id: body["model"] as? String) else {
            return .error(statusCode: 400, message: "Unknown model.", code: "model_not_found")
        }

        guard model.capabilities.contains("chat") else {
            return .unsupported("Model does not support chat completions.", param: "model")
        }

        body["model"] = model.id
        return startAndProxy(model: model, path: "/v1/chat/completions", body: body)
    }

    private func handleResponses(_ request: HTTPRequest) -> HTTPResponse {
        guard var body = JSONSupport.object(from: request.body) else {
            return .error(statusCode: 400, message: "Expected JSON request body.", code: "bad_json")
        }

        if let unsupported = unsupportedFeature(in: body) {
            return unsupported
        }

        guard let model = registry.model(id: body["model"] as? String) else {
            return .error(statusCode: 400, message: "Unknown model.", code: "model_not_found")
        }

        guard model.capabilities.contains("responses") else {
            return .unsupported("Responses API is only enabled for models with the responses capability.", param: "model")
        }

        body["model"] = model.id
        return startAndProxy(model: model, path: "/v1/responses", body: body)
    }

    private func handleAnthropicMessages(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = JSONSupport.object(from: request.body) else {
            return .error(statusCode: 400, message: "Expected JSON request body.", code: "bad_json")
        }

        if body["tools"] != nil {
            return .unsupported("Anthropic tool use is not supported in this gateway version.", param: "tools")
        }
        if body["tool_choice"] != nil {
            return .unsupported("Anthropic tool choice is not supported in this gateway version.", param: "tool_choice")
        }
        if JSONSupport.boolValue(body["stream"]) {
            return .unsupported("Streaming is not supported in this gateway version.", param: "stream")
        }

        guard let model = registry.model(id: body["model"] as? String) else {
            return .error(statusCode: 400, message: "Unknown model.", code: "model_not_found")
        }

        guard let messages = body["messages"] as? [[String: Any]] else {
            return .error(statusCode: 400, message: "Anthropic messages must be an array.", code: "bad_json")
        }

        let openAIMessages = messages.map { message -> [String: Any] in
            [
                "role": message["role"] as? String ?? "user",
                "content": plainTextContent(message["content"])
            ]
        }

        let chatBody: [String: Any] = [
            "model": model.id,
            "messages": openAIMessages,
            "max_tokens": body["max_tokens"] ?? 512
        ]

        return startAndProxy(model: model, path: "/v1/chat/completions", body: chatBody)
    }

    private func unsupportedFeature(in body: [String: Any]) -> HTTPResponse? {
        if JSONSupport.boolValue(body["stream"]) {
            return .unsupported("Streaming is not supported in this gateway version.", param: "stream")
        }
        if body["tools"] != nil {
            return .unsupported("Tool calling is not supported in this gateway version.", param: "tools")
        }
        if body["tool_choice"] != nil {
            return .unsupported("Tool choice is not supported in this gateway version.", param: "tool_choice")
        }
        if containsVisionPayload(body["messages"]) || containsVisionPayload(body["input"]) {
            return .unsupported("Vision input is not supported in this gateway version.", param: "messages")
        }
        return nil
    }

    private func containsVisionPayload(_ value: Any?) -> Bool {
        if let array = value as? [Any] {
            return array.contains { containsVisionPayload($0) }
        }
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["type"] as? String,
               type.contains("image") || type == "input_image" {
                return true
            }
            if dictionary["image_url"] != nil || dictionary["source"] != nil {
                return true
            }
            return dictionary.values.contains { containsVisionPayload($0) }
        }
        return false
    }

    private func plainTextContent(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                guard (part["type"] as? String) == "text" else {
                    return nil
                }
                return part["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }

    private func startAndProxy(model: ModelSpec, path: String, body: [String: Any]) -> HTTPResponse {
        do {
            try backendManager.ensureActive(model: model, host: modelHost, port: modelPort)
            return proxy(path: path, body: body)
        } catch {
            return .error(statusCode: 503, message: error.localizedDescription, code: "backend_unavailable")
        }
    }

    private func proxy(path: String, body: [String: Any]) -> HTTPResponse {
        guard let url = URL(string: "http://\(modelHost):\(modelPort)\(path)") else {
            return .error(statusCode: 502, message: "Invalid downstream URL.", code: "bad_downstream_url")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = JSONSupport.data(from: body)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error>?

        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let response = response as? HTTPURLResponse else {
                result = .failure(URLError(.badServerResponse))
                return
            }
            result = .success((data ?? Data(), response))
        }.resume()

        _ = semaphore.wait(timeout: .now() + 120)

        switch result {
        case .success(let (data, response)):
            return HTTPResponse(
                statusCode: response.statusCode,
                reason: HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized,
                headers: ["Content-Type": response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"],
                body: data
            )
        case .failure(let error):
            return .error(statusCode: 502, message: error.localizedDescription, code: "downstream_error")
        case .none:
            return .error(statusCode: 502, message: "Downstream request timed out.", code: "downstream_timeout")
        }
    }
}
