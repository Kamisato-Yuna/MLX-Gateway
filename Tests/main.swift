import Foundation
import Darwin
import CoreGraphics

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
final class StreamingProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let lock = NSLock()
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    var status = 0
    var contentType = ""
    var firstDelta: Date?
    var endedAt: Date?
    var session: URLSession?
    var task: URLSessionDataTask?
    func start(_ port: UInt16, _ path: String, _ body: [String: Any]? = nil) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/" + path)!)
        req.timeoutInterval = 8
        if let body { req.httpMethod = "POST"; req.httpBody = JSONSupport.data(from: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: req); self.task = task; task.resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { status = (response as? HTTPURLResponse)?.statusCode ?? 0; contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "" }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        lock.withLock {
            data.append(bytes)
            if firstDelta == nil, String(decoding: data, as: UTF8.self).contains(".delta\"") { firstDelta = Date() }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { endedAt = Date() }
        session.finishTasksAndInvalidate(); done.signal()
    }
    func wait() -> [[String: Any]] {
        check(done.wait(timeout: .now() + 10) == .success, "SSE transport terminates")
        return lock.withLock { var parser = SSEParser(); return ((try? parser.append(data)) ?? []).compactMap { JSONSupport.object(from: $0) } }
    }
    var responseID: String? {
        lock.withLock {
            var parser = SSEParser()
            return ((try? parser.append(data)) ?? []).compactMap { (JSONSupport.object(from: $0)?["response"] as? [String: Any])?["id"] as? String }.first
        }
    }
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
func request(_ port: UInt16, _ path: String, _ body: [String: Any]? = nil, method: String? = nil) -> (Int, [String: Any]) {
    var req = URLRequest(url: URL(string: "/" + path, relativeTo: LocalEndpoint.url(host: "127.0.0.1", port: port)!)!)
    req.timeoutInterval = 8
    if let body {
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = JSONSupport.data(from: body)
    }
    if let method { req.httpMethod = method }
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
for (key, value) in [("conversation", "conv_x" as Any), ("tool_choice", "unknown"), ("background", "yes"),
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
check((thinkingObject["output"] as? [[String: Any]])?.first?["type"] as? String == "reasoning", "preserve real reasoning without inventing final text")
let cacheUsage = ResponsesAdapter.usage(["prompt_tokens": 10, "completion_tokens": 2,
                                        "prompt_tokens_details": ["cached_tokens": 3, "cache_write_tokens": 4]]) as! [String: Any]
check((cacheUsage["input_tokens_details"] as? [String: Any])?["cache_write_tokens"] as? Int == 4, "preserve backend cache-write token count")
let defaultCacheUsage = ResponsesAdapter.usage(["prompt_tokens": 10, "completion_tokens": 2]) as! [String: Any]
check((defaultCacheUsage["input_tokens_details"] as? [String: Any])?["cache_write_tokens"] as? Int == 0, "SDK-required cache_write_tokens uses compatibility default when absent")
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
let fixtureModel = ModelSpec(id: modelID, backend: .mlxLM, capabilities: ["responses", "text", "tools"], localPath: modelRoot.path)
let secondID = "fixture-vision"
let second = ModelSpec(id: secondID, backend: .mlxVLM, capabilities: ["responses", "text", "tools", "image_input", "structured_output"], localPath: modelRoot.path)
let fixtureSource = try String(contentsOf: root.appendingPathComponent("Tests/backend_fixture.py"), encoding: .utf8)
let fixtureMethod = #"""
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.path == '/v1/chat/completions'
        assert body['model'] == args.model
        assert set(body) <= {'model', 'messages', 'stream', 'stream_options', 'temperature', 'top_p', 'max_tokens', 'tools', 'tool_choice', 'response_format'}
        messages = body['messages']
        text = messages[-1].get('content', '')
        if isinstance(text, list):
            assert any(p.get('type') == 'image_url' for p in text)
            text = 'image accepted'
        if text == 'slow':
            time.sleep(4)
        if text == 'backend-error':
            data = json.dumps({'error': {'message': args.model}}).encode()
            self.send_response(500)
        else:
            tools = body.get('tools') or []
            message = {'role': 'assistant', 'content': 'fixture: ' + text}
            finish = 'stop'
            if tools and not any(m['role'] == 'tool' for m in messages):
                message = {'role': 'assistant', 'content': None, 'tool_calls': [
                    {'id': 'fixture-call', 'type': 'function', 'function': {'name': tools[0]['function']['name'], 'arguments': '{"city":"上海"}'}}
                ]}
                finish = 'tool_calls'
            if text == 'history-check':
                assert any(m['role'] == 'assistant' and m.get('content') == 'fixture: 你好' for m in messages)
                assert not any(m.get('content') == 'old instructions' for m in messages)
            if text == 'bad-policy':
                message = {'role': 'assistant', 'content': 'no tool'}
                finish = 'stop'
            if 'response_format' in body:
                message = {'role': 'assistant', 'content': '{"ok":true}'}
            if body.get('stream'):
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                def emit(delta, reason=None, fragmented=False):
                    chunk = {'choices': [{'index': 0, 'delta': delta, 'finish_reason': reason}]}
                    wire = ('data: ' + json.dumps(chunk, ensure_ascii=False) + '\r\n\r\n').encode()
                    if fragmented:
                        for byte in wire:
                            self.wfile.write(bytes([byte])); self.wfile.flush()
                    else:
                        self.wfile.write(wire); self.wfile.flush()
                if text == 'stream-error':
                    emit({'content': 'partial'})
                    self.wfile.write(b'data: {broken}\n\n'); self.wfile.flush()
                    return
                if text == 'stream-truncated':
                    emit({'content': 'partial'})
                    return
                if finish == 'tool_calls':
                    call = message['tool_calls'][0]
                    emit({'tool_calls': [{'index': 0, 'id': call['id'], 'type': 'function', 'function': {'name': call['function']['name'], 'arguments': '{"city":'}}]})
                    time.sleep(0.2)
                    emit({'tool_calls': [{'index': 0, 'function': {'arguments': '"上海"}'}}]})
                else:
                    emit({'content': '你'}, fragmented=True)
                    time.sleep(0.2)
                    emit({'content': '好'})
                time.sleep(0.45)
                emit({}, finish)
                self.wfile.write(b'data: {"choices": [], "usage": {"prompt_tokens": 7, "completion_tokens": 3}}\n\n')
                self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
                return
            data = json.dumps({'choices': [{'message': message, 'finish_reason': finish}], 'usage': {'prompt_tokens': 7, 'completion_tokens': 3}}).encode()
            self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        print('fixture request completed', flush=True)

"""#
let methodStart = fixtureSource.range(of: "    def do_POST(self):")!.lowerBound
let methodEnd = fixtureSource.range(of: "class LocalFixtureServer")!.lowerBound
let fixtureURL = temporary.appendingPathComponent("responses-fixture.py")
try (String(fixtureSource[..<methodStart]) + fixtureMethod + "\n" + String(fixtureSource[methodEnd...])).write(to: fixtureURL, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureURL.path)
let backend = BackendManager(pythonExecutable: fixtureURL.path,
                             logURL: temporary.appendingPathComponent("backend.log"))
let missingClear = DispatchSemaphore(value: 0)
backend.clearLogs { result in if case .failure = result { check(false, "missing log is successful clear") }; missingClear.signal() }
check(missingClear.wait(timeout: .now() + 3) == .success, "missing log clear completes successfully")
testState.diagnostics = { "Backend: \(backend.status)\n\(backend.readLogTail())" }

let malformedDeltaRequest: [String: Any] = ["model": modelID, "input": "x", "stream": true]
for wire in [
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}\n\n",
    "data: {\"choices\":[{\"delta\":{\"refusal\":\"unsupported\"}}]}\n\n"
] {
    let mapper = ResponsesStream(request: malformedDeltaRequest, response: ResponsesAdapter.skeleton(request: malformedDeltaRequest))
    do { _ = try mapper.append(Data(wire.utf8)); check(false, "malformed delta rejected") }
    catch { check(true, "terminal or unsupported backend delta rejected without silent loss") }
}
let boundedStore = ResponsesStore()
for _ in 0..<ResponsesStore.capacity {
    let entry = ResponseRecord(prepared: try ResponsesAdapter.prepare(simple), metricID: UUID())
    try boundedStore.insert(entry)
}
do {
    try boundedStore.insert(ResponseRecord(prepared: try ResponsesAdapter.prepare(simple), metricID: UUID()))
    check(false, "active store capacity")
} catch { check(true, "active responses cannot be silently evicted") }
for record in boundedStore.records.values { record.finished = true; record.finishedAt = Date().addingTimeInterval(-86_401) }
boundedStore.prune()
check(boundedStore.records.isEmpty, "expired process-local records are removed")

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
let stored = request(gatewayPort, "v1/responses", ["model": modelID, "input": "你好", "instructions": "old instructions"])
let storedID = stored.1["id"] as! String
check(request(gatewayPort, "v1/responses/" + storedID).1["status"] as? String == "completed", "GET stored response")
check(request(gatewayPort, "v1/responses/" + (response.1["id"] as! String)).0 == 404, "store=false is not retrievable")
check(request(gatewayPort, "v1/responses", ["model": modelID, "input": "history-check", "previous_response_id": storedID]).0 == 200, "previous_response_id includes assistant output but not old instructions")
check(request(gatewayPort, "v1/responses", ["model": modelID, "input": "x", "previous_response_id": "missing"]).0 == 404, "unknown previous response")
let inputPage = request(gatewayPort, "v1/responses/\(storedID)/input_items?order=asc&limit=1")
check(inputPage.0 == 200 && (inputPage.1["data"] as? [[String: Any]])?.count == 1, "input_items pagination")
let itemCursor = inputPage.1["last_id"] as! String
check((request(gatewayPort, "v1/responses/\(storedID)/input_items?after=\(itemCursor)").1["data"] as? [Any])?.isEmpty == true, "input_items after cursor")
check(request(gatewayPort, "v1/responses/\(storedID)/input_items?limit=0").0 == 400, "input_items rejects invalid limit")
check(request(gatewayPort, "v1/responses/\(storedID)", method: "DELETE").1["deleted"] as? Bool == true, "DELETE stored response")
check(request(gatewayPort, "v1/responses/" + storedID).0 == 404, "deleted response no longer retrievable")
let tools: [[String: Any]] = [["type": "function", "name": "weather", "parameters": ["type": "object", "properties": ["city": ["type": "string"]]], "strict": false]]
let toolResult = request(gatewayPort, "v1/responses", ["model": modelID, "input": "weather", "tools": tools, "tool_choice": "required", "parallel_tool_calls": false])
check(toolResult.0 == 200, "function calling request")
let toolItem = (toolResult.1["output"] as! [[String: Any]])[0]
check(toolItem["type"] as? String == "function_call" && toolItem["arguments"] as? String == "{\"city\":\"上海\"}", "function response call ID/name/arguments")
let followup = request(gatewayPort, "v1/responses", ["model": modelID, "previous_response_id": toolResult.1["id"]!, "input": [["type": "function_call_output", "call_id": toolItem["call_id"]!, "output": "晴，22度"]], "tools": tools])
check(followup.0 == 200 && (((followup.1["output"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("晴，22度") == true, "function output closes tool loop via previous_response_id")
let toolHistoryPage = request(gatewayPort, "v1/responses/\(followup.1["id"] as! String)/input_items?order=desc&limit=1")
let storedToolOutput = (toolHistoryPage.1["data"] as? [[String: Any]])?.first
check(storedToolOutput?["type"] as? String == "function_call_output" && storedToolOutput?["status"] as? String == "completed", "SDK-required tool output status is returned by input_items")
check(request(gatewayPort, "v1/responses", ["model": modelID, "input": [["type": "function_call_output", "call_id": "wrong", "output": "x"]]]).0 == 400, "reject orphan tool output")
check(request(gatewayPort, "v1/responses", ["model": modelID, "input": "bad-policy", "tools": tools, "tool_choice": "required"]).0 == 502, "MLX tool policy violation is explicit")
check(request(gatewayPort, "v1/responses", ["model": modelID, "input": "weather", "tools": tools, "tool_choice": ["type": "function", "name": "weather"]]).0 == 200, "named function choice")
check(rejected(["model": modelID, "input": "x", "tools": [["type": "web_search"]]]), "hosted tools unsupported")
check(rejected(["model": modelID, "input": "x", "tools": [["type": "function", "name": "test", "strict": true]]]), "strict function schema is explicitly unsupported")
check(rejected(["model": modelID, "input": "x", "text": ["format": ["type": "json_object"]]]), "LM structured output unsupported")
check(rejected(["model": modelID, "input": "x", "text": ["verbosity": "high"]]), "no silent unimplemented nested fields")
check(rejected(["model": modelID, "input": [["role": "user", "content": "x", "status": "invalid"]]]), "invalid input status cannot escape into stored SDK items")

let visual = try ResponsesAdapter.prepare(["model": secondID, "input": [["role": "user", "content": [["type": "input_text", "text": "图片"], ["type": "input_image", "image_url": "https://example.com/image.png"]]]]], model: second)
check((visual.chat["messages"] as? [[String: Any]])?.last?["content"] is [[String: Any]], "VLM preserves text and image parts")
check((visual.inputItems[0]["content"] as? [[String: Any]])?[1]["detail"] as? String == "auto", "stored image content has SDK-required detail")
let assistantHistory = try ResponsesAdapter.prepare(["model": modelID, "input": [["id": NSNull(), "role": "assistant", "content": "earlier reply"], ["role": "user", "content": "continue"]]])
check(assistantHistory.inputItems[0]["id"] is String && assistantHistory.inputItems[0]["status"] as? String == "completed", "assistant history has SDK-required id and status")
check(((assistantHistory.inputItems[0]["content"] as? [[String: Any]])?.first?["annotations"] as? [Any])?.isEmpty == true, "assistant history has SDK-required output annotations")

do {
    _ = try ResponsesAdapter.prepare(["model": secondID, "input": [["role": "user", "content": [["type": "input_image", "image_url": "file:///private/model"]]]]], model: second)
    check(false, "reject local image path")
} catch { check(true, "local image paths rejected") }
let schema: [String: Any] = ["type": "json_schema", "name": "result", "schema": ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"], "additionalProperties": false], "strict": true]
let structured = try ResponsesAdapter.prepare(["model": secondID, "input": "json", "text": ["format": schema]], model: second)
check((structured.chat["response_format"] as? [String: Any])?["type"] as? String == "json_schema", "VLM JSON schema maps to actual response_format")
let textFile: [String: Any] = ["type": "input_file", "filename": "notes.txt", "file_data": Data("file text 中文".utf8).base64EncodedString()]
check(request(gatewayPort, "v1/responses", ["model": modelID, "input": [["role": "user", "content": [textFile]]]]).0 == 200, "inline UTF-8 file round trip")
let pdfData = NSMutableData()
var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
let consumer = CGDataConsumer(data: pdfData)!
let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
pdf.beginPDFPage(nil); pdf.setFillColor(CGColor(gray: 0.5, alpha: 1)); pdf.fill(mediaBox); pdf.endPDFPage(); pdf.closePDF()
let pdfFile: [String: Any] = ["type": "input_file", "filename": "drawing.pdf", "file_data": (pdfData as Data).base64EncodedString()]
let pdfParts = try ResponsesFiles.parts(pdfFile, vision: true)
check(pdfParts.count == 2 && pdfParts[1]["type"] as? String == "image_url", "PDF includes rendered page image, not just extracted text")
check(rejected(["model": modelID, "input": [["role": "user", "content": [pdfFile]]]]), "text LM refuses PDF rather than dropping page images")
let stream = StreamingProbe()
stream.start(gatewayPort, "v1/responses", ["model": modelID, "input": "stream", "stream": true])
let events = stream.wait()
check(stream.status == 200 && stream.contentType.hasPrefix("text/event-stream"), "SSE content type")
check(events.first?["type"] as? String == "response.created" && events.last?["type"] as? String == "response.completed", "SSE lifecycle event order")
check(events.compactMap { $0["sequence_number"] as? Int } == Array(events.indices), "SSE contiguous sequence numbers")
check(events.filter { $0["type"] as? String == "response.output_text.delta" }.compactMap { $0["delta"] as? String } == ["你", "好"], "fragmented UTF-8 maps to separate real content deltas")
check(stream.firstDelta != nil && stream.endedAt!.timeIntervalSince(stream.firstDelta!) >= 0.4, "first content arrives before delayed backend completion (true incremental SSE)")
let completedStream = events.last?["response"] as! [String: Any]
check((completedStream["usage"] as? [String: Any])?["output_tokens"] as? Int == 3, "stream final usage")
let streamTools = StreamingProbe()
streamTools.start(gatewayPort, "v1/responses", ["model": modelID, "input": "tools", "stream": true, "tools": tools, "tool_choice": "required"])
let toolEvents = streamTools.wait()
check(toolEvents.filter { $0["type"] as? String == "response.function_call_arguments.delta" }.count == 2, "function arguments stream progressively")
check(toolEvents.last?["type"] as? String == "response.completed", "tool SSE completes")
let streamedCall = ((toolEvents.last?["response"] as? [String: Any])?["output"] as? [[String: Any]])?.first
check(streamedCall?["arguments"] as? String == "{\"city\":\"上海\"}", "tool arguments reconstruct without corruption")
for input in ["stream-error", "stream-truncated"] {
    let failed = StreamingProbe(); failed.start(gatewayPort, "v1/responses", ["model": modelID, "input": input, "stream": true])
    let failureEvents = failed.wait()
    check(failureEvents.last?["type"] as? String == "response.failed", "malformed/truncated stream has explicit terminal failure")
}
let backgroundStart = Date()
let background = request(gatewayPort, "v1/responses", ["model": modelID, "input": "slow", "background": true, "store": false])
let backgroundID = background.1["id"] as! String
check(background.0 == 200 && backgroundStart.timeIntervalSinceNow > -1 && background.1["status"] as? String == "queued", "background returns before inference")
check(request(gatewayPort, "v1/responses/" + backgroundID).0 == 200, "background store=false is temporarily pollable")
check(request(gatewayPort, "v1/responses/\(backgroundID)/cancel", [:]).1["status"] as? String == "cancelled", "cancel background")
check(request(gatewayPort, "v1/responses/\(backgroundID)/cancel", [:]).1["status"] as? String == "cancelled", "cancel is idempotent")
let cancelledStream = StreamingProbe()
cancelledStream.start(gatewayPort, "v1/responses", ["model": modelID, "input": "slow", "stream": true, "background": true])
awaitCondition("background stream is cancellable before first content") { cancelledStream.responseID != nil }
let cancelledStreamID = cancelledStream.responseID!
check(request(gatewayPort, "v1/responses/\(cancelledStreamID)/cancel", [:]).1["status"] as? String == "cancelled", "cancel streaming background response")
let cancellationEvents = cancelledStream.wait()
check(cancellationEvents.last?["type"] as? String == "error" && cancellationEvents.last?["code"] as? String == "response_cancelled", "cancel uses standard SSE error event rather than an invented event type")
let bgStream = StreamingProbe()
bgStream.start(gatewayPort, "v1/responses", ["model": modelID, "input": "stream", "stream": true, "background": true])
awaitCondition("background stream response ID is visible") { bgStream.responseID != nil }
let bgStreamID = bgStream.responseID!
bgStream.task?.cancel()
_ = bgStream.wait()
let resumed = StreamingProbe(); resumed.start(gatewayPort, "v1/responses/\(bgStreamID)?stream=true&starting_after=0")
let resumedEvents = resumed.wait()
check(resumedEvents.first?["sequence_number"] as? Int == 1 && resumedEvents.last?["type"] as? String == "response.completed", "background SSE reconnect replays after cursor and follows live events")
let foreground = StreamingProbe()
foreground.start(gatewayPort, "v1/responses", ["model": modelID, "input": "stream", "stream": true])
awaitCondition("foreground ID") { foreground.responseID != nil }
let foregroundID = foreground.responseID!
foreground.task?.cancel(); _ = foreground.wait()
awaitCondition("foreground disconnect cancels generation") { request(gatewayPort, "v1/responses/" + foregroundID).1["status"] as? String == "cancelled" }
let clearing = DispatchSemaphore(value: 0)
backend.clearLogs { result in if case .failure = result { check(false, "clear active logs") }; clearing.signal() }
check(clearing.wait(timeout: .now() + 3) == .success, "clear logs completion")
_ = request(gatewayPort, "v1/responses", simple)
awaitCondition("active child writes after clear") { backend.readLogTail().contains("fixture request completed") }
let logData = try Data(contentsOf: temporary.appendingPathComponent("backend.log"))
check(!logData.contains(0), "truncate followed by O_APPEND never creates sparse NUL gap")
let metrics = RequestMetricsStore.shared.snapshot()
check(metrics.inFlight == 0, "all completed, failed and cancelled requests finish metrics")
check(metrics.records.contains { $0.firstTokenLatency != nil && $0.outputTokens == 3 }, "stream TTFT and token counts recorded")
check(metrics.records.contains { $0.firstTokenLatency == nil && $0.succeeded }, "nonstream TTFT remains unavailable")
check(metrics.records.contains { $0.error == "client_disconnected" }, "disconnect metrics terminate")
check(!String(describing: metrics.records).contains(modelRoot.path), "metrics never expose private model paths")

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
let imageRequest: [String: Any] = ["model": secondID, "input": [["role": "user", "content": [["type": "input_image", "image_url": "data:image/png;base64,eA=="]]]]]
check(request(gatewayPort, "v1/responses", imageRequest).0 == 200, "VLM image content reaches downstream as image_url parts")
check(request(gatewayPort, "v1/responses", ["model": secondID, "input": [["role": "user", "content": [pdfFile]]]]).0 == 200, "VLM PDF pages reach downstream")
let structuredResult = request(gatewayPort, "v1/responses", ["model": secondID, "input": "json", "text": ["format": schema]])
check(structuredResult.0 == 200 && ((structuredResult.1["text"] as? [String: Any])?["format"] as? [String: Any])?["type"] as? String == "json_schema", "structured output HTTP round trip preserves requested format")
let stoppedStream = StreamingProbe()
stoppedStream.start(gatewayPort, "v1/responses", ["model": secondID, "input": "stream", "stream": true])
awaitCondition("in-flight SSE starts before backend stop") { stoppedStream.lock.withLock { stoppedStream.firstDelta != nil } }
backend.stop()
let stoppedEvents = stoppedStream.wait()
check(stoppedEvents.last?["type"] as? String == "response.failed", "backend stop terminates SSE with failure")
awaitCondition("stopped stream fixture stops") { backend.status.state == .stopped }
backend.start(model: second, host: "127.0.0.1", port: modelPort)
awaitCondition("restart vision fixture") { backend.status.state == .ready }

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
print("PASS: \(testState.checks) checks — Responses, progressive SSE, tools, images/PDF, storage, background/resume/cancel, metrics and logs")
