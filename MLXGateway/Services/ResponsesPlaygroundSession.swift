import Foundation
import Combine

@MainActor
final class ResponsesPlaygroundSession: ObservableObject {
    @Published var endpoint: String
    @Published var apiKey = ""
    @Published var timeout = "180"
    @Published var body: String
    @Published var projectName = "快速文本"
    @Published private(set) var selection = "text"
    @Published private(set) var projects: [ResponsesTestProject] = []
    @Published var notice: String?
    @Published var responseID = ""
    @Published var afterID = ""
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published private(set) var status = "尚未发送"
    @Published private(set) var errorMessage: String?
    @Published private(set) var output = ""
    @Published private(set) var events: [ResponsesClientEvent] = []
    @Published private(set) var raw = Data()
    @Published private(set) var httpStatus: Int?
    @Published private(set) var contentType = ""
    @Published private(set) var requestID: String?
    @Published private(set) var usage = ""
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var firstToken: Double?
    @Published private(set) var startedAt: Date?
    @Published private(set) var serverStatus = ""
    @Published private(set) var outputTruncated = false

    static let displayCharacters = 256 * 1024
    private var drafts: [String: (name: String, body: String)] = [:]
    private let store: ResponsesPlaygroundProjectStore
    private let client: ResponsesClient
    private var task: Task<Void, Never>?
    private var runID: UUID?
    private var terminalEvent = false
    private var storageReadable = true
    private var operation: ResponsesClientOperation = .create
    private var outputCharacterCount = 0

    init(baseURL: String, modelID: String?, store: ResponsesPlaygroundProjectStore = .init(), client: ResponsesClient = .init()) {
        endpoint = baseURL
        body = ResponsesTestPreset.all[0].body(modelID: modelID)
        self.store = store
        self.client = client
        do { projects = try store.load() }
        catch { storageReadable = false; notice = "已保存的项目无法读取，为保留原数据，本次禁用保存：\(error.localizedDescription)" }
    }

    var hint: String {
        ResponsesTestPreset.all.first(where: { $0.id == selection })?.hint ?? "自定义完整 JSON；可使用兼容端点的扩展字段。项目 body 会以明文保存在本机，请勿放入密钥。"
    }

    var selectedProject: ResponsesTestProject? { projects.first { $0.id.uuidString == selection } }

    func select(_ id: String, modelID: String?) {
        guard id != selection else { return }
        drafts[selection] = (projectName, body)
        if let draft = drafts[id] { projectName = draft.name; body = draft.body }
        else if let preset = ResponsesTestPreset.all.first(where: { $0.id == id }) {
            projectName = preset.name; body = preset.body(modelID: modelID)
        } else if let project = projects.first(where: { $0.id.uuidString == id }) {
            projectName = project.name; body = project.body
        } else { return }
        selection = id
    }

    func applyModel(_ modelID: String?) {
        guard let modelID, !modelID.isEmpty else { notice = "没有所选模型，可在 JSON 中手动填写 model。"; return }
        editJSON { $0["model"] = modelID }
    }

    func formatJSON() { editJSON { _ in } }

    func usePreviousResponse() {
        guard !responseID.isEmpty else { notice = "先获得或填写响应 ID。"; return }
        editJSON { $0["previous_response_id"] = responseID }
    }

    private func editJSON(_ edit: (inout [String: Any]) -> Void) {
        do { var object = try ResponsesTestJSON.object(body); edit(&object); body = ResponsesTestJSON.pretty(object); notice = nil }
        catch { notice = error.localizedDescription }
    }

    func saveProject(asNew: Bool) {
        do {
            try checkStorage()
            var updated = projects
            let project = ResponsesTestProject(id: asNew ? UUID() : (selectedProject?.id ?? UUID()), name: projectName, body: body)
            try checkNoKey(in: project.name + project.body)
            if let index = updated.firstIndex(where: { $0.id == project.id }) { updated[index] = project }
            else { updated.append(project) }
            try store.save(updated)
            drafts[selection] = (projectName, body)
            projects = updated
            selection = project.id.uuidString
            notice = "已保存项目；API key 未写入项目存储。"
        } catch { notice = error.localizedDescription }
    }

    func deleteSelectedProject(modelID: String?) {
        guard let project = selectedProject else { return }
        do {
            try checkStorage()
            let updated = projects.filter { $0.id != project.id }
            try store.save(updated)
            select("text", modelID: modelID)
            drafts.removeValue(forKey: project.id.uuidString)
            projects = updated
            notice = "已删除自定义项目。"
        } catch { notice = error.localizedDescription }
    }

    func importProjects(_ data: Data) {
        do {
            try checkStorage()
            let imported = try ResponsesPlaygroundProjectStore.decode(data).map { project in
                ResponsesTestProject(name: project.name, body: project.body)
            }
            for project in imported { try checkNoKey(in: project.name + project.body) }
            let updated = projects + imported
            try store.save(updated)
            projects = updated
            notice = "已导入 \(imported.count) 个项目（新增副本）。"
        } catch { notice = "导入失败：\(error.localizedDescription)" }
    }

    func exportProjects() throws -> Data {
        for project in projects { try checkNoKey(in: project.name + project.body) }
        return try ResponsesPlaygroundProjectStore.encode(projects)
    }

    private func checkStorage() throws {
        guard storageReadable else { throw ResponsesClientError.message("原项目存储不可读；请先备份并修复本机项目数据。") }
    }

    private func checkNoKey(in text: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, text.contains(key) { throw ResponsesClientError.message("名称或 body 包含当前 API key，请移除后保存或导出。") }
    }

