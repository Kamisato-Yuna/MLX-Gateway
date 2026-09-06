import SwiftUI

struct RuntimeLogView: View {
    @ObservedObject var controller: GatewayController
    @State private var query = ""
    @State private var errorsOnly = false
    @State private var showingClearConfirmation = false
    @State private var rendered = AttributedString()
    @State private var visibleCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("运行日志", systemImage: "terminal").font(.headline)
                Spacer()
                Toggle("跟随最新", isOn: $controller.followLogs).toggleStyle(.switch).controlSize(.small)
                    .help("关闭自动滚动后，日志仍继续更新")
                Button(action: controller.openLogs) { Label("在访达中显示日志", systemImage: "folder") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                Button { showingClearConfirmation = true } label: {
                    Label(controller.clearingLogs ? "正在清理…" : "清理运行日志", systemImage: "trash")
                }.disabled(controller.clearingLogs || controller.logs.isEmpty)
            }
            HStack {
                TextField("搜索日志", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索运行日志")
                Toggle("仅警告与错误", isOn: $errorsOnly)
            }
            if let error = controller.logError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
            if let message = controller.logNotice {
                Label(message, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            if controller.logs.isEmpty {
                ContentUnavailableView("暂无运行日志", systemImage: "text.page", description: Text("模型加载进度、错误与推理日志将在这里显示。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleCount == 0 {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(rendered).font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                            Color.clear.frame(height: 1).id("runtime-log-end")
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: rendered) { if controller.followLogs { proxy.scrollTo("runtime-log-end", anchor: .bottomLeading) } }
                    .onChange(of: controller.followLogs) { if controller.followLogs { proxy.scrollTo("runtime-log-end", anchor: .bottomLeading) } }
                    .onAppear { if controller.followLogs { proxy.scrollTo("runtime-log-end", anchor: .bottomLeading) } }
                }
            }
            HStack(spacing: 16) {
                Label("错误", systemImage: "xmark.circle").foregroundStyle(.red)
                Label("警告", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Label("成功", systemImage: "checkmark.circle").foregroundStyle(.green)
                Spacer()
                Text("最近 64 KB · \(visibleCount) 行")
            }.font(.caption)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: controller.logs, initial: true) { render() }
        .onChange(of: query) { render() }
        .onChange(of: errorsOnly) { render() }
        .confirmationDialog("清理运行日志？", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button("清理日志", role: .destructive, action: controller.clearLogs)
        } message: {
            Text("将清空本地 backend.log 中所有模型的历史日志。模型继续运行，之后的新日志会正常记录。此操作不可撤销。")
        }
    }

    private func render() {
        let lines = RuntimeLogFormatting.lines(controller.logs).filter {
            (!$0.text.isEmpty) && (!errorsOnly || $0.level == .warning || $0.level == .error)
                && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query))
        }
        var result = AttributedString()
        for line in lines {
            var text = AttributedString(line.text + "\n")
            switch line.level {
            case .error: text.foregroundColor = .red
            case .warning: text.foregroundColor = .orange
            case .success: text.foregroundColor = .green
            case .info: text.foregroundColor = .primary
            case .debug: text.foregroundColor = .secondary
            case .plain: text.foregroundColor = .primary
            }
            if !query.isEmpty {
                var searchStart = line.text.startIndex
                while searchStart < line.text.endIndex,
                      let match = line.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<line.text.endIndex) {
                    guard !match.isEmpty else { break }
                    if let lower = AttributedString.Index(match.lowerBound, within: text),
                       let upper = AttributedString.Index(match.upperBound, within: text) {
                        text[lower..<upper].backgroundColor = .yellow.opacity(0.3)
                        text[lower..<upper].font = .system(size: 12, weight: .bold, design: .monospaced)
                    }
                    searchStart = match.upperBound
                }
            }
            result.append(text)
        }
        rendered = result
        visibleCount = lines.count
    }
}
