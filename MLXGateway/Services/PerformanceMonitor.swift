import Foundation
import AppKit
import UniformTypeIdentifiers

struct ResourceSample: Identifiable, Sendable, Codable {
    let id: UUID
    let date: Date
    let modelID: String
    let pid: Int32
    let cpuPercent: Double?
    let residentBytes: UInt64
    let footprintBytes: UInt64
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
}

@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published var enabled = true {
        didSet {
            previous = nil
            if enabled { sampleResources() }
            else { resourceMessage = "资源采样已暂停；请求统计继续记录。" }
        }
    }
    @Published var interval: Double = 2 {
        didSet { scheduleSampling() }
    }
    @Published private(set) var samples: [ResourceSample] = []
    @Published private(set) var requests: [RequestMetric] = []
    @Published private(set) var inFlight = 0
    @Published private(set) var resourceMessage = "启动模型后开始采样。"
    @Published private(set) var exportError: String?
    private var previous: ProcessResourceReading?
    private var samplingTimer: Timer?
    private var sampling = false
    private var observedPID: Int32?
    private var observedModelID: String?

    init() { scheduleSampling() }

    private func scheduleSampling() {
        samplingTimer?.invalidate()
        samplingTimer = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleResources() }
        }
    }

    func stop() {
        samplingTimer?.invalidate()
        samplingTimer = nil
        enabled = false
    }

    func refresh(pid: Int32?, modelID: String?) {
        let snapshot = RequestMetricsStore.shared.snapshot()
        if requests != snapshot.records { requests = snapshot.records }
        if inFlight != snapshot.inFlight { inFlight = snapshot.inFlight }
        if observedPID != pid || observedModelID != modelID {
            observedPID = pid
            observedModelID = modelID
            previous = nil
            sampleResources()
        }
        if !enabled { resourceMessage = "资源采样已暂停；请求统计继续记录。" }
        else if pid == nil { resourceMessage = "模型未运行，暂无资源数据。" }
    }

    private func sampleResources() {
        guard enabled else { previous = nil; resourceMessage = "资源采样已暂停；请求统计继续记录。"; return }
        guard let pid = observedPID, let modelID = observedModelID else { previous = nil; resourceMessage = "模型未运行，暂无资源数据。"; return }
        guard !sampling else { return }
        sampling = true
        Task {
            let reading = await Task.detached(priority: .utility) { ProcessResourceSampler.read(pid: pid) }.value
            defer { sampling = false }
            guard enabled, observedPID == pid, observedModelID == modelID else { return }
            guard let reading else {
                previous = nil
                resourceMessage = "无法读取进程资源（进程已退出或系统未授予访问）。"
                return
            }
            let cpu = ProcessResourceSampler.cpuPercent(current: reading, previous: previous)
            previous = reading
            samples.append(ResourceSample(id: UUID(), date: Date(), modelID: modelID, pid: pid,
                cpuPercent: cpu, residentBytes: reading.residentBytes, footprintBytes: reading.footprintBytes,
                diskReadBytes: reading.readBytes, diskWrittenBytes: reading.writtenBytes))
            if samples.count > 900 { samples.removeFirst(samples.count - 900) }
            resourceMessage = "每 \(Int(interval)) 秒采样 · PID \(pid) · 仅统计当前 MLX 主进程"
        }
    }

    func clear() {
        samples.removeAll()
        requests.removeAll()
        RequestMetricsStore.shared.clearCompleted()
        previous = nil
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "mlx-performance.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                struct Report: Encodable { let exportedAt: Date; let resources: [ResourceSample]; let requests: [RequestMetric] }
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(Report(exportedAt: Date(), resources: self.samples, requests: self.requests)).write(to: url, options: .atomic)
                    self.exportError = nil
                } catch { self.exportError = error.localizedDescription }
            }
        }
    }
}

enum BenchmarkPreset: String, CaseIterable, Identifiable {
    case short = "短响应", generation = "持续生成", context = "长输入", custom = "自定义"
    var id: String { rawValue }
    var prompt: String {
        switch self {
        case .short: return "只回复：MLX 已就绪。"
        case .generation: return "请用中文分十段解释大型语言模型的推理过程，每段至少五十字。"
        case .context:
            return (1...80).map { "记录\($0)：本地推理需要观察延迟、吞吐量与内存占用。" }.joined(separator: "\n") + "\n请总结上面的记录。"
        case .custom: return ""
        }
    }
}

struct BenchmarkResult: Identifiable {
    let id = UUID()
    let iteration: Int
    let duration: Double
    let outputTokens: Int?
    let error: String?
}

@MainActor
final class ModelBenchmarkRunner: ObservableObject {
    @Published var preset: BenchmarkPreset = .short
    @Published var prompt = BenchmarkPreset.short.prompt
    @Published var iterations = 3
    @Published var maxOutputTokens = 128
    @Published var warmup = true
    @Published private(set) var running = false
    @Published private(set) var results: [BenchmarkResult] = []
    @Published private(set) var status = "使用当前运行模型，串行发送预置或自定义请求。"
    private var task: Task<Void, Never>?

    func cancel() { task?.cancel(); status = "正在取消当前请求…" }

    func start(baseURL: String, modelID: String) {
        guard !running, let base = URL(string: baseURL), ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let prompt = prompt
        let count = max(1, min(20, iterations))
        let limit = max(1, min(4096, maxOutputTokens))
        let warmup = warmup
        results = []
        running = true
        task = Task {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel(); running = false; task = nil }
            for iteration in (warmup ? 0 : 1)...count {
                if Task.isCancelled { status = "已取消；已完成轮次保留。"; return }
                status = iteration == 0 ? "预热中（不计入本组结果）…" : "正在运行第 \(iteration)/\(count) 轮…"
                var request = URLRequest(url: base.appendingPathComponent("responses"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 180
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": modelID, "input": prompt,
                    "max_output_tokens": limit, "stream": false, "store": false])
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let (data, response) = try await session.data(for: request)
                    try Task.checkCancellation()
                    let duration = ProcessInfo.processInfo.systemUptime - started
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let apiError = body?["error"] as? [String: Any]
                    let statusValue = body?["status"] as? String
                    let validResponse = body?["object"] as? String == "response"
                        && (statusValue == "completed" || statusValue == "incomplete")
                    let success = (200..<300).contains(code) && apiError == nil && validResponse
                    let error = success ? nil : "HTTP \(code) · \((apiError?["code"] as? String) ?? (validResponse ? "请求失败" : "无有效 Responses 结果"))"
                    if iteration > 0 {
                        let usage = body?["usage"] as? [String: Any]
                        results.append(BenchmarkResult(iteration: iteration, duration: duration,
                            outputTokens: usage?["output_tokens"] as? Int, error: error))
                    }
                    if let error { status = "第 \(iteration == 0 ? "预热" : String(iteration)) 轮失败：\(error)；已停止本组测试。"; return }
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        status = "已取消；网关将取消断开的请求，已完成轮次保留。"
                        return
                    }
                    if iteration > 0 {
                        results.append(BenchmarkResult(iteration: iteration,
                            duration: ProcessInfo.processInfo.systemUptime - started, outputTokens: nil, error: error.localizedDescription))
                    }
                    status = "测试停止：\(error.localizedDescription)"
                    return
                }
            }
            status = "已完成 \(count) 轮\(warmup ? "（不含 1 轮预热）" : "")。"
        }
    }
}
