import Foundation
import Security

enum AppUpdateURLPolicy {
    static func validateHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { throw AppUpdateError.insecureURL }
    }
}

enum AppUpdateAssetSelector {
    static func select(name: String, url: URL) -> Bool {
        let lower = name.lowercased()
        return url.pathExtension.lowercased() == "zip" && lower.contains("arm64") && !lower.contains("source")
    }
}

enum AppUpdateArchiveValidator {

    static func validateEntry(_ entry: String) throws {
        let normalized = entry.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains("\0"), !entry.contains("\\"), !entry.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else {
            throw AppUpdateError.invalidArchive("压缩包包含绝对路径或非法条目。")
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." }) else {
            throw AppUpdateError.invalidArchive("压缩包包含路径穿越条目。")
        }
    }

    static func validateEntries(_ entries: [String]) throws {
        guard !entries.isEmpty else { throw AppUpdateError.invalidArchive("压缩包为空。") }
        try entries.forEach(validateEntry)
    }
}

enum AppUpdateSignatureValidator {
    static func teamIdentifier(for bundleURL: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func validate(bundleURL: URL, expectedBundleIdentifier: String, expectedVersion: String,
                         currentBundleURL: URL) throws {
        guard let bundle = Bundle(url: bundleURL) else { throw AppUpdateError.invalidBundle("无法读取应用包。") }
        guard bundle.bundleIdentifier == expectedBundleIdentifier else {
            throw AppUpdateError.invalidBundle("bundle identifier 不匹配。")
        }
        guard let bundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              AppUpdateVersion.equivalent(bundleVersion, expectedVersion) else {
            throw AppUpdateError.invalidBundle("包内版本与 Release 不匹配。")
        }
        guard let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppUpdateError.invalidBundle("缺少可执行文件。")
        }
        let architectureResult = AppUpdateProcess.run("/usr/bin/lipo", arguments: ["-archs", executable.path])
        guard architectureResult.status == 0, architectureResult.output
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).contains("arm64") else {
            throw AppUpdateError.invalidBundle("可执行文件不是 arm64。")
        }
        guard let currentTeam = teamIdentifier(for: currentBundleURL), !currentTeam.isEmpty,
              let candidateTeam = teamIdentifier(for: bundleURL), candidateTeam == currentTeam else {
            throw AppUpdateError.signatureRejected
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { throw AppUpdateError.signatureRejected }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard let currentTeam = teamIdentifier(for: currentBundleURL), !currentTeam.isEmpty else {
            throw AppUpdateError.signatureRejected
        }
        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(currentTeam)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw AppUpdateError.signatureRejected
        }
    }
}

extension AppUpdateArchiveValidator {
    static func extractAndValidate(at archive: URL, to root: URL, expectedBundleIdentifier: String,
                                   expectedVersion: String, currentBundleURL: URL,
                                   checkCancellation: () throws -> Void = {}) throws -> URL {
        let attributes = try archive.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, Int64(size) <= AppUpdateArchive.maximumArchiveBytes else {
            throw AppUpdateError.invalidArchive("压缩包不是普通文件或超过 1 GiB 限制。")
        }
        try AppUpdateArchive.extract(archive, to: root, checkCancellation: checkCancellation)
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])?
            .compactMap { $0 as? URL } ?? []
        let apps = urls.filter { url in
            url.pathExtension == "app" && !url.pathComponents.contains("__MACOSX")
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard apps.count == 1 else { throw AppUpdateError.invalidArchive("压缩包必须包含唯一 app。") }
        try checkCancellation()
        try AppUpdateSignatureValidator.validate(bundleURL: apps[0], expectedBundleIdentifier: expectedBundleIdentifier,
                                                 expectedVersion: expectedVersion, currentBundleURL: currentBundleURL)
        return apps[0]
    }

    static func validateArchiveForInstall(at archive: URL, expectedBundleIdentifier: String,
                                          expectedVersion: String, currentBundleURL: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MLXGateway-update-validate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try extractAndValidate(at: archive, to: root, expectedBundleIdentifier: expectedBundleIdentifier,
                                   expectedVersion: expectedVersion, currentBundleURL: currentBundleURL,
                                   checkCancellation: { try Task.checkCancellation() })
    }
}

struct AppUpdateProcessResult: Sendable {
    let status: Int32
    let output: String
}

enum AppUpdateProcess {
    static func run(_ executable: String, arguments: [String]) -> AppUpdateProcessResult {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXGateway-update-process-\(UUID().uuidString).log")
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let outputFile = try FileHandle(forWritingTo: outputURL)
            process.standardOutput = outputFile
            process.standardError = outputFile
            try process.run()
            process.waitUntilExit()
            try outputFile.close()
            let data = try Data(contentsOf: outputURL)
            try? FileManager.default.removeItem(at: outputURL)
            return AppUpdateProcessResult(status: process.terminationStatus,
                                          output: String(decoding: data, as: UTF8.self))
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            return AppUpdateProcessResult(status: -1, output: error.localizedDescription)
        }
    }
}
