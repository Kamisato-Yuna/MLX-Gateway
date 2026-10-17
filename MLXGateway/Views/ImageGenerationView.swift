import SwiftUI
import AppKit

struct ImageGenerationView: View {
    @ObservedObject var controller: GatewayController
    @State private var prompt = ""
    @State private var size = "1024x1024"
    @State private var steps = 28
    @State private var seedText = ""
    @State private var generatedImage: NSImage?
    @State private var pngData: Data?
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var notice: String?

    private let sizes = ["512x512", "1024x1024", "1024x1536", "1536x1024"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "photo.artframe").font(.title2).foregroundStyle(.tint)
                        .frame(width: 48, height: 48).glassEffect(.regular, in: .rect(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(controller.imageService.configuration?.title ?? "图像生成服务").font(.title2.weight(.semibold))
                        Text(controller.imageStatus.message).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(controller.imageStatus.state == .ready ? .green : (controller.imageStatus.state == .failed ? .red : .secondary))
                        .frame(width: 9, height: 9)
                    Text(stateTitle).font(.caption).foregroundStyle(.secondary)
                }
                if let configuration = controller.imageService.configuration {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        GridRow { Text("模型").foregroundStyle(.secondary); Text(configuration.model).textSelection(.enabled) }
                        GridRow { Text("监听地址").foregroundStyle(.secondary); Text("http://\(configuration.host):\(String(configuration.port))").textSelection(.enabled) }
                        GridRow { Text("模型目录").foregroundStyle(.secondary); Text(configuration.modelPath).font(.caption.monospaced()).textSelection(.enabled) }
                        GridRow { Text("启动程序").foregroundStyle(.secondary); Text(configuration.executablePath).font(.caption.monospaced()).textSelection(.enabled) }
                    }.font(.callout)
                    if let issue = controller.imageService.configurationError {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if let issue = configuration.validationMessage {
                        Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Label(controller.imageService.configurationError ?? "缺少图像服务配置。", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    Text("在运行目录的 image-service/gateway.json 中配置模型、可执行程序和监听地址。保存设置或重新打开应用后读取配置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("生成图像").font(.headline)
                    TextField("描述你想生成的图像", text: $prompt, axis: .vertical)
                        .lineLimit(3...7).textFieldStyle(.roundedBorder)
                        .disabled(controller.imageStatus.state != .ready || isGenerating)
                    HStack(spacing: 16) {
                        Picker("尺寸", selection: $size) { ForEach(sizes, id: \.self) { Text($0).tag($0) } }.frame(width: 170)
                        Stepper("Steps：\(steps)", value: $steps, in: 1...100).frame(width: 180)
                        TextField("Seed（可选）", text: $seedText).frame(width: 150)
                            .textFieldStyle(.roundedBorder)
                    }.disabled(controller.imageStatus.state != .ready || isGenerating)
                    HStack(spacing: 12) {
                        Button(action: generate) {
                            Label(isGenerating ? "正在生成…" : "生成图像", systemImage: isGenerating ? "hourglass" : "sparkles")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(controller.imageStatus.state != .ready || isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let pngData {
                            Button(action: savePNG) { Label("保存 PNG…", systemImage: "square.and.arrow.down") }
                                .buttonStyle(.glass)
                        }
                        if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if let generatedImage {
                    Image(nsImage: generatedImage)
                        .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 620)
                        .clipShape(.rect(cornerRadius: 12))
                        .accessibilityLabel("生成的图像")
                } else {
                    ContentUnavailableView("图像会显示在这里", systemImage: "photo", description: Text("启动图像服务后，输入提示词并生成 PNG。"))
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
                if !controller.imageLogTail.isEmpty {
                    DisclosureGroup("最近服务日志") {
                        Text(controller.imageLogTail).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption)
                }
                Text("请求通过本机 Gateway 的 POST /v1/images/generations 同步生成 base64 PNG。图像服务独立启停，不会自动加载；当前接口不支持图像编辑或 Responses image_generation 工具。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func generate() {
        guard let url = URL(string: controller.activeBaseURL + "/images/generations"),
              let configuration = controller.imageService.configuration else { return }
        let seedInput = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard seedInput.isEmpty || (UInt32(seedInput) != nil) else {
            errorMessage = "Seed 必须是 0 到 4294967295 的整数。"
            return
        }
        isGenerating = true
        errorMessage = nil
        notice = nil
        generatedImage = nil
        pngData = nil
        var payload: [String: Any] = [
            "model": configuration.model,
            "prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "size": size,
            "steps": steps,
            "response_format": "b64_json"
        ]
        if let seed = Int(seedInput) { payload["seed"] = seed }
        generationTask = Task {
            defer { isGenerating = false }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = configuration.requestTimeout
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw RequestError.message("Gateway 没有返回有效的 HTTP 响应。") }
                guard (200..<300).contains(http.statusCode) else {
                    let detail = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let errorObject = detail?["error"] as? [String: Any]
                    let message = errorObject?["message"] as? String ?? detail?["error"] as? String ?? "请求失败"
                    throw RequestError.message("HTTP \(http.statusCode)：\(message)")
                }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = object["data"] as? [[String: Any]],
                      let encoded = items.first?["b64_json"] as? String,
                      let decoded = Data(base64Encoded: encoded),
                      let image = NSImage(data: decoded) else {
                    throw RequestError.message("响应中没有有效的 base64 PNG。")
                }
                pngData = decoded
                generatedImage = image
                notice = "已生成 PNG（\(ByteCountFormatter.string(fromByteCount: Int64(decoded.count), countStyle: .file))）。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var stateTitle: String {
        switch controller.imageStatus.state {
        case .stopped: "已停止"
        case .starting: "正在启动"
        case .ready: "就绪"
        case .stopping: "正在停止"
        case .failed: "启动失败"
        }
    }

    private func savePNG() {
        guard let pngData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "mlx-generated-image.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try pngData.write(to: url, options: .atomic)
                notice = "已保存到 \(url.path)"
            } catch { errorMessage = "保存失败：\(error.localizedDescription)" }
        }
    }

    private enum RequestError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
    }
}
