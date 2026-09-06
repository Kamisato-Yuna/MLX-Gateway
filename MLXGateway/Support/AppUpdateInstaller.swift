import Foundation

struct AppUpdateInstaller: Sendable {
    let targetBundleURL: URL
    let bundleIdentifier: String
    let currentVersion: String

    /// Returns only after the child has staged and verified the complete update on the target volume.
    func launch(archiveURL: URL, release: AppUpdateRelease) async throws {
        guard try AppUpdateVersion(release.version) > AppUpdateVersion(currentVersion) else {
            throw AppUpdateError.invalidVersion(release.version)
        }
        guard let executable = Bundle(url: targetBundleURL)?.executableURL else {
            throw AppUpdateError.installerUnavailable
        }
        let worker = Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["--mlx-gateway-update-helper", "--install", archiveURL.path,
                targetBundleURL.path, bundleIdentifier, currentVersion, release.version,
                AppUpdateSignatureValidator.teamIdentifier(for: targetBundleURL) ?? "", String(getpid()),
                AppUpdateFailureStore.defaultURL.path]
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()
            // A pipe event is awaited off the main actor. The helper exits on every preparation error.
            var line = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte[0] == 10 { break }
                line.append(byte)
                guard line.count < 16_384 else { process.terminate(); throw AppUpdateError.processFailed("安装器响应无效。") }
            }
            let result = String(decoding: line, as: UTF8.self)
            guard result == "READY" else {
                throw AppUpdateError.processFailed(result.hasPrefix("ERROR:") ? String(result.dropFirst(6)) : "安装器在准备完成前退出。")
            }
            // Keep the read endpoint alive in the child? No further output is needed on success;
            // errors after READY are saved for the restarted application's UI.
            try? output.fileHandleForReading.close()
        }
        try await worker.value
    }
}
