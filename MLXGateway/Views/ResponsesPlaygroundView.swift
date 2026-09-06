import SwiftUI
import UniformTypeIdentifiers

/// The parent supplies its applied gateway URL. Changes never replace the user's edited JSON.
struct ResponsesPlaygroundView: View {
    let baseURL: String
    let modelID: String?
    @StateObject private var session: ResponsesPlaygroundSession
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = ResponsesPlaygroundDocument(data: Data())
    @State private var exportName = "responses-projects.json"
    @State private var exportType = UTType.json
    @State private var resultTab = 0
    @State private var selectedEvent: Int?
    @State private var eventPage = 0
    @State private var confirmingDelete = false
    @State private var confirmingProjectDelete = false
    @State private var toolCallID = ""
    @State private var toolResult = ""

    init(baseURL: String, modelID: String?) {
        self.baseURL = baseURL
        self.modelID = modelID
        _session = StateObject(wrappedValue: ResponsesPlaygroundSession(baseURL: baseURL, modelID: modelID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            connection
            Divider()
            HSplitView {
                composer.frame(minWidth: 340, idealWidth: 440)
                results.frame(minWidth: 340, idealWidth: 440)
            }
            Divider()
            sessionOperations
            if let notice = session.notice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("关闭提示") { session.notice = nil }.buttonStyle(.borderless)
                }
            }
        }
        .padding(16)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false, onCompletion: importFile)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let error) = result { session.notice = "导出失败：\(error.localizedDescription)" }
        }
        .confirmationDialog("删除服务端响应 \(session.responseID)？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除服务端响应", role: .destructive) { session.start(.delete) }
        } message: { Text("这将调用当前端点的 DELETE 接口，删除已存储的响应。") }
        .confirmationDialog("删除自定义项目？", isPresented: $confirmingProjectDelete, titleVisibility: .visible) {
            Button("删除项目", role: .destructive) { session.deleteSelectedProject(modelID: modelID) }
        }
        .onChange(of: session.endpoint) { _, _ in session.apiKey = "" }
        .onChange(of: session.startedAt) { _, _ in selectedEvent = nil; eventPage = 0 }
        .onDisappear { session.stopReceiving() }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("API 基址，例如 http://127.0.0.1:44110/v1", text: $session.endpoint)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("API 基址")
                Button("使用当前网关") { session.endpoint = baseURL }
                    .disabled(baseURL.isEmpty || session.running)
                SecureField("API key（可选，仅内存）", text: $session.apiKey)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                Button("清除密钥") { session.apiKey = "" }.disabled(session.apiKey.isEmpty)
            }
            .disabled(session.running)
            HStack {
                Text("不会自动启动或切换模型；更换端点会清除密钥。")
                Spacer()
                Text("超时（秒）")
                TextField("180", text: $session.timeout).frame(width: 55).textFieldStyle(.roundedBorder)
                    .disabled(session.running).accessibilityLabel("请求总超时秒数")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("项目", selection: Binding(get: { session.selection }, set: { session.select($0, modelID: modelID) })) {
                    Section("预置") {
                        ForEach(ResponsesTestPreset.all) { preset in Text(preset.name).tag(preset.id) }
                    }
                    Section("自定义") {
                        ForEach(session.projects) { project in Text(project.name).tag(project.id.uuidString) }
                    }
                }
                Menu {
                    Button("保存为新项目") { session.saveProject(asNew: true) }
                    Button("更新当前项目") { session.saveProject(asNew: false) }.disabled(session.selectedProject == nil)
                    Button("删除当前项目", role: .destructive) { confirmingProjectDelete = true }.disabled(session.selectedProject == nil)
                    Divider()
                    Button("导入项目 JSON…") { importing = true }
                    Button("导出已保存项目…") { exportProjects() }.disabled(session.projects.isEmpty)
                } label: { Label("管理", systemImage: "folder") }
            }
            TextField("项目名称", text: $session.projectName).textFieldStyle(.roundedBorder)
            Text(session.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("请求 JSON").font(.headline)
                Spacer()
                Button("使用所选模型") { session.applyModel(modelID) }.disabled(modelID == nil)
                    .help(modelID ?? "未选择模型")
                Button("格式化") { session.formatJSON() }
            }
            TextEditor(text: $session.body)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .accessibilityLabel("完整 Responses 请求 JSON")
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Text("保留未知扩展字段；切换项目会保留本窗口草稿。保存上限：100 项 / 4 MiB。")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button { session.start(.create) } label: { Label("发送请求", systemImage: "paperplane") }
                    .buttonStyle(.borderedProminent).disabled(session.running)
                    .keyboardShortcut(.return, modifiers: [.command])
                if session.running {
                    Button(session.stopping ? "正在停止…" : "停止接收") { session.stopReceiving() }
                        .disabled(session.stopping)
                        .help("只取消本次本地网络任务；不代表服务器已停止生成")
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.trailing, 10)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.status).font(.headline).textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let duration = session.running ? context.date.timeIntervalSince(session.startedAt ?? context.date) : session.elapsed
                        Text("耗时 \(duration, specifier: "%.2f") s · 首个文本增量 \(session.firstToken.map { String(format: "%.3f s", $0) } ?? "—") · \(session.raw.count) bytes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("导出原始响应…") {
                    exportDocument = ResponsesPlaygroundDocument(data: session.raw)
                    exportName = session.contentType.lowercased().hasPrefix("text/event-stream") ? "response.sse.txt" : "response.json"
                    exportType = .plainText
                    exporting = true
                }.disabled(session.raw.isEmpty || session.running)
            }
            if let error = session.errorMessage {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 90)
            }
            Picker("结果视图", selection: $resultTab) {
                Text("输出").tag(0)
                Text("事件（\(session.events.count)）").tag(1)
                Text("原始正文").tag(2)
                Text("指标").tag(3)
            }.pickerStyle(.segmented)
            Group {
                switch resultTab {
                case 1: eventBrowser
                case 2: textPane(String(decoding: session.raw.prefix(ResponsesPlaygroundSession.displayCharacters), as: UTF8.self))
                case 3: metrics
                default: textPane(session.output.isEmpty ? "文本输出尚未到达。工具调用、非文本输出和错误请查看事件或原始正文。" : session.output)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text("正文预览 256 KiB，输出预览 256 Ki 字符，单事件预览 64 Ki 字符；原始响应可导出。接收上限 8 MiB / 10,000 事件，单事件 1 MiB，超限会断开并标明未完成。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if session.outputTruncated { Text("输出预览已截断。请导出原始响应查看其余内容。").font(.caption).foregroundStyle(.orange) }
        }
        .padding(.leading, 10)
    }

    private var eventBrowser: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("上一页") { eventPage -= 1 }.disabled(eventPage == 0)
                Text("第 \(eventPage + 1) 页 · 每页 100 条").font(.caption)
                Button("下一页") { eventPage += 1 }.disabled((eventPage + 1) * 100 >= session.events.count)
                Spacer()
            }
            List(selection: $selectedEvent) {
                ForEach(Array(session.events.dropFirst(eventPage * 100).prefix(100))) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(event.id) \(event.name)").lineLimit(1)
                        Text(event.data.prefix(120)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(event.id)
                }
            }.frame(minHeight: 90, idealHeight: 140, maxHeight: 180)
            if let event = session.events.first(where: { $0.id == selectedEvent }) {
                Text("\(event.elapsed, specifier: "%.3f") s · SSE id: \(event.serverID ?? "—")").font(.caption)
                textPane(String(event.data.prefix(65_536)))
            } else { Text("选择事件查看完整 data 预览。所有未知事件也会保留。").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var metrics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("HTTP: \(session.httpStatus.map(String.init) ?? "—")\nContent-Type: \(session.contentType)\nx-request-id: \(session.requestID ?? "—")\n服务端 status: \(session.serverStatus.isEmpty ? "—" : session.serverStatus)")
                Text("usage（服务端原值）").font(.headline)
                Text(session.usage.isEmpty ? "服务端尚未提供 usage。" : session.usage).font(.system(.body, design: .monospaced))
                Text("首 token 指首个非空文本 / 拒绝 / 音频转写增量到达时间；非流式与纯工具调用不估算此指标。HTTP 成功不等于所有功能已支持。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    private var sessionOperations: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("响应 ID（响应返回时自动填入）", text: $session.responseID).textFieldStyle(.roundedBorder)
                Button("写入 previous_response_id") { session.usePreviousResponse() }
                    .disabled(session.responseID.isEmpty)
                Button("GET") { session.start(.retrieve) }.help("读取响应")
                Button("服务端 cancel") { session.start(.cancel) }.help("提交取消请求；只有返回 cancelled 才确认取消成功")
                Button("DELETE", role: .destructive) { confirmingDelete = true }.help("删除服务端存储响应")
            }
            HStack {
                TextField("input_items 分页 after（可选）", text: $session.afterID).textFieldStyle(.roundedBorder)
                Button("GET input_items") { session.start(.inputItems) }
                Text("每页 100 项，按 asc 返回；从原始正文复制 last_id 到 after 查询下一页。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            DisclosureGroup("手动填写工具结果") {
                HStack(alignment: .top) {
                    TextField("function call_id", text: $toolCallID).textFieldStyle(.roundedBorder).frame(width: 190)
                    TextEditor(text: $toolResult).font(.system(.caption, design: .monospaced)).frame(height: 55)
                        .accessibilityLabel("用户确认的工具结果")
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                    Button("写入草稿") { writeToolResult() }
                        .disabled(toolCallID.isEmpty || toolResult.isEmpty || session.responseID.isEmpty)
                }
                Text("将替换 input、写入 previous_response_id 并移除强制 tool_choice；检查草稿后手动发送。不会执行任意函数。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .disabled(session.running)
    }

    private func textPane(_ text: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(6)
        }
    }

    private func writeToolResult() {
        do {
            var object = try ResponsesTestJSON.object(session.body)
            object["previous_response_id"] = session.responseID
            object["input"] = [["type": "function_call_output", "call_id": toolCallID, "output": toolResult]]
            object.removeValue(forKey: "tool_choice")
            session.body = ResponsesTestJSON.pretty(object)
            session.notice = "工具结果已写入草稿，请检查后发送。"
        } catch { session.notice = error.localizedDescription }
    }

    private func exportProjects() {
        do {
            exportDocument = ResponsesPlaygroundDocument(data: try session.exportProjects())
            exportName = "responses-projects.json"; exportType = .json; exporting = true
        } catch { session.notice = error.localizedDescription }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: ResponsesPlaygroundProjectStore.maximumBytes + 1) ?? Data()
            session.importProjects(data)
        } catch { session.notice = "导入失败：\(error.localizedDescription)" }
    }
}

private struct ResponsesPlaygroundDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText, .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
