import SwiftUI
import UniformTypeIdentifiers

struct AudioTranscriptionView: View {
    @ObservedObject var controller: GatewayController
    @ObservedObject var service: AudioServiceController
    @State private var showingConfiguration = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(.tint)
                        .frame(width: 66, height: 66).glassEffect(.regular, in: .rect(cornerRadius: 20))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(service.configuration?.title ?? "语音转写").font(.title2.weight(.semibold))
                        Text("音频文件 → 文字 · OpenAI Transcriptions").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("服务设置", systemImage: "slider.horizontal.3") { service.restoreDraft(); showingConfiguration = true }
                        .disabled(!service.canConfigure)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(service.title, systemImage: service.state == .ready ? "checkmark.circle.fill" : "waveform")
                        .font(.headline).foregroundStyle(service.state == .ready ? Color.green : .secondary)
                    Text(service.message).foregroundStyle(.secondary)
                    if service.busy { ProgressView().controlSize(.small) }
                    if let error = service.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("客户端连接").font(.headline).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 14) {
                        connectionRow("Base URL", value: controller.activeBaseURL)
                        connectionRow("模型 ID", value: service.configuration?.model ?? "未配置")
                        connectionRow("转写端点", value: controller.activeBaseURL + "/audio/transcriptions")
                        Text("兼容 /audio/transcriptions · multipart 上传 file 和 model；可选 language、response_format。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("输出格式：JSON、纯文本、verbose_json、WebVTT 字幕。字幕时间轴来自 Whisper 分段。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("转写测试").font(.headline).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Button(service.transcribing ? "正在转写…" : "选择音频并转写…", systemImage: "waveform.badge.magnifyingglass", action: chooseAudio)
                                .buttonStyle(.glassProminent)
                                .disabled(service.state != .ready || service.transcribing || !controller.gatewayReady)
                            if service.transcribing { ProgressView().controlSize(.small) }
                            Spacer()
                            if !service.transcript.isEmpty {
                                Button("复制文字", systemImage: "doc.on.doc") { controller.copy(service.transcript) }
                            }
                        }
                        Text(service.testFilename.isEmpty ? "通过 Gateway 上传音频，结果仅保留在本次窗口内存中。上传总大小不超过 16 MiB。" : service.testFilename)
                            .font(.caption).foregroundStyle(.secondary)
                        if service.transcript.isEmpty {
                            Text("转写结果将在此显示。支持格式由下游服务决定。")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                        } else {
                            Text(service.transcript).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                        }
                    }.padding(10)
                }
                if let config = service.configuration {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("下游服务").font(.headline).accessibilityAddTraits(.isHeader)
                        VStack(alignment: .leading, spacing: 10) {
                            connectionRow("服务地址", value: config.baseURL.absoluteString)
                            Text(service.ownsProcess ? "本进程由 Gateway 启动；停止服务或退出应用时会结束进程。" : "连接已有服务。卸载只释放转写模型，保留服务进程。")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("检查连接", systemImage: "arrow.clockwise") { service.refresh(force: true) }.disabled(service.busy)
                                if FileManager.default.fileExists(atPath: service.logURL.path) {
                                    Button("查看服务日志", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([service.logURL]) }
                                }
                            }
                        }.padding(10)
                    }
                }
                Text("先手动加载模型，再发送转写请求。此模型使用独立的音频端点。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingConfiguration) { configurationSheet }
    }

    private func connectionRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { controller.copy(value) } label: {
                Image(systemName: controller.copiedValue == value ? "checkmark" : "doc.on.doc")
            }.buttonStyle(.borderless).accessibilityLabel("复制\(title)")
        }
    }

    private var configurationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音频转写服务设置").font(.title2.weight(.semibold))
            Form {
                TextField("模型名称", text: $service.draftDisplayName)
                TextField("模型 ID", text: $service.draftModel)
                TextField("下游 Base URL", text: $service.draftBaseURL)
                VStack(alignment: .leading, spacing: 8) {
                    Text("本地启动脚本（可选）")
                    HStack {
                        TextField("可执行脚本的绝对路径", text: $service.draftLaunchScript)
                        Button("选择…", action: chooseScript)
                    }
                    Text("没有启动脚本时，Gateway 连接已运行的服务。手动加载/卸载要求下游支持 POST/DELETE /v1/models?model_name=…；仅支持转写的服务需在服务端预先加载模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error = service.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { showingConfiguration = false }.keyboardShortcut(.cancelAction)
                Button("保存") { if service.save() { showingConfiguration = false } }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!service.canConfigure)
            }
        }.padding(24).frame(width: 620, height: 470)
    }

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.prompt = "转写"; panel.message = "音频将发送至本机 Gateway，结果仅保留在当前窗口。"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in service.transcribe(file: url, gatewayBaseURL: controller.activeBaseURL) }
        }
    }

    private func chooseScript() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in service.draftLaunchScript = url.path }
        }
    }
}
