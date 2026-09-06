import SwiftUI

enum GatewayPanel: String, CaseIterable, Identifiable {
    case logs = "运行日志", playground = "快速测试", performance = "性能分析", updates = "客户端更新"
    var id: String { rawValue }
}

struct StatusWindowView: View {
    @ObservedObject var controller: GatewayController
    @ObservedObject var updater: AppUpdateController
    @Binding var panel: GatewayPanel

    var body: some View {
        NavigationSplitView {
            List(selection: $controller.selectedModelID) {
                Section("本地模型 · \(controller.registry.models.count)") {
                    ForEach(controller.registry.models) { model in
                        HStack(spacing: 10) {
                            Image(systemName: model.backend.symbol)
                                .foregroundStyle(.tint).frame(width: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.displayName).font(.headline).lineLimit(2)
                                Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if controller.backend.modelID == model.id, controller.backend.pid != nil {
                                Image(systemName: controller.backend.state == .ready ? "checkmark.circle.fill" : "hourglass")
                                    .foregroundStyle(controller.backend.state == .ready ? .green : .orange)
                                    .accessibilityLabel(controller.backend.title)
                            }
                        }
                        .padding(.vertical, 8).tag(model.id).help(model.id)
                    }
                }
            }
            .overlay {
                if controller.scanningModels && controller.registry.models.isEmpty { ProgressView("扫描模型…") }
                else if controller.registry.models.isEmpty {
                    ContentUnavailableView("没有本地模型", systemImage: "folder.badge.questionmark", description: Text("在设置中选择 MLX 与模型目录。"))
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 285, max: 380)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("本机 MLX", systemImage: "cpu").font(.caption.weight(.medium))
                        Spacer()
                        Button(action: controller.refreshModels) {
                            Label("刷新模型", systemImage: "arrow.clockwise")
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .disabled(!controller.canConfigure)
                        .help("重新扫描模型目录；运行模型时请先停止")
                    }
                    Text(controller.scanningModels ? "正在扫描模型目录…" : controller.scanSummary)
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(18)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Picker("工作面板", selection: $panel) {
                    ForEach(GatewayPanel.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.vertical, 14)
                if panel != .updates, updater.hasUpdate || updater.errorMessage != nil {
                    HStack(spacing: 12) {
                        Label(updater.errorMessage == nil ? "客户端有可用更新" : "客户端更新需要处理",
                              systemImage: updater.errorMessage == nil ? "arrow.up.circle" : "exclamationmark.triangle")
                        Spacer()
                        Button("查看更新") { panel = .updates }
                    }
                    .font(.callout).padding(.horizontal, 24).padding(.bottom, 12)
                }
                ZStack {
                    VStack(spacing: 0) {
                        modelHeader
                        Divider().padding(.horizontal, 24)
                        RuntimeLogView(controller: controller)
                    }.panelVisibility(panel == .logs)
                    ResponsesPlaygroundView(baseURL: controller.activeBaseURL, modelID: controller.selectedModelID)
                        .panelVisibility(panel == .playground)
                    PerformancePanelView(monitor: controller.performance, benchmark: controller.benchmark,
                        baseURL: controller.activeBaseURL, modelID: controller.backend.modelID,
                        backendReady: controller.backend.state == .ready)
                        .panelVisibility(panel == .performance)
                    AppUpdateView(updater: updater).panelVisibility(panel == .updates)
                }
            }
            .navigationTitle("MLX Gateway")
            .navigationSubtitle("本机模型 · Responses 网关")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: controller.startSelectedModel) {
                        Label(controller.startTitle, systemImage: controller.backend.pid != nil && controller.backend.modelID != controller.selectedModelID ? "arrow.triangle.swap" : "play.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(!controller.canStart)
                    .help("启动所选模型；切换时先停止当前服务")
                    .keyboardShortcut("r", modifiers: [.command])
                    Button(action: controller.stopBackend) { Label("停止模型", systemImage: "stop.fill") }
                        .disabled(!controller.canStop)
                        .help("停止当前模型并释放内存；网关仍保持监听")
                        .keyboardShortcut(".", modifiers: [.command])
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button { controller.showingSettings = true } label: { Label("设置", systemImage: "slider.horizontal.3") }
                        .help("查看连接与 MLX 目录设置")
                }
            }
        }
        .frame(minWidth: 1060, minHeight: 760)
        .sheet(isPresented: $controller.showingSettings, onDismiss: controller.restoreSettings) { settingsSheet }
    }

