import AppKit
import Combine
import Foundation

@MainActor
final class AppUpdateController: ObservableObject {
    @Published private(set) var status: AppUpdateStatus = .idle
    @Published private(set) var availableRelease: AppUpdateRelease?
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published var automaticChecksEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticChecksEnabled, forKey: Self.automaticChecksKey)
            if automaticChecksEnabled { startAutomaticChecks() }
            else { automaticTask?.cancel(); automaticTask = nil }
        }
    }
    @Published var source: AppUpdateSource
    @Published var pagesManifestURLString: String

    private(set) var configuration: AppUpdateConfiguration
    private var provider: any AppUpdateSourceProviding
    private let downloader: AppUpdateDownloader
    private var automaticTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var downloadedArchiveURL: URL?
    private var operationGeneration = 0
    private var installationFailurePending = false
    private let failureLogURL: URL?

    static let automaticChecksKey = "MLXGateway.automaticUpdateChecks"
    static let sourceKey = "MLXGateway.updateSource"
    static let pagesManifestURLKey = "MLXGateway.pagesManifestURL"

    init(configuration: AppUpdateConfiguration = .default(),
         provider: (any AppUpdateSourceProviding)? = nil,
         downloader: AppUpdateDownloader = AppUpdateDownloader(),
         failureLogURL: URL? = AppUpdateFailureStore.defaultURL) {
        var resolvedConfiguration = configuration
        let defaults = UserDefaults.standard
        let storedSource = defaults.string(forKey: Self.sourceKey).flatMap(AppUpdateSource.init(rawValue:)) ?? configuration.source
        let storedPagesURL = defaults.string(forKey: Self.pagesManifestURLKey).flatMap(URL.init(string:))
        resolvedConfiguration.source = storedSource
        if let storedPagesURL { resolvedConfiguration.pagesManifestURL = storedPagesURL }
        self.configuration = resolvedConfiguration
        self.source = storedSource
        self.pagesManifestURLString = resolvedConfiguration.pagesManifestURL?.absoluteString ?? ""
        self.provider = provider ?? Self.makeProvider(configuration: resolvedConfiguration)
        self.downloader = downloader
        self.failureLogURL = failureLogURL
        self.automaticChecksEnabled = defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
        if let failureLogURL, let message = AppUpdateFailureStore.read(at: failureLogURL) {
            installationFailurePending = true
            status = .failed
            errorMessage = "上次安装未完成：" + message
        }
    }

    var hasUpdate: Bool { status == .available || status == .downloading || status == .readyToInstall }
    var canInstall: Bool { status == .readyToInstall && downloadedArchiveURL != nil }

    func startAutomaticChecks() {
        if let automaticTask, !automaticTask.isCancelled { return }
        guard automaticChecksEnabled else { return }
        let interval = configuration.checkInterval
        automaticTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { [weak self] in
                    guard let self, self.automaticChecksEnabled else { return }
                    self.checkForUpdates(automatic: true)
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func checkForUpdates(automatic: Bool = false) {
        if automatic && installationFailurePending { return }
        guard status != .downloading, status != .readyToInstall, status != .installing else { return }
        installationFailurePending = false
        if let failureLogURL { AppUpdateFailureStore.clear(at: failureLogURL) }
        operationGeneration += 1
        let generation = operationGeneration
        activeTask?.cancel()
        status = .checking
        activeTask = Task { [weak self] in await self?.performCheck(generation: generation) }
    }

    func downloadUpdate() {
        guard let release = availableRelease, status == .available else { return }
        operationGeneration += 1
        let generation = operationGeneration
        activeTask?.cancel()
        status = .downloading
        downloadProgress = 0
        activeTask = Task { [weak self] in
            guard let self, self.operationGeneration == generation else { return }
            var archive: URL?
            var retained = false
            defer { if !retained, let archive { try? FileManager.default.removeItem(at: archive) } }
            do {
                let downloaded = try await self.downloader.download(release.downloadURL) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.operationGeneration == generation else { return }
                        self.downloadProgress = progress
                    }
                }
                archive = downloaded
                try Task.checkCancellation()
                let bundleIdentifier = self.configuration.bundleIdentifier
                let currentBundleURL = self.configuration.currentBundleURL
                let validation = Task.detached(priority: .userInitiated) {
                    try AppUpdateArchiveValidator.validateArchiveForInstall(
                        at: downloaded, expectedBundleIdentifier: bundleIdentifier,
                        expectedVersion: release.version, currentBundleURL: currentBundleURL)
                }
                try await withTaskCancellationHandler {
                    try await validation.value
                } onCancel: { validation.cancel() }
                try Task.checkCancellation()
                guard self.operationGeneration == generation else { return }
                self.downloadedArchiveURL = downloaded
                retained = true
                self.status = .readyToInstall
                self.errorMessage = nil
            } catch {
                guard self.operationGeneration == generation else { return }
                if Task.isCancelled || error is CancellationError {
                    self.status = .available
                } else {
                    self.status = .failed
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelDownload() {
        guard status == .downloading else { return }
        operationGeneration += 1
        activeTask?.cancel()
        activeTask = nil
        status = availableRelease == nil ? .idle : .available
        downloadProgress = 0
    }

    func retry() {
        switch status {
        case .available: downloadUpdate()
        case .failed: checkForUpdates()
        default: checkForUpdates()
        }
    }

    func installAndRestart() {
        guard let release = availableRelease, let archive = downloadedArchiveURL, canInstall else { return }
        operationGeneration += 1
        let generation = operationGeneration
        status = .installing
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await AppUpdateInstaller(targetBundleURL: self.configuration.currentBundleURL,
                    bundleIdentifier: self.configuration.bundleIdentifier,
                    currentVersion: self.configuration.currentVersion).launch(archiveURL: archive, release: release)
                guard self.operationGeneration == generation else { return }
                NSApp.terminate(nil)
            } catch {
                guard self.operationGeneration == generation else { return }
                self.status = .failed
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func applySourceSettings() {
        guard status != .installing else { return }
        guard source == .githubRelease || URL(string: pagesManifestURLString).map({ (try? AppUpdateURLPolicy.validateHTTPS($0)) != nil }) == true else {
            status = .failed
            errorMessage = AppUpdateError.insecureURL.localizedDescription
            return
        }
        operationGeneration += 1
        activeTask?.cancel()
        if let downloadedArchiveURL { try? FileManager.default.removeItem(at: downloadedArchiveURL) }
        downloadedArchiveURL = nil
        availableRelease = nil
        downloadProgress = 0
        errorMessage = nil
        status = .idle
        configuration.source = source
        configuration.pagesManifestURL = source == .pagesManifest ? URL(string: pagesManifestURLString) : configuration.pagesManifestURL
        UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
        UserDefaults.standard.set(configuration.pagesManifestURL?.absoluteString, forKey: Self.pagesManifestURLKey)
        provider = Self.makeProvider(configuration: configuration)
        checkForUpdates()
    }

    private func performCheck(generation: Int) async {
        guard operationGeneration == generation,
              status != .downloading, status != .readyToInstall, status != .installing else { return }
        status = .checking
        errorMessage = nil
        do {
            let release = try await provider.fetchLatest()
            guard operationGeneration == generation,
                  status == .checking else { return }
            guard let current = try? AppUpdateVersion(configuration.currentVersion),
                  let candidate = try? AppUpdateVersion(release.version) else {
                throw AppUpdateError.invalidVersion(release.version)
            }
            lastCheckedAt = Date()
            if candidate > current {
                availableRelease = release
                status = .available
            } else {
                availableRelease = nil
                status = .upToDate
            }
        } catch AppUpdateError.noPublishedRelease {
            guard operationGeneration == generation else { return }
            lastCheckedAt = Date(); availableRelease = nil; status = .noRelease
        } catch is CancellationError {
            guard operationGeneration == generation else { return }
            status = .idle
        } catch {
            guard operationGeneration == generation else { return }
            lastCheckedAt = Date(); status = .failed; errorMessage = error.localizedDescription
        }
    }

    private static func makeProvider(configuration: AppUpdateConfiguration) -> any AppUpdateSourceProviding {
        switch configuration.source {
        case .githubRelease: return AppUpdateGitHubReleaseProvider(endpoint: configuration.githubLatestURL)
        case .pagesManifest: return AppUpdatePagesManifestProvider(endpoint: configuration.pagesManifestURL ?? configuration.githubLatestURL)
        }
    }

    deinit { automaticTask?.cancel(); activeTask?.cancel() }
}
