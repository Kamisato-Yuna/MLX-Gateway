import SwiftUI

struct AppUpdateView: View {
    @ObservedObject var updater: AppUpdateController

    var body: some View {
        Form {
            Section("软件更新") {
                Text("当前版本：\(updater.configuration.currentVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("自动检查更新", isOn: $updater.automaticChecksEnabled)
                Picker("更新源", selection: $updater.source) {
                    ForEach(AppUpdateSource.allCases, id: \.self) { source in
                        Text(source.title).tag(source)
                    }
                }
                .disabled(sourceControlsDisabled)
                if updater.source == .pagesManifest {
                    TextField("Pages manifest HTTPS URL", text: $updater.pagesManifestURLString)
                        .textFieldStyle(.roundedBorder)
                        .disabled(sourceControlsDisabled)
                } else {
                    Text("GitHub：Kamisato-Yuna/MLX-Gateway")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("保存源设置并检查") { updater.applySourceSettings() }
                    .disabled(sourceControlsDisabled)
                HStack {
                    Label(statusTitle, systemImage: statusSymbol)
                    Spacer()
                    if updater.status == .checking || updater.status == .downloading { ProgressView().controlSize(.small) }
                    Button("立即检查") { updater.checkForUpdates() }
                        .disabled(updater.status == .checking || updater.status == .downloading || updater.status == .installing)
                }
                if let date = updater.lastCheckedAt {
                    Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let release = updater.availableRelease {
                Section("\(release.title) · \(release.version)") {
                    if !release.notes.isEmpty {
                        ScrollView { Text(release.notes).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 150)
                    }
                    if updater.status == .available {
                        Button("下载更新") { updater.downloadUpdate() }.buttonStyle(.glassProminent)
                    } else if updater.status == .downloading {
                        ProgressView(value: updater.downloadProgress) { Text(updater.downloadProgress >= 1 ? "正在校验更新…" : "下载中…") }
                        Button("取消下载") { updater.cancelDownload() }
                    } else if updater.status == .readyToInstall {
                        Button("安装并重启") { updater.installAndRestart() }.buttonStyle(.glassProminent)
                    }
                }
            }
            if let error = updater.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("重试") { updater.retry() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .onAppear { updater.startAutomaticChecks() }
    }

    private var statusTitle: String {
        switch updater.status {
        case .idle: return "尚未检查"
        case .checking: return "正在检查更新…"
        case .noRelease: return "当前未发布更新"
        case .upToDate: return "已是最新版本"
        case .available: return "发现新版本"
        case .downloading: return "正在下载更新…"
        case .readyToInstall: return "更新已下载，可安装"
        case .installing: return "正在退出并安装…"
        case .failed: return "更新失败"
        }
    }

    private var statusSymbol: String {
        switch updater.status {
        case .available, .readyToInstall: return "arrow.up.circle"
        case .failed: return "exclamationmark.circle"
        case .upToDate: return "checkmark.circle"
        default: return "arrow.clockwise"
        }
    }

    private var sourceControlsDisabled: Bool {
        switch updater.status {
        case .checking, .downloading, .readyToInstall, .installing: return true
        default: return false
        }
    }
}