    private var statusColor: Color {
        switch controller.backend.state {
        case .ready: return .green
        case .starting, .stopping: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var modelHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                GatewayMark().frame(width: 46, height: 46).padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.selectedModel?.displayName ?? "让本地模型连接你的应用")
                        .font(.title2.weight(.semibold)).lineLimit(2)
                    if let model = controller.selectedModel {
                        HStack {
                            Text(model.subtitle).font(.callout).foregroundStyle(.secondary)
                            copyButton("复制模型 ID", value: model.id)
                        }
                    } else {
                        Text("选择 MLX 目录，扫描模型后即可启动。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let issue = controller.runtimeIssue {
                HStack {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.callout)
                    Spacer()
                    Button("配置环境") { controller.showingSettings = true }
                }.foregroundStyle(.orange)
            } else if controller.registry.models.isEmpty && !controller.scanningModels {
                Button("选择 MLX 目录…") { controller.showingSettings = true }.buttonStyle(.glassProminent)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if controller.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: controller.backend.state == .ready ? "checkmark.circle.fill" : (controller.backend.state == .failed ? "exclamationmark.circle.fill" : "pause.circle")).foregroundStyle(statusColor) }
                    Text(controller.backend.title).font(.subheadline.weight(.medium))
                    if controller.backend.modelID != nil, controller.backend.state != .stopped {
                        Text("· \(controller.activeModel?.displayName ?? controller.backend.modelID ?? "")")
                            .font(.callout).lineLimit(1).truncationMode(.middle)
                    }
                }
                Text(controller.backend.message).font(.callout).foregroundStyle(.secondary)
                if controller.backend.pid != nil, controller.backend.modelID != controller.selectedModelID {
                    Label("所选模型尚未启动。点击「切换并启动」会停止当前模型及其请求。", systemImage: "arrow.triangle.swap")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.right.square").font(.title3).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.gatewayReady ? "网关正在监听 · OpenAI base_url" : "网关未就绪")
                        .font(.caption).foregroundStyle(controller.gatewayReady ? Color.secondary : .orange)
                    Text(controller.activeBaseURL).font(.callout.monospaced()).textSelection(.enabled)
                }
                Spacer()
                copyButton("复制地址", value: controller.activeBaseURL)
            }
            if let error = controller.gatewayError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("检查设置") { controller.showingSettings = true }
                }
            }
        }.padding(24)
    }

    private func copyButton(_ title: String, value: String) -> some View {
        Button { controller.copy(value) } label: {
            Label(controller.copiedValue == value ? "已复制" : title,
                  systemImage: controller.copiedValue == value ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless).font(.caption)
        .disabled(value.isEmpty).help(title)
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("MLX Gateway 设置", systemImage: "slider.horizontal.3").font(.title2.weight(.semibold))
            if !controller.canConfigure {
                Label("当前可查看设置；停止模型并等待扫描结束后可修改。", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Form {
                Section {
                    pathField("MLX 运行目录", value: Binding(get: { controller.runtimeDirectory }, set: controller.useRuntimeDirectory), kind: "runtime")
                    pathField("模型目录", value: $controller.modelsDirectory, kind: "models")
                    pathField("Python 可执行文件", value: $controller.pythonExecutable, kind: "python")
                } header: { Text("本地运行环境") } footer: {
                    Text("选择运行目录后默认使用 models/ 和 .venv/bin/python，也可分别指定。模型以目录中的 config.json 扫描结果为准；不会下载或修改模型。")
                }
                Section("Responses 网关 · 客户端连接此地址") {
                    TextField("网关主机", text: $controller.gatewayHost).disabled(!controller.canConfigure)
                    TextField("网关端口", text: $controller.gatewayPort).disabled(!controller.canConfigure)
                }
                Section("MLX 服务 · 内部模型进程") {
                    TextField("MLX 主机", text: $controller.modelHost).disabled(!controller.canConfigure)
                    TextField("MLX 端口", text: $controller.modelPort).disabled(!controller.canConfigure)
                }
                Section {
                    Text("默认仅本机访问。使用本机 IP 或 localhost；两个端口不能相同。网关没有认证，请勿直接暴露到不受信任网络。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let error = controller.settingsError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(controller.canConfigure ? "取消" : "关闭") { controller.showingSettings = false }.keyboardShortcut(.cancelAction)
                Button("保存并扫描") {
                    if controller.applySettings() { controller.showingSettings = false }
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!controller.canConfigure)
            }
        }.padding(24).frame(width: 600, height: 650)
    }

    private func pathField(_ title: String, value: Binding<String>, kind: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            HStack {
                TextField(title, text: value).labelsHidden().textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced()).help(value.wrappedValue)
                Button { controller.choosePath(kind) } label: { Image(systemName: "folder") }
                    .accessibilityLabel("选择\(title)").help("选择\(title)")
            }
        }.padding(.vertical, 3).disabled(!controller.canConfigure)
    }
}

private extension View {
    /// Keep drafts and active test tasks alive when switching panels.
    func panelVisibility(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0).allowsHitTesting(visible).disabled(!visible).accessibilityHidden(!visible)
    }
}

/// The same open gateway, local chip and outgoing response used in the app icon.
struct GatewayMark: View {
    var body: some View {
        ZStack {
            GatewayOutline().stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            Image(systemName: "cpu.fill").font(.system(size: 18)).foregroundStyle(.tint).offset(x: -2)
            Image(systemName: "arrow.right").font(.system(size: 17, weight: .bold)).foregroundStyle(.primary).offset(x: 15)
        }
    }
}

private struct GatewayOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.74, y: rect.height * 0.23))
        path.addLine(to: CGPoint(x: rect.width * 0.74, y: rect.height * 0.14))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.64, y: rect.height * 0.04), control: CGPoint(x: rect.width * 0.74, y: rect.height * 0.04))
        path.addLine(to: CGPoint(x: rect.width * 0.18, y: rect.height * 0.04))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.08, y: rect.height * 0.14), control: CGPoint(x: rect.width * 0.08, y: rect.height * 0.04))
        path.addLine(to: CGPoint(x: rect.width * 0.08, y: rect.height * 0.86))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.18, y: rect.height * 0.96), control: CGPoint(x: rect.width * 0.08, y: rect.height * 0.96))
        path.addLine(to: CGPoint(x: rect.width * 0.64, y: rect.height * 0.96))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.74, y: rect.height * 0.86), control: CGPoint(x: rect.width * 0.74, y: rect.height * 0.96))
        path.addLine(to: CGPoint(x: rect.width * 0.74, y: rect.height * 0.77))
        return path
    }
}
