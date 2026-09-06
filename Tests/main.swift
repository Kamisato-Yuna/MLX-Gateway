import Foundation
import Darwin

URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
// Callbacks share only this locked state; JSON stays serialized across threads.
final class TestState: @unchecked Sendable {
    let lock = NSLock()
    var checks = 0
    var cleanup: @Sendable () -> Void = {}
    var diagnostics: @Sendable () -> String = { "" }
    func record() { lock.withLock { checks += 1 } }
}
final class ResponseBox: @unchecked Sendable {
    let lock = NSLock()
    var status = 0
    var data = Data()
}
let testState = TestState()
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n\(testState.diagnostics())\n", stderr); testState.cleanup(); exit(1) }
    testState.record()
}
func awaitCondition(_ message: String, _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while !predicate(), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    check(predicate(), message)
}
func request(_ port: UInt16, _ path: String, _ body: [String: Any]? = nil) -> (Int, [String: Any]) {
    var req = URLRequest(url: LocalEndpoint.url(host: "127.0.0.1", port: port)!.appendingPathComponent(path))
    req.timeoutInterval = 8
    if let body {
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = JSONSupport.data(from: body)
    }
    let box = ResponseBox()
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, response, _ in
        box.lock.withLock { box.status = (response as? HTTPURLResponse)?.statusCode ?? 0; box.data = data ?? Data() }
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 10)
    return box.lock.withLock { (box.status, JSONSupport.object(from: box.data) ?? [:]) }
}
func rejected(_ body: [String: Any]) -> Bool {
    do { _ = try ResponsesAdapter.chatRequest(body); return false }
    catch let error as ResponsesAdapter.InvalidRequest { return error.response.statusCode == 400 }
    catch { return false }
}