    func start(_ operation: ResponsesClientOperation) {
        guard !running else { return }
        let request = ResponsesClientRequest(baseURL: endpoint, apiKey: apiKey, operation: operation, body: body,
                                             responseID: responseID, after: afterID, timeout: Double(timeout) ?? 0)
        do { _ = try request.urlRequest() }
        catch { notice = error.localizedDescription; return }
        notice = nil
        self.operation = operation
        raw = Data(); events = []; output = ""; errorMessage = nil; usage = ""; serverStatus = ""
        firstToken = nil; httpStatus = nil; contentType = ""; requestID = nil; elapsed = 0
        outputTruncated = false; outputCharacterCount = 0; terminalEvent = false; stopping = false
        running = true; startedAt = Date(); status = "连接中…"
        let id = UUID()
        runID = id
        let started = ProcessInfo.processInfo.systemUptime
        let client = client
        task = Task { [weak self] in
            do {
                try await client.perform(request) { [weak self] update in
                    await self?.receive(update, runID: id)
                }
                guard let self, self.runID == id else { return }
                self.elapsed = ProcessInfo.processInfo.systemUptime - started
                self.finish()
            } catch {
                guard let self, self.runID == id else { return }
                self.elapsed = ProcessInfo.processInfo.systemUptime - started
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    self.status = "本地接收已停止"
                    self.errorMessage = "已取消本次网络任务；这不代表服务端生成已取消。可用响应 ID 查询状态或请求服务端取消。"
                } else {
                    self.status = "请求未完成"
                    self.errorMessage = error.localizedDescription
                }
            }
            guard let self, self.runID == id else { return }
            self.running = false; self.stopping = false; self.task = nil
        }
    }

    func stopReceiving() {
        guard running else { return }
        stopping = true
        status = "正在停止本地接收…"
        task?.cancel()
    }

    private func receive(_ update: ResponsesClientUpdate, runID: UUID) {
        guard self.runID == runID else { return }
        switch update {
        case .headers(let code, let type, let id):
            httpStatus = code; contentType = type; requestID = id
            if !stopping { status = "HTTP \(code) · 接收中…" }
        case .batch(let data, let batch):
            raw.append(data)
            events.append(contentsOf: batch)
            for event in batch { process(event) }
        }
    }

    private func process(_ event: ResponsesClientEvent) {
        guard event.data != "[DONE]" else { return }
        guard let object = try? ResponsesTestJSON.object(event.data) else { return }
        let type = object["type"] as? String ?? event.name
        if ["response.output_text.delta", "response.refusal.delta", "response.output_audio_transcript.delta"].contains(type),
           let delta = object["delta"] as? String, !delta.isEmpty {
            if firstToken == nil { firstToken = event.elapsed }
            appendOutput(delta)
        }
        if let response = object["response"] as? [String: Any] { readResponse(response, extractOutput: output.isEmpty) }
        if ["response.completed", "response.failed", "response.incomplete", "response.cancelled"].contains(type) {
            terminalEvent = true
            if serverStatus.isEmpty { serverStatus = String(type.dropFirst("response.".count)) }
        }
        if type == "error" || type == "response.error" {
            errorMessage = ResponsesTestJSON.pretty(object)
        }
    }

    private func readResponse(_ response: [String: Any], extractOutput: Bool) {
        if let id = response["id"] as? String { responseID = id }
        if let value = response["status"] as? String { serverStatus = value }
        if let value = response["usage"], !(value is NSNull) { usage = ResponsesTestJSON.pretty(value) }
        if let error = response["error"], !(error is NSNull) { errorMessage = ResponsesTestJSON.pretty(error) }
        if extractOutput, let items = response["output"] as? [[String: Any]] {
            for item in items {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    if let text = part["text"] as? String { appendOutput(text) }
                    else if let refusal = part["refusal"] as? String { appendOutput(refusal) }
                }
            }
        }
    }

    private func appendOutput(_ text: String) {
        let room = Self.displayCharacters - outputCharacterCount
        guard room > 0 else { outputTruncated = true; return }
        let portion = text.prefix(room)
        output += portion
        outputCharacterCount += portion.count
        if text.count > room { outputTruncated = true }
    }

    private func finish() {
        guard let httpStatus else { status = "没有 HTTP 响应"; return }
        guard (200..<300).contains(httpStatus) else {
            status = "HTTP \(httpStatus) · 端点返回错误"
            errorMessage = String(decoding: raw.prefix(16_384), as: UTF8.self)
            if raw.count > 16_384 { errorMessage? += "\n…错误正文摘要已截断，完整接收数据可导出。" }
            return
        }
        let streaming = contentType.lowercased().hasPrefix("text/event-stream")
        if !streaming, raw.isEmpty, operation != .delete {
            errorMessage = "HTTP 成功但响应正文为空，无法确认 Responses 结果。"
        }
        if !streaming, !raw.isEmpty {
            do {
                let response = try ResponsesTestJSON.object(String(decoding: raw, as: UTF8.self))
                if operation != .inputItems { readResponse(response, extractOutput: true) }
            } catch { errorMessage = "HTTP 成功但正文不是 JSON 对象：\(error.localizedDescription)" }
        }
        if streaming && !terminalEvent {
            status = "流已断开 · 未收到 Responses 终态事件"
        } else if errorMessage != nil || serverStatus == "failed" {
            status = "HTTP \(httpStatus) · 响应包含错误"
        } else if operation == .cancel {
            status = serverStatus == "cancelled" ? "服务端确认 cancelled" : "取消接口已返回 · 未确认 cancelled（\(serverStatus.isEmpty ? "无状态" : serverStatus)）"
        } else {
            status = "HTTP \(httpStatus) · \(serverStatus.isEmpty ? "接收完成" : serverStatus)"
        }
    }
}
