import AppKit
import Darwin
import Foundation

private final class UpdateFixtureProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "update.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path == "/slow" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.respond() }
        } else { respond() }
    }
    private func respond() {
        lock.lock(); let active = !stopped; lock.unlock()
        guard active else { return }
        let path = request.url!.path
        let status = path == "/404" ? 404 : (path == "/403" ? 403 : 200)
        let headers = path == "/declared-large" ? ["Content-Length": "10000"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 42, count: path == "/stream-large" ? 256 : 16))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

private struct UpdateFixtureProvider: AppUpdateSourceProviding {
    let release: AppUpdateRelease
    func fetchLatest() async throws -> AppUpdateRelease { release }
}

@main
struct AppUpdateTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try testVersions()
        try testArchiveAttacks(root)
        try testAppleDouble(root)
        try await testTransfers()
        try testTransactions(root)
        try await testController(root)
        try await testPreparationError(root)
        let existingOutput = root.appendingPathComponent("existing-output")
        try FileManager.default.createDirectory(at: existingOutput, withIntermediateDirectories: false)
        let sentinel = existingOutput.appendingPathComponent("keep")
        try Data([1]).write(to: sentinel)
        precondition(AppUpdateHelper.run(arguments: ["--verify-archive", root.appendingPathComponent("missing.zip").path,
            root.path, "fixture", "0.2.0", existingOutput.path]) == 1)
        precondition(FileManager.default.fileExists(atPath: sentinel.path))
        print("AppUpdateTests: PASS (version, ZIP attacks and budgets, AppleDouble, HTTP limits, cancellation, rollback, failure UI)")
    }

    private static func testVersions() throws {
        let numericPrerelease = try AppUpdateVersion("0.2.0-beta.10") > AppUpdateVersion("0.2.0-beta.9")
        precondition(numericPrerelease)
        let stableUpgrade = try AppUpdateVersion("0.2.0") > AppUpdateVersion("0.2.0-beta.1")
        precondition(stableUpgrade)
        precondition(AppUpdateVersion.equivalent("v0.2.0", "0.2.0"))
        precondition(AppUpdateVersion.equivalent("0.2.0+build.42", "0.2.0"))
        precondition(AppUpdateVersion.equivalent("1.2", "1.2.0"))
        expectFailure { _ = try AppUpdateVersion("invalid") }
        precondition(AppUpdateAssetSelector.select(name: "MLXGateway-0.2.0-macos-arm64.zip", url: URL(string: "https://update.test/a.zip")!))
        precondition(!AppUpdateAssetSelector.select(name: "source-arm64.zip", url: URL(string: "https://update.test/a.zip")!))
    }

    private static func testArchiveAttacks(_ root: URL) throws {
        let cases: [(String, [(String, Data, UInt32)])] = [
            ("traversal", [("../escape", Data([1]), 0o100644)]),
            ("absolute", [("/tmp/escape", Data([1]), 0o100644)]),
            ("backslash", [("folder\\..\\escape", Data([1]), 0o100644)]),
            ("symlink", [("link", Data("../escape".utf8), 0o120777)]),
            ("fifo", [("pipe", Data(), 0o010644)]),
            ("duplicate", [("file", Data([1]), 0o100644), ("file", Data([2]), 0o100644)]),
            ("alias", [("folder/./file", Data([1]), 0o100644)]),
            ("metadata-traversal", [("__MACOSX/._..", Data([1]), 0o100644)])
        ]
        for (label, entries) in cases {
            try FileHandle.standardError.write(contentsOf: Data(("ZIP fixture: " + label + "\n").utf8))
            let archive = root.appendingPathComponent(label + ".zip")
            try zip(entries).write(to: archive)
            let destination = root.appendingPathComponent(label)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            expectFailure { try AppUpdateArchive.extract(archive, to: destination) }
        }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
        // No Unix file-type bits: zipinfo reports '?rw-------'. It must still count toward the budget.
        let unknownType = root.appendingPathComponent("unknown.zip")
        try zip([("payload", Data(repeating: 0, count: 2048), 0o600)]).write(to: unknownType)
        let unknownRoot = root.appendingPathComponent("unknown")
        try FileManager.default.createDirectory(at: unknownRoot, withIntermediateDirectories: false)
        expectFailure { try AppUpdateArchive.extract(unknownType, to: unknownRoot, maximumBytes: 1024) }
        // A real DEFLATE stream with both size declarations reduced to one byte.
        let payload = root.appendingPathComponent("payload")
        try Data(repeating: 0, count: 131_072).write(to: payload)
        let compressed = root.appendingPathComponent("underdeclared.zip")
        let result = AppUpdateProcess.run("/usr/bin/zip", arguments: ["-q", "-j", compressed.path, payload.path])
        precondition(result.status == 0)
        var data = try Data(contentsOf: compressed)
        guard let directory = data.range(of: Data([0x50, 0x4b, 1, 2])) else { fatalError("fixture missing central directory") }
        write32(1, in: &data, at: 22)
        write32(1, in: &data, at: directory.lowerBound + 24)
        try data.write(to: compressed)
        let output = root.appendingPathComponent("underdeclared")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        expectFailure { try AppUpdateArchive.extract(compressed, to: output, maximumBytes: 1024) }
        let written = (try? output.appendingPathComponent("payload").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        precondition(written <= 1024)
        let cumulative = root.appendingPathComponent("cumulative.zip")
        try zip([("a", Data(repeating: 0, count: 700), 0o100600), ("b", Data(repeating: 0, count: 700), 0o100600)]).write(to: cumulative)
        let cumulativeRoot = root.appendingPathComponent("cumulative")
        try FileManager.default.createDirectory(at: cumulativeRoot, withIntermediateDirectories: false)
        expectFailure { try AppUpdateArchive.extract(cumulative, to: cumulativeRoot, maximumBytes: 1024) }
        let valid = root.appendingPathComponent("valid.zip")
        try zip([("file", Data([1, 2, 3]), 0o100755)]).write(to: valid)
        let validRoot = root.appendingPathComponent("valid")
        try FileManager.default.createDirectory(at: validRoot, withIntermediateDirectories: false)
        try AppUpdateArchive.extract(valid, to: validRoot)
        let extracted = try Data(contentsOf: validRoot.appendingPathComponent("file"))
        precondition(extracted == Data([1, 2, 3]))
        precondition(FileManager.default.isExecutableFile(atPath: validRoot.appendingPathComponent("file").path))
    }

    private static func testAppleDouble(_ root: URL) throws {
        let source = root.appendingPathComponent("Metadata.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data([7]).write(to: source.appendingPathComponent("file"))
        let set = AppUpdateProcess.run("/usr/bin/xattr", arguments: ["-w", "com.example.mlx-update-fixture", "ticket-fixture", source.appendingPathComponent("file").path])
        precondition(set.status == 0)
        let archive = root.appendingPathComponent("metadata.zip")
        let package = AppUpdateProcess.run("/usr/bin/ditto", arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path])
        precondition(package.status == 0)
        let output = root.appendingPathComponent("metadata-out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try AppUpdateArchive.extract(archive, to: output)
        let read = AppUpdateProcess.run("/usr/bin/xattr", arguments: ["-p", "com.example.mlx-update-fixture", output.appendingPathComponent("Metadata.app/file").path])
        precondition(read.status == 0 && read.output.contains("ticket-fixture"))
    }

    private static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateFixtureProtocol.self]
        return config
    }
    private static func url(_ path: String) -> URL { URL(string: "https://update.test/" + path)! }
    private static func testTransfers() async throws {
        let downloader = AppUpdateDownloader(maximumBytes: 64, configuration: configuration())
        for path in ["declared-large", "stream-large", "403"] {
            do { _ = try await downloader.download(url(path), progress: { _ in }); fatalError("download accepted \(path)") }
            catch AppUpdateError.downloadTooLarge where path != "403" { }
            catch AppUpdateError.invalidHTTPStatus(403) where path == "403" { }
        }
        let before = Task { try await downloader.download(url("slow"), progress: { _ in }) }
        before.cancel()
        do { _ = try await before.value; fatalError("pre-cancelled task succeeded") } catch is CancellationError { }
        let during = Task { try await downloader.download(url("slow"), progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(10))
        during.cancel()
        do { _ = try await during.value; fatalError("cancelled task succeeded") } catch is CancellationError { }
        let success = try await downloader.download(url("ok"), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: success) }
        let downloaded = try Data(contentsOf: success)
        precondition(downloaded.count == 16)
        let redirect = AppUpdateTransfer(request: URLRequest(url: url("start")), configuration: configuration(), maximumBytes: 64, progress: { _ in })
        let request: URLRequest? = await withCheckedContinuation { continuation in
            redirect.urlSession(.shared, task: URLSession.shared.dataTask(with: url("start")),
                willPerformHTTPRedirection: HTTPURLResponse(url: url("start"), statusCode: 302, httpVersion: nil, headerFields: nil)!,
                newRequest: URLRequest(url: URL(string: "http://update.test/end")!)) { continuation.resume(returning: $0) }
        }
        precondition(request == nil)
        let provider = AppUpdateGitHubReleaseProvider(endpoint: url("404"), session: URLSession(configuration: configuration()))
        do { _ = try await provider.fetchLatest(); fatalError("404 accepted") } catch AppUpdateError.noPublishedRelease { }
    }

    private static func testTransactions(_ root: URL) throws {
        for scenario in ["copy-failure", "launch-failure", "restore-failure"] {
            let work = root.appendingPathComponent(scenario)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            let target = work.appendingPathComponent("Target.app"), candidate = work.appendingPathComponent("Candidate.app"), backup = work.appendingPathComponent("previous.app")
            for app in [target, candidate] { try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false) }
            try Data("old".utf8).write(to: target.appendingPathComponent("old"))
            try Data("new".utf8).write(to: candidate.appendingPathComponent("new"))
            var moves = 0
            expectFailure {
                try AppUpdateInstallTransaction.replace(candidate: candidate, target: target, backup: backup, move: { from, to in
                    moves += 1
                    if moves == 2 && scenario != "launch-failure" {
                        if scenario == "restore-failure" { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
                        throw AppUpdateError.processFailed("injected replacement failure")
                    }
                    try AppUpdateInstallTransaction.moveExclusively(from, to)
                }, launch: { _ in throw AppUpdateError.processFailed("injected launch failure") })
            }
            if scenario == "restore-failure" {
                precondition(FileManager.default.fileExists(atPath: backup.appendingPathComponent("old").path))
                precondition(!FileManager.default.fileExists(atPath: target.appendingPathComponent("previous.app").path))
            } else { precondition(FileManager.default.fileExists(atPath: target.appendingPathComponent("old").path)) }
        }
    }

    @MainActor private static func testController(_ root: URL) async throws {
        var config = AppUpdateConfiguration.default()
        config.currentVersion = "0.1.0"
        let release = AppUpdateRelease(version: "v0.2.0", title: "fixture", notes: "", publishedAt: nil,
                                       downloadURL: url("slow"), assetName: "arm64.zip", source: .githubRelease)
        let provider = UpdateFixtureProvider(release: release)
        let updater = AppUpdateController(configuration: config, provider: provider,
            downloader: AppUpdateDownloader(maximumBytes: 64, configuration: configuration()), failureLogURL: nil)
        updater.checkForUpdates()
        try await Task.sleep(for: .milliseconds(10))
        precondition(updater.status == .available)
        updater.downloadUpdate()
        updater.downloadUpdate() // same event turn: the second request must be ignored.
        precondition(updater.status == .downloading)
        updater.cancelDownload()
        updater.checkForUpdates()
        try await Task.sleep(for: .milliseconds(250))
        precondition(updater.status == .available && updater.availableRelease == release && updater.errorMessage == nil)
        let failure = root.appendingPathComponent("failure.log")
        AppUpdateFailureStore.record("fixture installation failed", at: failure)
        let restored = AppUpdateController(configuration: config, provider: provider, failureLogURL: failure)
        precondition(restored.status == .failed && restored.errorMessage!.contains("fixture installation failed"))
        restored.checkForUpdates(automatic: true)
        precondition(restored.status == .failed)
        restored.checkForUpdates()
        try await Task.sleep(for: .milliseconds(10))
        precondition(restored.status == .available && AppUpdateFailureStore.read(at: failure) == nil)
    }

    private static func testPreparationError(_ root: URL) async throws {
        let app = root.appendingPathComponent("PreparationFixture.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.fixture", "CFBundleExecutable": "fixture", "CFBundleShortVersionString": "0.1.0", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("fixture")
        try Data("#!/bin/sh\nprintf 'ERROR:fixture preparation failed\\n'\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let release = AppUpdateRelease(version: "0.2.0", title: "fixture", notes: "", publishedAt: nil,
                                       downloadURL: url("ok"), assetName: "arm64.zip", source: .githubRelease)
        do {
            try await AppUpdateInstaller(targetBundleURL: app, bundleIdentifier: "test.fixture", currentVersion: "0.1.0")
                .launch(archiveURL: root.appendingPathComponent("unused.zip"), release: release)
            fatalError("preparation error accepted")
        } catch AppUpdateError.processFailed(let message) { precondition(message.contains("fixture preparation failed")) }
        precondition(FileManager.default.fileExists(atPath: executable.path))
    }

    private static func expectFailure(_ body: () throws -> Void, line: UInt = #line) {
        do { try body(); fatalError("unsafe operation unexpectedly succeeded at test line \(line)") } catch { }
    }
    private static func write32(_ value: UInt32, in data: inout Data, at index: Int) {
        for byte in 0..<4 { data[index + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }
    private static func zip(_ entries: [(String, Data, UInt32)]) -> Data {
        var output = Data(), central = Data()
        func number<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        for (name, payload, mode) in entries {
            let offset = UInt32(output.count), filename = Data(name.utf8)
            var crc: UInt32 = 0xffffffff
            for byte in payload { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
            crc ^= 0xffffffff
            number(UInt32(0x04034b50), into: &output)
            for value: UInt16 in [20, 0, 0, 0, 0] { number(value, into: &output) }
            number(crc, into: &output); number(UInt32(payload.count), into: &output); number(UInt32(payload.count), into: &output)
            number(UInt16(filename.count), into: &output); number(UInt16(0), into: &output)
            output.append(filename); output.append(payload)
            number(UInt32(0x02014b50), into: &central)
            for value: UInt16 in [0x0314, 20, 0, 0, 0, 0] { number(value, into: &central) }
            number(crc, into: &central); number(UInt32(payload.count), into: &central); number(UInt32(payload.count), into: &central)
            number(UInt16(filename.count), into: &central)
            for _ in 0..<4 { number(UInt16(0), into: &central) }
            number(mode << 16, into: &central); number(offset, into: &central); central.append(filename)
        }
        let offset = UInt32(output.count)
        output.append(central); number(UInt32(0x06054b50), into: &output)
        number(UInt16(0), into: &output); number(UInt16(0), into: &output)
        number(UInt16(entries.count), into: &output); number(UInt16(entries.count), into: &output)
        number(UInt32(central.count), into: &output); number(offset, into: &output); number(UInt16(0), into: &output)
        return output
    }
}