let modelID = "fixture-text"
let simple: [String: Any] = ["model": modelID, "input": "你好", "store": false, "max_output_tokens": 30]
let chat = try ResponsesAdapter.chatRequest(simple)
check(chat["max_tokens"] as? Int == 30, "max_output_tokens mapping")
check((chat["messages"] as? [[String: Any]])?.first?["content"] as? String == "你好", "string input mapping")
let messages = try ResponsesAdapter.chatRequest([
    "model": modelID, "instructions": "遵守证据", "input": [
        ["role": "developer", "content": "中文"],
        ["role": "assistant", "type": "message", "id": "msg_history", "status": "completed",
         "content": [["type": "output_text", "text": "收到", "annotations": []]]],
        ["role": "user", "content": [["type": "input_text", "text": "继续"]]]
    ]
])
let mapped = messages["messages"] as! [[String: Any]]
check(mapped.count == 4 && mapped[0]["content"] as? String == "遵守证据", "instructions prepended")
check(mapped[1]["role"] as? String == "system" && mapped[2]["content"] as? String == "收到", "developer and assistant history")
for (key, value) in [("stream", true as Any), ("store", true), ("tools", []), ("tool_choice", "auto"),
                     ("previous_response_id", "resp_x"), ("conversation", "conv_x"), ("background", true),
                     ("max_output_tokens", -1), ("max_output_tokens", 1.5), ("temperature", true),
                     ("stream", "true"), ("top_p", 2)] {
    var body = simple; body[key] = value
    check(rejected(body), "reject unsupported/invalid \(key)=\(value)")
}
for item in [["role": "user", "content": [["type": "input_image", "image_url": "data:image/png;base64,eA=="]]],
             ["type": "function_call_output", "call_id": "call_1", "output": "ok"],
             ["role": "user", "content": [["type": "input_text", "text": "ok"], ["type": "input_audio"]]]] as [[String: Any]] {
    check(rejected(["model": modelID, "input": [item]]), "reject unsupported input without dropping content")
}
for finish in ["stop", "length", "content_filter"] {
    let response = ResponsesAdapter.response(from: JSONSupport.data(from: [
        "model": "/private/model/path", "choices": [["message": ["content": "完成"], "finish_reason": finish]],
        "usage": ["prompt_tokens": 4, "completion_tokens": 2]
    ]), request: simple)
    let object = JSONSupport.object(from: response.body)!
    check(object["object"] as? String == "response" && object["model"] as? String == modelID, "Responses output and public model ID")
    check(object["status"] as? String == (finish == "stop" ? "completed" : "incomplete"), "finish reason \(finish)")
    check((object["usage"] as? [String: Any])?["total_tokens"] as? Int == 6, "usage mapping")
    check(!String(decoding: response.body, as: UTF8.self).contains("/private/model"), "no backend path leak")
}
check(ResponsesAdapter.response(from: Data("{}".utf8), request: simple).statusCode == 502, "malformed backend response")
let vlmResponse = ResponsesAdapter.response(from: JSONSupport.data(from: [
    "choices": [["finish_reason": "stop", "message": ["content": "你好", "tool_calls": NSNull()]]]
]), request: simple)
check(vlmResponse.statusCode == 200, "MLX VLM nullable tool_calls")
let thinkingResponse = ResponsesAdapter.response(from: JSONSupport.data(from: [
    "choices": [["finish_reason": "length", "message": ["reasoning": "partial reasoning"]]]
]), request: simple)
let thinkingObject = JSONSupport.object(from: thinkingResponse.body)!
check(thinkingResponse.statusCode == 200 && thinkingObject["status"] as? String == "incomplete", "budget exhausted before final text")
check((thinkingObject["output"] as? [Any])?.isEmpty == true, "no invented text when only reasoning was generated")
check(LocalEndpoint.url(host: "::1", port: 44100)?.absoluteString == "http://[::1]:44100", "IPv6 endpoint URL")

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-gateway-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
// Directory discovery is independent of the developer's installed models.
let collection = temporary.appendingPathComponent("scan")
func writeModel(_ path: String, _ json: String) throws {
    let directory = collection.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: directory.appendingPathComponent("config.json"))
}
try writeModel("team-a/text", #"{"model_type":"qwen3"}"#)
try writeModel("team-b/text", #"{"model_type":"llama","vision_config":null}"#)
try writeModel("vision", #"{"model_type":"qwen3_vl","vision_config":{}}"#)
try writeModel("invalid", "not json")
try writeModel("missing-type", "{}")
try FileManager.default.createSymbolicLink(at: collection.appendingPathComponent("loop"), withDestinationURL: collection)
let scanned = ModelRegistry(modelsRoot: collection.path)
check(scanned.models.count == 3, "discover models and skip invalid configs / directory symlinks")
check(Set(scanned.models.map(\.id)) == Set(["team-a/text", "team-b/text", "vision"]), "nested model IDs remain unique")
check(scanned.model(id: "vision")?.backend == .mlxVLM, "detect visual backend from config")
check(scanned.model(id: "team-a/text")?.backend == .mlxLM && scanned.model(id: "team-b/text")?.backend == .mlxLM, "detect text backend, including null vision config")
check(scanned.scanMessage?.contains("2") == true, "invalid configurations have an actionable summary")
check(ModelRegistry(modelsRoot: collection.appendingPathComponent("vision").path).defaultModel?.id == "vision", "single-model directory")
check(ModelRegistry(modelsRoot: temporary.appendingPathComponent("absent").path).scanMessage != nil, "missing directory is reported")
let empty = temporary.appendingPathComponent("empty")
try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
check(ModelRegistry(modelsRoot: empty.path).defaultModel == nil, "empty registry never indexes a missing model")
check(!String(describing: scanned.models.map(\.publicDescription)).contains(collection.path), "scan paths stay out of the public model list")
let customPaths = RuntimePaths(directory: " ~/custom-mlx ")
check(customPaths.python.hasSuffix("/custom-mlx/.venv/bin/python") && customPaths.models.hasSuffix("/custom-mlx/models"), "runtime selection derives model and interpreter paths")
check(RuntimePaths(directory: "~/custom-mlx", models: "/tmp/models", python: "/tmp/python").python == "/tmp/python", "independent interpreter override")

let modelRoot = temporary.appendingPathComponent("model")
try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
try Data("{}".utf8).write(to: modelRoot.appendingPathComponent("config.json"))
let fixtureModel = ModelSpec(id: modelID, backend: .mlxLM, capabilities: ["responses", "text"], localPath: modelRoot.path)
let secondID = "fixture-vision"
let second = ModelSpec(id: secondID, backend: .mlxVLM, capabilities: ["responses", "text"], localPath: modelRoot.path)
let backend = BackendManager(pythonExecutable: root.appendingPathComponent("Tests/backend_fixture.py").path,
                             logURL: temporary.appendingPathComponent("backend.log"))
testState.diagnostics = { "Backend: \(backend.status)\n\(backend.readLogTail())" }
let gatewayPort: UInt16 = 44219
let modelPort: UInt16 = 44220
try LocalEndpoint.checkAvailable(host: "127.0.0.1", port: gatewayPort)
try LocalEndpoint.checkAvailable(host: "127.0.0.1", port: modelPort)
let server = GatewayServer(registry: ModelRegistry(models: [fixtureModel, second]), backendManager: backend, host: "127.0.0.1", port: gatewayPort)
try server.start()
testState.cleanup = { server.stop(); backend.shutdown(); try? FileManager.default.removeItem(at: temporary) }
defer { testState.cleanup() }
awaitCondition("gateway listens") { request(gatewayPort, "health").0 == 200 }
check(request(gatewayPort, "v1/messages", simple).0 == 404, "Anthropic route removed")
check(request(gatewayPort, "v1/chat/completions", simple).0 == 404, "public Chat route removed")
check(request(gatewayPort, "v1/responses", simple).0 == 503, "no automatic backend startup")
check(backend.status.pid == nil, "request cannot start a process")
backend.start(model: fixtureModel, host: "127.0.0.1", port: modelPort)
awaitCondition("fixture ready") { backend.status.state == .ready }
let firstPID = backend.status.pid!
let response = request(gatewayPort, "v1/responses", simple)
check(response.0 == 200 && response.1["object"] as? String == "response", "Responses HTTP success")
let output = response.1["output"] as! [[String: Any]]
check((output[0]["content"] as! [[String: Any]])[0]["text"] as? String == "fixture: 你好", "actual adapter round trip")
var wrongModel = simple; wrongModel["model"] = secondID
check(request(gatewayPort, "v1/responses", wrongModel).0 == 409, "wrong model rejected")
check(backend.status.pid == firstPID, "wrong model does not switch backend")
let errorResult = request(gatewayPort, "v1/responses", ["model": modelID, "input": "backend-error"])
check(errorResult.0 == 502 && !String(describing: errorResult.1).contains(temporary.path), "backend error path remains private")
awaitCondition("stdout captured") { backend.readLogTail().contains("fixture request completed") }
let slowDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    let result = request(gatewayPort, "v1/responses", ["model": modelID, "input": "slow"])
    check(result.0 == 503, "switch cancels an in-flight request")
    slowDone.signal()
}
Thread.sleep(forTimeInterval: 0.2)
let started = Date()
check(request(gatewayPort, "health").0 == 200 && Date().timeIntervalSince(started) < 1, "health stays responsive during inference")
backend.start(model: second, host: "127.0.0.1", port: modelPort)
awaitCondition("selected replacement ready") { backend.status.state == .ready && backend.status.modelID == secondID }
check(kill(firstPID, 0) != 0, "old process terminated before replacement")
check(slowDone.wait(timeout: .now() + 5) == .success, "cancelled request finishes")
check(request(gatewayPort, "v1/responses", wrongModel).0 == 200, "second selected model responds")
let secondPID = backend.status.pid!
backend.stop()
awaitCondition("service stopped") { backend.status.state == .stopped }
check(kill(secondPID, 0) != 0 && request(gatewayPort, "v1/responses", wrongModel).0 == 503, "stop releases process and disables inference")
backend.start(model: fixtureModel, host: "127.0.0.1", port: gatewayPort)
awaitCondition("occupied port fails safely") { backend.status.state == .failed }
check(backend.status.pid == nil && request(gatewayPort, "health").0 == 200, "foreign listener untouched")
backend.start(model: fixtureModel, host: "127.0.0.1", port: modelPort)
awaitCondition("restart succeeds") { backend.status.state == .ready }
_ = request(modelPort, "exit")
awaitCondition("abnormal exit detected") { backend.status.state == .failed && backend.status.pid == nil }
check(backend.readLogTail().contains("退出码 7"), "abnormal exit logged")
print("PASS: \(testState.checks) checks — Responses conversion, routes, lifecycle, switching, cancellation, logs and errors")
