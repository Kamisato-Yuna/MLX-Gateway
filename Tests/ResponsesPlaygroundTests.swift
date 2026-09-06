import Foundation
import ImageIO
import PDFKit

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

private actor Collector {
    var events: [ResponsesClientEvent] = []
    var raw = Data()
    var status: Int?
    func receive(_ update: ResponsesClientUpdate) {
        switch update {
        case .headers(let code, _, _): status = code
        case .batch(let data, let batch): raw.append(data); events.append(contentsOf: batch)
        }
    }
    var count: Int { events.count }
}

@main
struct ResponsesPlaygroundTests {
    @MainActor
    static func main() async throws {
        let endpoint = CommandLine.arguments[1]
        try parserTests()
        try requestTests(endpoint)
        try storeTests()
        try await clientTests(endpoint)
        try await stateTests(endpoint)
        print("PASS: Responses Playground JSON / SSE / cancellation / HTTP / session / storage fixtures")
    }

    static func parserTests() throws {
        var parser = ResponsesClientSSEParser()
        let wire = "\u{FEFF}:hello\r\nid: abc\revent: vendor.future\rdata: 你好\rdata: second\r\rdata:\n\nevent: unfinished\ndata: lost"
        var events: [ResponsesClientEvent] = []
        for byte in wire.utf8 { if let event = try parser.append(byte) { events.append(event) } }
        require(events.count == 2, "CR/LF framing and incomplete EOF")
        require(events[0].data == "你好\nsecond", "UTF-8 and multiline data")
        require(events[0].name == "vendor.future", "unknown events retained")
        require(events[1].serverID == "abc", "SSE id persists")
        require(events[1].data == "", "empty data event dispatched")
        var oversized = ResponsesClientSSEParser()
        do {
            for _ in 0...ResponsesClientSSEParser.maximumEventBytes { _ = try oversized.append(65) }
            fatalError("unbounded event accepted")
        } catch { require(error.localizedDescription.contains("1 MiB"), "event cap explained") }
        var invalid = ResponsesClientSSEParser()
        _ = try invalid.append(255)
        do { _ = try invalid.append(10); fatalError("invalid UTF-8 accepted") } catch {}
    }

    static func requestTests(_ endpoint: String) throws {
        let body = "{\n \"input\": \"hi\", \"vendor_extension\": {\"x\": [1, true, null]}\n}"
        var input = ResponsesClientRequest(baseURL: endpoint + "/", apiKey: "fixture-memory-key", operation: .create, body: body, responseID: "")
        let request = try input.urlRequest()
        require(request.httpBody == Data(body.utf8), "exact JSON roundtrip")
        require(request.url!.path == "/v1/responses", "base URL normalized")
        input.operation = .inputItems; input.responseID = "resp_123"; input.after = "item/a&b"
        let url = try input.urlRequest().url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        require(components.queryItems!.contains(URLQueryItem(name: "after", value: "item/a&b")), "pagination encoding")
        input.responseID = "../delete"
        do { _ = try input.urlRequest(); fatalError("path traversal accepted") } catch {}
        input.operation = .create; input.baseURL = "https://user:secret@example.com/v1"
        do { _ = try input.urlRequest(); fatalError("URL credentials accepted") } catch {}
        input.baseURL = endpoint; input.body = "[]"
        do { _ = try input.urlRequest(); fatalError("non-object accepted") } catch {}
        for preset in ResponsesTestPreset.all {
            let object = try ResponsesTestJSON.object(preset.body(modelID: "model\"中文"))
            require(object["model"] as? String == "model\"中文", "preset model escaping")
            if preset.id == "function" {
                let tools = object["tools"] as! [[String: Any]]
                require(tools[0]["strict"] as? Bool == false, "default function preset is compatible with local gateway")
            }
            if preset.id == "image" || preset.id == "file" {
                let input = object["input"] as! [[String: Any]]
                let content = input[0]["content"] as! [[String: Any]]
                let uri = content[1][preset.id == "image" ? "image_url" : "file_data"] as! String
                let data = Data(base64Encoded: String(uri.split(separator: ",", maxSplits: 1)[1]))!
                if preset.id == "image" {
                    require(decodesFourColorPixels(data), "PNG must decode and render all four color quadrants, not just report header dimensions")
                    // Previous fixture had readable IHDR dimensions but an invalid compressed pixel stream.
                    let broken = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAZElEQVR4nO3PIREAIRAAQOJgaIBBE4cGZEITB/P6PRkQ53ZmC2z6eguV5wmVBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBASeA3WNUP8uoQQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEnl2Flil4c7zVRwAAAABJRU5ErkJggg==")!
                    require(!decodesFourColorPixels(broken), "regression: valid PNG dimensions must not hide a broken pixel stream")
                } else {
                    let document = PDFDocument(data: data)!
                    require(document.pageCount == 1 && document.string?.contains("Hello") == true, "native PDF decoder validates self-contained file preset")
                }
            }
        }
    }

