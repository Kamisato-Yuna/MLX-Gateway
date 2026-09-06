import Foundation

enum AppUpdateSource: String, CaseIterable, Codable, Sendable {
    case githubRelease
    case pagesManifest

    var title: String {
        switch self {
        case .githubRelease: return "GitHub Release"
        case .pagesManifest: return "GitHub Pages manifest"
        }
    }
}

struct AppUpdateRelease: Codable, Equatable, Identifiable, Sendable {
    let version: String
    let title: String
    let notes: String
    let publishedAt: Date?
    let downloadURL: URL
    let assetName: String
    let source: AppUpdateSource

    var id: String { version }
}

enum AppUpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case noRelease
    case upToDate
    case available
    case downloading
    case readyToInstall
    case installing
    case failed
}

enum AppUpdateError: LocalizedError, Equatable {
    case noPublishedRelease
    case invalidHTTPStatus(Int)
    case invalidURL
    case unsupportedAsset
    case invalidVersion(String)
    case insecureURL
    case malformedManifest(String)
    case invalidArchive(String)
    case invalidBundle(String)
    case signatureRejected
    case installerUnavailable
    case processFailed(String)
    case downloadTooLarge

    var errorDescription: String? {
        switch self {
        case .noPublishedRelease: return "当前没有已发布的更新。"
        case .invalidHTTPStatus(let status): return "更新源返回 HTTP \(status)。"
        case .invalidURL: return "更新下载地址无效。"
        case .unsupportedAsset: return "更新源没有提供 macOS arm64 ZIP 客户端。"
        case .invalidVersion(let version): return "版本号无效：\(version)"
        case .insecureURL: return "更新地址必须使用 HTTPS。"
        case .malformedManifest(let message): return "更新 manifest 无效：\(message)"
        case .invalidArchive(let message): return "更新压缩包无效：\(message)"
        case .invalidBundle(let message): return "更新应用不匹配：\(message)"
        case .signatureRejected: return "更新应用的 Apple 代码签名或团队标识未通过校验。"
        case .installerUnavailable: return "更新安装组件缺失，请重新安装完整客户端。"
        case .downloadTooLarge: return "更新下载超过允许大小，已停止下载。"
        case .processFailed(let message): return "更新安装器启动失败：\(message)"
        }
    }
}

struct AppUpdateConfiguration: Sendable {
    var githubLatestURL: URL
    var pagesManifestURL: URL?
    var source: AppUpdateSource
    var checkInterval: Duration
    var bundleIdentifier: String
    var currentVersion: String
    var currentBundleURL: URL

    static func `default`(bundle: Bundle = .main) -> AppUpdateConfiguration {
        let info = bundle.infoDictionary ?? [:]
        let identifier = (info["CFBundleIdentifier"] as? String) ?? "dev.kamisato-yuna.MLXGateway"
        let version = (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        return AppUpdateConfiguration(
            githubLatestURL: URL(string: "https://api.github.com/repos/Kamisato-Yuna/MLX-Gateway/releases/latest")!,
            pagesManifestURL: URL(string: "https://kamisato-yuna.github.io/MLX-Gateway/update.json"),
            source: .githubRelease,
            checkInterval: .seconds(86_400),
            bundleIdentifier: identifier,
            currentVersion: version,
            currentBundleURL: bundle.bundleURL
        )
    }
}
