import SwiftUI

struct PersistentServiceSettingsView: View {
    @ObservedObject var service: PersistentServiceController

    var body: some View {
        Form {
            Section {
                Toggle("登录后自动启动 Gateway 和 Whisper", isOn: Binding(get: { service.login }, set: service.changeLogin))
                Toggle("退出后自动恢复", isOn: Binding(get: { service.recovery }, set: service.changeRecovery))
                    .disabled(!service.login)
                HStack {
                    Text(service.editing ? "有未保存的修改" : configurationSummary).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存常驻配置") { service.perform("configure") }
                        .disabled(!service.editing)
                }
            } header: { Text("登录自启与自动恢复") } footer: {
                Text("登录 macOS 后启动。自动恢复由 launchd 执行，需要启用登录自启；正常退出应用也会重新打开。保存运行中的配置会短暂重启服务。")
            }
            .disabled(!service.installed || service.busy)

            Section("实际运行状态") {
                if let snapshot = service.snapshot {
                    ForEach(snapshot.jobs) { job in
                        HStack(alignment: .top) {
                            Label(job.name, systemImage: job.pid != nil ? "circle.fill" : "circle")
                                .foregroundStyle(job.pid != nil ? .green : .secondary)
                                .frame(width: 100, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.pid.map { "运行中 · PID \($0)" } ?? (job.loaded ? "等待启动" : "已停止"))
                                Text("登录自启：\(job.login ? "开" : "关") · 自动恢复：\(job.recovery ? "开" : "关")")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("启动次数：\(job.runs) · 最近退出：\(job.lastExit)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(job.installed ? "已安装" : "未安装").font(.caption).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                    LabeledContent("Gateway HTTP", value: snapshot.gatewayReady ? "可用" : "不可用")
                    LabeledContent("Whisper 模型", value: snapshot.whisperReady ? "\(snapshot.model) · 已就绪" : "\(snapshot.model) · 未就绪")
                    Text("\(snapshot.gatewayURL) → \(snapshot.audioURL)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    ProgressView("正在读取服务状态…")
                }
            }

            Section {
                HStack {
                    Button("启动服务", systemImage: "play.fill") { service.perform("start") }
                        .disabled(service.running || service.busy || !service.installed || service.editing)
                    Button("停止服务", systemImage: "stop.fill") { service.perform("stop") }
                        .disabled(!service.running || service.busy || !service.installed)
                    Button("重启服务", systemImage: "arrow.clockwise") { service.perform("restart") }
                        .disabled(!service.running || service.busy || !service.installed || service.editing)
                    Spacer()
                    Button("刷新", systemImage: "arrow.trianglehead.2.clockwise") { Task { await service.refresh() } }
                    Button("打开日志", systemImage: "folder") { service.openLogs() }
                }
                if let operation = service.snapshot?.operation {
                    Label(operation.message, systemImage: operation.state == "failed" ? "exclamationmark.triangle" : (operation.state == "running" ? "hourglass" : "checkmark.circle"))
                        .font(.callout).foregroundStyle(operation.state == "failed" ? .red : .secondary)
                }
                if let error = service.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if service.snapshot != nil && !service.installed {
                    Text("尚未安装常驻服务。请先按本地服务操作文档完成安装。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: { Text("服务操作") } footer: {
                Text(service.controlOnly
                     ? "当前为控制窗口，不监听服务端口。启动后会重新打开常驻应用。"
                     : "启停作用于 Gateway 与 Whisper。停止会中断当前请求，并重开控制窗口；保存的自启配置不变。正在运行的其他模型进程也会随 Gateway 退出。")
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await service.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    private var configurationSummary: String {
        guard let jobs = service.snapshot?.jobs, !jobs.isEmpty else { return "正在读取配置" }
        return Set(jobs.map(\.login)).count > 1 || Set(jobs.map(\.recovery)).count > 1 ? "两项服务配置不同，保存后统一应用" : "已读取 launchd 配置"
    }
}