    static func decodesFourColorPixels(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == 64, image.height == 64 else { return false }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 64, height: 64,
                                          bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return true
        }
        guard rendered else { return false }
        let expected: Set<[UInt8]> = [[235, 75, 65, 255], [40, 130, 230, 255], [60, 180, 115, 255], [245, 190, 45, 255]]
        // Force access to every decoded pixel and require four uniform, distinct quadrants.
        var quadrants = Set<[UInt8]>()
        for originY in [0, 32] {
            for originX in [0, 32] {
                let start = (originY * 64 + originX) * 4
                let color = Array(pixels[start..<start + 4])
                guard expected.contains(color) else { return false }
                quadrants.insert(color)
                for y in originY..<originY + 32 {
                    for x in originX..<originX + 32 {
                        let offset = (y * 64 + x) * 4
                        guard Array(pixels[offset..<offset + 4]) == color else { return false }
                    }
                }
            }
        }
        return quadrants == expected
    }

    static func storeTests() throws {
        let project = ResponsesTestProject(name: "自定义", body: "{\"unknown\": {\"x\":1}, \"input\":\"你好\"}")
        let data = try ResponsesPlaygroundProjectStore.encode([project])
        let decoded = try ResponsesPlaygroundProjectStore.decode(data)
        require(decoded == [project], "project exact roundtrip")
        let portable = Data("[{\"name\":\"Portable\",\"body\":\"{}\"}]".utf8)
        let decodedPortable = try ResponsesPlaygroundProjectStore.decode(portable)
        require(decodedPortable.count == 1, "import name+body without ID")
        do { _ = try ResponsesPlaygroundProjectStore.decode(Data("[{\"name\":\"x\",\"body\":\"[]\"}]".utf8)); fatalError("invalid import") } catch {}
    }

    static func clientTests(_ endpoint: String) async throws {
        let client = ResponsesClient()
        let collector = Collector()
        let request = ResponsesClientRequest(baseURL: endpoint, apiKey: "", operation: .create, body: "{\"fixture\":\"stream\"}", responseID: "")
        let task = Task { try await client.perform(request) { await collector.receive($0) } }
        try await Task.sleep(for: .milliseconds(100))
        let early = await collector.count
        require(early >= 2, "events must arrive before stream closes, including rapid first events before idle")
        try await task.value
        let events = await collector.events
        require(events.count == 3 && events[1].data.contains("你好"), "real streamed Unicode events")
        var cancelRequest = request
        cancelRequest.body = "{\"fixture\":\"cancel\"}"
        let cancelledCollector = Collector()
        let cancelled = Task { try await client.perform(cancelRequest) { await cancelledCollector.receive($0) } }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        do { try await cancelled.value; fatalError("cancellation returned success") } catch {}
        let count = await cancelledCollector.count
        require(count == 2, "cancellation must retain partial events without duplicate flush")
        let redirected = Collector()
        var redirectRequest = request; redirectRequest.body = "{\"fixture\":\"redirect\"}"
        try await client.perform(redirectRequest) { await redirected.receive($0) }
        let status = await redirected.status
        require(status == 307, "redirect must not forward credentials")
    }

    @MainActor
    static func stateTests(_ endpoint: String) async throws {
        let suite = "ResponsesPlaygroundTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ResponsesPlaygroundProjectStore(defaults: defaults)
        let session = ResponsesPlaygroundSession(baseURL: endpoint, modelID: "first", store: store)
        session.body = "{\"input\":\"edited\",\"vendor\":3}"
        session.select("stream", modelID: "second")
        session.select("text", modelID: "third")
        require(session.body.contains("edited") && !session.body.contains("third"), "model/preset changes preserve edits")
        session.apiKey = "fixture-memory-key"
        session.projectName = "Saved"; session.saveProject(asNew: true)
        let saved = defaults.data(forKey: ResponsesPlaygroundProjectStore.key)!
        require(!String(decoding: saved, as: UTF8.self).contains(session.apiKey), "key not persisted")
        session.body = "{\"input\":\"fixture-memory-key\"}"; session.saveProject(asNew: true)
        require(session.projects.count == 1, "current key in body cannot be persisted")
        let before = session.projects
        session.importProjects(Data("{}".utf8))
        require(session.projects == before, "invalid import is atomic")
        for scenario in ["stream", "partial", "failed", "error", "unknown"] {
            session.body = "{\"fixture\":\"\(scenario)\"}"
            session.start(.create)
            try await wait(session)
            switch scenario {
            case "stream":
                require(session.output == "你好", "do not duplicate final text after deltas")
                require(session.firstToken != nil && session.usage.contains("total_tokens"), "stream metrics")
                require(session.status.contains("completed"), "completed event")
            case "partial": require(session.status.contains("未收到"), "partial stream cannot claim completion")
            case "failed": require(session.errorMessage?.contains("backend_failed") == true, "failed event retained")
            case "error": require(session.httpStatus == 422 && session.errorMessage?.contains("unsupported_feature") == true, "HTTP error retained")
            default: require(session.events.contains { $0.name == "vendor.extension" }, "unknown extension event retained")
            }
        }
        session.responseID = "resp_unconfirmed"; session.start(.cancel); try await wait(session)
        require(session.status.contains("未确认"), "200 cancel is not cancelled proof")
        session.responseID = "resp_fixture"; session.start(.cancel); try await wait(session)
        require(session.status == "服务端确认 cancelled", "cancel requires server status")
        session.start(.retrieve); try await wait(session)
        require(session.output == "你好" && session.responseID == "resp_fixture", "GET response state")
        session.afterID = "item/a&b"; session.start(.inputItems); try await wait(session)
        require(String(decoding: session.raw, as: UTF8.self).contains("limit=100"), "session input items request")
        session.start(.delete); try await wait(session)
        require(String(decoding: session.raw, as: UTF8.self).contains("deleted"), "delete response exposed")
        session.body = "{\"fixture\":\"headers-slow\"}"; session.start(.create)
        try await Task.sleep(for: .milliseconds(100))
        session.stopReceiving(); try await wait(session)
        require(session.status == "本地接收已停止" && !session.running, "cancellation before headers clears busy state")
        session.timeout = "1"; session.start(.create); try await wait(session)
        require(session.status == "请求未完成" && session.errorMessage != nil, "slow headers timeout is a failure, not a cancellation confirmation")
        session.timeout = "180"
        session.body = "{}"; session.start(.create); try await wait(session)
        require(session.status.contains("completed") && session.firstToken == nil, "new run after cancel resets state")
        session.deleteSelectedProject(modelID: nil)
        require(session.projects.isEmpty, "custom project deletion persists")
        let reloaded = try store.load()
        require(reloaded.isEmpty, "deleted project does not reappear")
    }

    @MainActor
    static func wait(_ session: ResponsesPlaygroundSession) async throws {
        for _ in 0..<250 {
            if !session.running { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        fatalError("session stuck running")
    }
}
