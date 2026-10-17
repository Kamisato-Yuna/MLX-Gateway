import Foundation
import Network

final class ImageTestBox: @unchecked Sendable {
    let lock = NSLock(); var status = 0; var data = Data()
}
func imageRequest(_ port: UInt16, _ path: String, _ object: [String: Any]? = nil, method: String = "GET") -> (Int, [String: Any], Data) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
    request.httpMethod = method; request.timeoutInterval = 20
    if let object { request.httpBody = JSONSupport.data(from: object); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let box = ImageTestBox(), done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        box.lock.withLock { box.status = (response as? HTTPURLResponse)?.statusCode ?? 0; box.data = data ?? Data() }; done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 22)
    return box.lock.withLock { (box.status, JSONSupport.object(from: box.data) ?? [:], box.data) }
}
func imageWait(_ label: String, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(20)
    while !condition() && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
    precondition(condition(), "image service timed out: \(label)")
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-image-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let runtime = temp.appendingPathComponent("runtime")
let imageRoot = runtime.appendingPathComponent("image-service")
let model = imageRoot.appendingPathComponent("model")
try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
for path in ["model_index.json", "config.json", "transformer/config.json", "transformer/model.safetensors", "vae/config.json",
             "vae/diffusion_pytorch_model.safetensors", "processor/tokenizer.json", "text_encoder/config.json", "text_encoder/model-00001-of-00001.safetensors"] {
    let file = model.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: file)
}
let launcher = temp.appendingPathComponent("mlx-serve")
let fixture = root.appendingPathComponent("Tests/image_fixture.py")
try Data(("#!/bin/sh\nexec \"" + "/usr/bin/python3" + "\" \"" + fixture.path + "\" \"$@\"\n").utf8).write(to: launcher)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
let port: UInt16 = 44391, gatewayPort: UInt16 = 44392
try LocalEndpoint.checkAvailable(host: "127.0.0.1", port: port)
try LocalEndpoint.checkAvailable(host: "127.0.0.1", port: gatewayPort)
let configuration: [String: Any] = ["title": "Qwen Image 2.1 UC", "model": "qwen-image-uc-mlx-serve",
    "model_path": model.path, "executable_path": launcher.path, "host": "127.0.0.1", "port": Int(port),
    "readiness_timeout": 30, "request_timeout": 20]
try FileManager.default.createDirectory(at: imageRoot, withIntermediateDirectories: true)
try JSONSupport.data(from: configuration).write(to: imageRoot.appendingPathComponent("gateway.json"))
let noConfig = ImageGenerationService(runtimeDirectory: temp.appendingPathComponent("missing").path)
let unconfiguredPort: UInt16 = 44393
let unconfiguredServer = GatewayServer(registry: ModelRegistry(models: []), backendManager: BackendManager(), host: "127.0.0.1", port: unconfiguredPort,
    imageService: noConfig)
try unconfiguredServer.start(); defer { unconfiguredServer.stop() }
imageWait("unconfigured gateway listener") { imageRequest(unconfiguredPort, "health").0 == 200 }
precondition(imageRequest(unconfiguredPort, "v1/images/generations", ["model": "x", "prompt": "p"], method: "POST").0 == 404, "unconfigured route is 404")
let imageService = ImageGenerationService(runtimeDirectory: runtime.path, logURL: temp.appendingPathComponent("image.log"))
precondition(imageService.configurationError == nil, "valid image configuration has no error")
let gateway = GatewayServer(registry: ModelRegistry(models: []), backendManager: BackendManager(), host: "127.0.0.1", port: gatewayPort,
                            imageService: imageService)
