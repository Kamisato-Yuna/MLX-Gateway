import Foundation

struct ResponsesTestProject: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var body: String

    enum CodingKeys: String, CodingKey { case id, name, body }

    init(id: UUID = UUID(), name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        body = try values.decode(String.self, forKey: .body)
    }
}

struct ResponsesTestPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let hint: String

    static let all: [Self] = [
        .init(id: "text", name: "快速文本", hint: "先手动启动本地模型，再发送一个简短问题。"),
        .init(id: "stream", name: "流式输出", hint: "观察真实 SSE 增量、首个文本增量时间与全部事件。"),
        .init(id: "json", name: "结构化 JSON", hint: "要求严格 JSON Schema；端点或模型不支持时会显示原始错误。"),
        .init(id: "function", name: "函数调用", hint: "声明 get_weather；只展示调用参数，不执行函数。"),
        .init(id: "tool-output", name: "提交工具结果", hint: "填入真实 previous_response_id、call_id 和你明确提供的结果后发送。"),
        .init(id: "previous", name: "继续存储会话", hint: "先用「存储响应」获得 ID，再替换 previous_response_id。"),
        .init(id: "store", name: "存储响应", hint: "要求服务端存储响应；成功后可用下方 GET、input_items、DELETE 操作。"),
        .init(id: "background", name: "后台响应", hint: "后台生成供 GET / cancel 测试；通常仅支持后台响应取消。"),
        .init(id: "image", name: "图像输入", hint: "内置 64×64 四色 PNG，可直接测试视觉输入；可替换 image_url 为 URL 或 data URI。"),
        .init(id: "file", name: "文件输入", hint: "内置小型 PDF data URI；也可编辑为已上传的 file_id。此面板不上传文件。"),
        .init(id: "audio", name: "音频兼容性探测", hint: "input_audio 是兼容端点扩展探测，并非宣称标准 Responses 或本地模型支持；替换为 WAV base64。")
    ]

    func body(modelID: String?) -> String {
        var object: [String: Any] = ["input": "请用中文一句话介绍你自己。", "max_output_tokens": 128, "store": false]
        if let modelID, !modelID.isEmpty { object["model"] = modelID }
        switch id {
        case "stream":
            object["stream"] = true
            object["input"] = "用中文列出学习 Swift 的三个建议，每条一句话。"
        case "json":
            object["input"] = "介绍 Swift：返回 name 和一个简短 summary。"
            object["text"] = ["format": ["type": "json_schema", "name": "language", "strict": true,
                "schema": ["type": "object", "properties": ["name": ["type": "string"], "summary": ["type": "string"]],
                           "required": ["name", "summary"], "additionalProperties": false]]]
        case "function":
            object["store"] = true
            object["input"] = "查询上海的天气，请调用 get_weather。"
            object["tools"] = [["type": "function", "name": "get_weather", "description": "查询城市天气",
                "parameters": ["type": "object", "properties": ["city": ["type": "string"]],
                               "required": ["city"], "additionalProperties": false], "strict": false]]
            object["tool_choice"] = ["type": "function", "name": "get_weather"]
        case "tool-output":
            object["previous_response_id"] = "填写响应ID"
            object["input"] = [["type": "function_call_output", "call_id": "填写call_id", "output": "填写你确认的工具结果"]]
        case "previous":
            object["previous_response_id"] = "填写响应ID"
            object["input"] = "我刚才让你记住的单词是什么？"
        case "store", "background":
            object["store"] = true
            object["input"] = "请记住单词：流萤。只回复已记住。"
            if id == "background" { object["background"] = true }
        case "image":
            object["input"] = [["role": "user", "content": [
                ["type": "input_text", "text": "描述图片中的四个色块。"],
                ["type": "input_image", "image_url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAnElEQVR4nNXOsQ3CABTEUMeiYhwaqhRUKVJlDAZjHCZhiQwRfSG/AXy3/PYXk9bnZ7QvcRIncRIncRIncRIncRIncRIncRIncRIncRIncRIncRIncRIncRIncRIncRIncbfj/Rgd+N630b7ESZzESZzESZzESZzESZzESZzESZzESZzESZzESZzESZzESZzESZzESZzESZz/PnDVCXObBRxJ0GoHAAAAAElFTkSuQmCC"]]]]
        case "file":
            object["input"] = [["role": "user", "content": [
                ["type": "input_text", "text": "读取此 PDF，输出里面的单词。"],
                ["type": "input_file", "filename": "hello.pdf", "file_data": "data:application/pdf;base64," + Self.samplePDF.base64EncodedString()]]]]
        case "audio":
            object["input"] = [["role": "user", "content": [
                ["type": "input_text", "text": "请转写这段音频。"],
                ["type": "input_audio", "input_audio": ["data": "填写WAV文件的base64", "format": "wav"]]]]]
        default: break
        }
        return ResponsesTestJSON.pretty(object)
    }

    // A self-contained PDF avoids fetching external sample content when opening a preset.
    private static var samplePDF: Data {
        let stream = "BT /F1 20 Tf 30 100 Td (Hello) Tj ET"
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 150] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"]
        var pdf = "%PDF-1.4\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 6\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}

enum ResponsesTestJSON {
    static func object(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ResponsesClientError.message("请求 body 必须是 JSON 对象。")
        }
        return object
    }

    static func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return string
    }
}
