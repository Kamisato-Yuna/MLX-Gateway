import SwiftUI
import Charts

struct PerformancePanelView: View {
    @ObservedObject var monitor: PerformanceMonitor
    @ObservedObject var benchmark: ModelBenchmarkRunner
    let baseURL: String
    let modelID: String?
    let backendReady: Bool
    @State private var selectedModel = ""

    private var visibleRequests: [RequestMetric] {
        selectedModel.isEmpty ? monitor.requests : monitor.requests.filter { $0.modelID == selectedModel }
    }
    private var visibleSamples: [ResourceSample] {
        selectedModel.isEmpty ? monitor.samples : monitor.samples.filter { $0.modelID == selectedModel }
    }
    private var modelIDs: [String] {
        Set(monitor.requests.map(\.modelID) + monitor.samples.map(\.modelID) + [modelID].compactMap { $0 }).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Label("性能分析", systemImage: "chart.xyaxis.line").font(.title2.bold())
                    Spacer()
                    Button("导出记录", systemImage: "square.and.arrow.up", action: monitor.export)
                        .disabled(monitor.requests.isEmpty && monitor.samples.isEmpty)
                    Button("清空统计", systemImage: "clear", action: monitor.clear)
                }
                HStack {
                    Toggle("资源监控", isOn: $monitor.enabled).toggleStyle(.switch)
                    Picker("采样间隔", selection: $monitor.interval) {
                        ForEach([1.0, 2, 5, 10, 30, 60], id: \.self) { value in Text("\(Int(value)) 秒").tag(value) }
                    }.frame(maxWidth: 200)
                    Spacer()
                    Picker("筛选模型", selection: $selectedModel) {
                        Text("全部模型").tag("")
                        ForEach(modelIDs, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 260)
                }
                Text(monitor.resourceMessage).font(.caption).foregroundStyle(.secondary)
                resourceCharts
                requestSummary
                benchmarkForm
                requestHistory
                if let error = monitor.exportError { Text(error).foregroundStyle(.red) }
            }.padding(24)
        }
    }

    private var resourceCharts: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let latest = visibleSamples.last {
                HStack(spacing: 28) {
                    metric("CPU", latest.cpuPercent.map { $0.formatted(.number.precision(.fractionLength(1))) + "%" } ?? "等待下一次采样")
                    metric("物理占用", ByteCountFormatter.string(fromByteCount: Int64(clamping: latest.footprintBytes), countStyle: .memory))
                    metric("驻留内存", ByteCountFormatter.string(fromByteCount: Int64(clamping: latest.residentBytes), countStyle: .memory))
                    metric("采样时间", latest.date.formatted(date: .omitted, time: .standard))
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading) {
                        Text("CPU · 单核 100%").font(.subheadline)
                        Chart(visibleSamples) { sample in
                            if let cpu = sample.cpuPercent {
                                LineMark(x: .value("时间", sample.date), y: .value("CPU %", cpu), series: .value("进程", String(sample.pid)))
                                    .foregroundStyle(by: .value("模型", sample.modelID))
                            }
                        }.chartLegend(.hidden).frame(height: 150)
                    }
                    VStack(alignment: .leading) {
                        Text("物理内存 · GiB").font(.subheadline)
                        Chart(visibleSamples) { sample in
                            LineMark(x: .value("时间", sample.date), y: .value("GiB", Double(sample.footprintBytes) / 1_073_741_824), series: .value("进程", String(sample.pid)))
                                .foregroundStyle(by: .value("模型", sample.modelID))
                        }.chartLegend(.hidden).frame(height: 150)
                    }
                }
            } else {
                ContentUnavailableView("暂无资源采样", systemImage: "waveform.path", description: Text("启动模型并打开资源监控后，可查看 CPU 与内存趋势。"))
            }
            Text("保留最近 900 次采样。内存为操作系统统计的 MLX 主进程物理占用与驻留量，不等同于 Metal 分配量；未提供 GPU 利用率。暂停或停止模型后，上方保留最后一次采样时间。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var requestSummary: some View {
        let summary = PerformanceSummary(records: visibleRequests)
        return VStack(alignment: .leading, spacing: 12) {
            Text("请求统计").font(.headline)
            HStack(spacing: 24) {
                metric("成功 / 失败", "\(summary.successCount) / \(summary.failureCount)")
                metric("进行中 · 全部", "\(monitor.inFlight)")
                metric("平均耗时", seconds(summary.average))
                metric("P50", seconds(summary.percentile(0.5)))
                metric("P95", seconds(summary.percentile(0.95)))
            }
            Text("保留本次启动最近 500 个请求；延迟分位数只计成功请求。TTFT 仅在真实流式内容到达时记录；输出 tok/s = 输出 token / 请求总耗时，包含提示词处理。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var benchmarkForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("预置性能测试").font(.headline)
            HStack {
                Picker("测试项目", selection: $benchmark.preset) {
                    ForEach(BenchmarkPreset.allCases) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 220)
                Stepper("\(benchmark.iterations) 轮", value: $benchmark.iterations, in: 1...20)
                Spacer()
                Toggle("先预热 1 轮", isOn: $benchmark.warmup)
            }.disabled(benchmark.running)
            TextEditor(text: $benchmark.prompt).font(.callout).frame(minHeight: 70, maxHeight: 110)
                .padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .disabled(benchmark.running).accessibilityLabel("性能测试提示词")
            HStack {
                Picker("输出上限", selection: $benchmark.maxOutputTokens) {
                    ForEach([32, 128, 256, 512, 1024, 2048, 4096], id: \.self) { Text("\($0) token").tag($0) }
                }.frame(maxWidth: 230).disabled(benchmark.running)
                Spacer()
                if benchmark.running {
                    ProgressView().controlSize(.small)
                    Button("取消测试", action: benchmark.cancel)
                } else {
                    Button("开始性能测试", systemImage: "play.fill") {
                        if let modelID { benchmark.start(baseURL: baseURL, modelID: modelID) }
                    }.buttonStyle(.glassProminent)
                        .disabled(!backendReady || modelID == nil || benchmark.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("当前模型：\(modelID ?? "未启动") · 串行、非流式、store=false。预热不计入本组结果，但仍出现在网关请求统计。模型不会自动启动或切换。")
                .font(.caption).foregroundStyle(.secondary)
            Text(benchmark.status).font(.callout).textSelection(.enabled)
            if !benchmark.results.isEmpty {
                let successful = benchmark.results.filter { $0.error == nil }
                if !successful.isEmpty {
                    Text("本组成功 \(successful.count) 轮 · 平均 \(seconds(successful.map(\.duration).reduce(0, +) / Double(successful.count)))")
                        .font(.subheadline.weight(.medium))
                }
                ForEach(benchmark.results) { result in
                    HStack {
                        Text("第 \(result.iteration) 轮").frame(width: 80, alignment: .leading)
                        Text(seconds(result.duration)).monospacedDigit()
                        Text(result.outputTokens.map { "\($0) 输出 token" } ?? "无 token 统计").foregroundStyle(.secondary)
                        if let error = result.error { Text(error).foregroundStyle(.red) }
                    }.font(.caption)
                }
            }
        }
        .onChange(of: benchmark.preset) { _, preset in
            if preset != .custom { benchmark.prompt = preset.prompt }
        }
    }

    private var requestHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("最近请求 · \(visibleRequests.count)").font(.headline)
            if visibleRequests.isEmpty {
                Text("使用快速测试面板或让客户端发送 Responses 请求后，这里会显示统计。")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("时间 / 模型"); Text("状态"); Text("总耗时"); Text("TTFT"); Text("输入 / 输出"); Text("输出 tok/s")
                    }.fontWeight(.medium)
                    ForEach(visibleRequests.suffix(50).reversed()) { request in
                        GridRow {
                            VStack(alignment: .leading) {
                                Text(request.startedAt.formatted(date: .omitted, time: .standard))
                                Text(request.modelID).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            }.frame(maxWidth: 190, alignment: .leading)
                            Text(request.error ?? String(request.statusCode)).foregroundStyle(request.succeeded ? .green : .red).lineLimit(2)
                            Text(seconds(request.duration))
                            Text(seconds(request.firstTokenLatency))
                            Text("\(request.inputTokens.map(String.init) ?? "—") / \(request.outputTokens.map(String.init) ?? "—")")
                            Text(request.outputTokensPerSecond.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—")
                        }
                    }
                }.font(.caption.monospacedDigit()).textSelection(.enabled)
                Text("表格显示最近 50 条；导出包含全部保留记录。数据不包含提示词、输出正文或认证信息。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit()).textSelection(.enabled)
        }
    }

    private func seconds(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(2))) + " s" } ?? "—"
    }
}
