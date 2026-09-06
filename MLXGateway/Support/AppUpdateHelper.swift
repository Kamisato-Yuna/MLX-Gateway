import Darwin
import Foundation

enum AppUpdateFailureStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MLXGateway/update-failure.log")
    }
    static func record(_ message: String, at url: URL = defaultURL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(message.utf8).write(to: url, options: .atomic)
        } catch { /* The helper also reports the error through stderr/stdout. */ }
    }
    static func read(at url: URL = defaultURL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 16_384), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    static func clear(at url: URL = defaultURL) { try? FileManager.default.removeItem(at: url) }
}

/// Both renames take place on the target volume. No cross-volume copy occurs after the old app exits.
enum AppUpdateInstallTransaction {
    static func moveExclusively(_ source: URL, _ destination: URL) throws {
        let result = source.path.withCString { from in
            destination.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else {
            throw AppUpdateError.processFailed("无法移动 \(source.lastPathComponent)：\(String(cString: strerror(errno)))")
        }
    }

    static func replace(candidate: URL, target: URL, backup: URL,
                        move: (URL, URL) throws -> Void = moveExclusively,
                        launch: (URL) throws -> Void) throws {
        try move(target, backup)
        do {
            try move(candidate, target)
        } catch {
            do { try move(backup, target) }
            catch {
                throw AppUpdateError.processFailed("安装及恢复失败；旧应用保留在 \(backup.path)。\(error.localizedDescription)")
            }
            throw AppUpdateError.processFailed("替换失败，旧应用已恢复。")
        }
        do { try launch(target) }
        catch {
            let failed = backup.deletingLastPathComponent().appendingPathComponent("failed.app")
            do {
                try move(target, failed)
                try move(backup, target)
            } catch {
                throw AppUpdateError.processFailed("启动及恢复失败；请检查旧应用 \(backup.path)。\(error.localizedDescription)")
            }
            throw AppUpdateError.processFailed("新应用无法启动，旧应用已恢复。")
        }
    }
}

enum AppUpdateHelper {
    static func run(arguments: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        if arguments.first == "--verify-archive" { return verifyArchive(arguments) }
        guard arguments.count == 9, arguments[0] == "--install", let pid = Int32(arguments[7]), pid > 1,
              pid != getpid() else {
            report("ERROR:安装参数无效。")
            return 2
        }
        let archive = URL(fileURLWithPath: arguments[1])
        let target = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let identifier = arguments[3], currentVersion = arguments[4], version = arguments[5], team = arguments[6]
        let failureLog = URL(fileURLWithPath: arguments[8])
        var ready = false
        var stage: URL?
        var backup: URL?
        defer {
            // Never delete the only surviving old application after an unsuccessful restore.
            if let stage, backup.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
                try? FileManager.default.removeItem(at: stage)
            }
        }
        do {
            guard try AppUpdateVersion(version) > AppUpdateVersion(currentVersion) else {
                throw AppUpdateError.invalidVersion(version)
            }
            let attributes = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true,
                  !team.isEmpty, AppUpdateSignatureValidator.teamIdentifier(for: target) == team else {
                throw AppUpdateError.signatureRejected
            }
            try AppUpdateSignatureValidator.validate(bundleURL: target, expectedBundleIdentifier: identifier,
                                                     expectedVersion: currentVersion, currentBundleURL: target)
            let root = target.deletingLastPathComponent()
                .appendingPathComponent(".MLXGateway-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            stage = root
            let candidate = try AppUpdateArchiveValidator.extractAndValidate(at: archive, to: root,
                expectedBundleIdentifier: identifier, expectedVersion: version, currentBundleURL: target)
            let previous = root.appendingPathComponent("previous.app")
            backup = previous
            ready = true
            report("READY")
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while processExists(pid) && ProcessInfo.processInfo.systemUptime < deadline { usleep(100_000) }
            guard !processExists(pid) else { throw AppUpdateError.processFailed("旧应用未能正常退出，已取消安装。") }
            try AppUpdateInstallTransaction.replace(candidate: candidate, target: target, backup: previous,
                                                   launch: openApplication)
            AppUpdateFailureStore.clear(at: failureLog)
            try? FileManager.default.removeItem(at: archive)
            return 0
        } catch {
            let message = error.localizedDescription
            AppUpdateFailureStore.record(message, at: failureLog)
            report("ERROR:" + message.replacingOccurrences(of: "\n", with: " "))
            if ready && !processExists(pid), FileManager.default.fileExists(atPath: target.path) {
                try? openApplication(target)
            }
            return 1
        }
    }

    private static func verifyArchive(_ arguments: [String]) -> Int32 {
        guard arguments.count == 6 else { report("ERROR:校验参数无效。"); return 2 }
        let output = URL(fileURLWithPath: arguments[5])
        var created = false
        do {
            guard output.path.withCString({ mkdir($0, 0o700) }) == 0 else {
                throw AppUpdateError.processFailed("校验输出目录必须不存在，且父目录必须可写。")
            }
            created = true
            let app = try AppUpdateArchiveValidator.extractAndValidate(at: URL(fileURLWithPath: arguments[1]),
                to: output, expectedBundleIdentifier: arguments[3], expectedVersion: arguments[4],
                currentBundleURL: URL(fileURLWithPath: arguments[2]))
            report("VERIFIED:" + app.path)
            return 0
        } catch {
            if created { try? FileManager.default.removeItem(at: output) }
            report("ERROR:" + error.localizedDescription)
            return 1
        }
    }

    private static func openApplication(_ url: URL) throws {
        let result = AppUpdateProcess.run("/usr/bin/open", arguments: ["-n", url.path])
        guard result.status == 0 else { throw AppUpdateError.processFailed(result.output) }
    }
    private static func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }
    private static func report(_ line: String) { try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8)) }
}