try gateway.start(); defer { gateway.stop() }
imageWait("configured gateway listener") { imageRequest(gatewayPort, "health").0 == 200 }
let payload: [String: Any] = ["model": configuration["model"]!, "prompt": "a red flower"]
precondition(imageRequest(gatewayPort, "v1/images/generations", payload, method: "POST").0 == 503, "stopped backend request does not start a process")
precondition(imageService.status.state == .stopped, "request does not implicitly start backend")
imageService.start(); imageWait("image backend ready, configuration error=\(imageService.configurationError ?? "none")") { imageService.status.state == .ready }
let success = imageRequest(gatewayPort, "v1/images/generations", payload, method: "POST")
precondition(success.0 == 200 && ((success.1["data"] as? [[String: Any]])?.first?["b64_json"] as? String) != nil, "ready image generation returns b64 PNG")
for invalid in [["model": configuration["model"]!, "prompt": "x", "n": 2],
                ["model": configuration["model"]!, "prompt": "x", "response_format": "url"],
                ["model": configuration["model"]!, "prompt": "x", "extra": true],
                ["model": configuration["model"]!, "prompt": ""],
                ["model": configuration["model"]!, "prompt": "x", "image": "data:image/png;base64,..."],
                ["model": configuration["model"]!, "prompt": "x", "n": 1.5],
                ["model": configuration["model"]!, "prompt": "x", "n": true],
                ["model": configuration["model"]!, "prompt": "x", "steps": 0],
                ["model": configuration["model"]!, "prompt": "x", "steps": 101],
                ["model": configuration["model"]!, "prompt": "x", "seed": UInt64(UInt32.max) + 1],
                ["model": configuration["model"]!, "prompt": "x", "guidance_scale": 21],
                ["model": configuration["model"]!, "prompt": "x", "guidance_scale": true]] as [[String: Any]] {
    precondition(imageRequest(gatewayPort, "v1/images/generations", invalid, method: "POST").0 == 400, "invalid generation parameter is rejected")
}
precondition(imageRequest(gatewayPort, "v1/images/edits", payload, method: "POST").0 == 404, "image edits remain unavailable")
precondition(imageRequest(gatewayPort, "v1/responses", ["model": configuration["model"]!, "input": "x"], method: "POST").0 == 400,
             "image model cannot be used with Responses")
let modelList = imageRequest(gatewayPort, "v1/models").2
precondition(!String(decoding: modelList, as: UTF8.self).contains(model.path) && !String(decoding: modelList, as: UTF8.self).contains(launcher.path), "model list does not expose local paths")
let failure = imageRequest(gatewayPort, "v1/images/generations", ["model": configuration["model"]!, "prompt": "failure"], method: "POST")
precondition(failure.0 == 502 && !String(decoding: failure.2, as: UTF8.self).contains("/private/internal"), "downstream errors are redacted")
precondition(imageRequest(gatewayPort, "v1/images/generations", ["model": configuration["model"]!, "prompt": "corrupt"], method: "POST").0 == 502,
             "corrupt PNG is rejected")
let slow = ImageTestBox(), slowDone = DispatchSemaphore(value: 0)
var slowReq = URLRequest(url: URL(string: "http://127.0.0.1:\(gatewayPort)/v1/images/generations")!)
slowReq.httpMethod = "POST"; slowReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
slowReq.httpBody = JSONSupport.data(from: ["model": configuration["model"]!, "prompt": "slow"])
URLSession.shared.dataTask(with: slowReq) { data, response, _ in slow.lock.withLock { slow.status = (response as? HTTPURLResponse)?.statusCode ?? 0; slow.data = data ?? Data() }; slowDone.signal() }.resume()
Thread.sleep(forTimeInterval: 0.2)
precondition(imageRequest(gatewayPort, "v1/images/generations", payload, method: "POST").0 == 429, "parallel generation is rejected while busy")
imageService.stop()
precondition(slowDone.wait(timeout: .now() + 5) == .success && slow.lock.withLock({ slow.status }) == 503, "stop cancels an in-flight image request")
imageWait("image backend stopped") { imageService.status.state == .stopped }
precondition(imageRequest(gatewayPort, "v1/images/generations", payload, method: "POST").0 == 503, "stopped backend request fails closed")
print("PASS: image backend config, lifecycle, validation, model routing and path privacy")
