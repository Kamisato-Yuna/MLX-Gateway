import Foundation
import Darwin

@main struct AudioServiceMain {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("audio-controller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try LocalEndpoint.checkAvailable(host: "127.0.0.1", port: 44234)
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: RuntimePaths.saved.python)
        fixture.arguments = [root.appendingPathComponent("Tests/audio_fixture.py").path, "44234"]
        fixture.standardError = FileHandle.nullDevice; fixture.standardOutput = FileHandle.nullDevice
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let config = AudioTranscriptionProxy.Configuration(baseURL: URL(string: "http://127.0.0.1:44234/v1")!)
        let proxy = AudioTranscriptionProxy(configuration: config)
        let controller = AudioServiceController(proxy: proxy, runtimeDirectory: temporary.path)
        defer { controller.shutdown() }
        func wait(_ name: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { controller.refresh(force: true); try await Task.sleep(for: .milliseconds(50)) }
            guard condition() else { fputs("FAIL: \(name), state=\(controller.state), error=\(controller.error ?? "none")\n", stderr); exit(1) }
        }
        controller.refresh(force: true)
        try await wait("existing model is detected") { controller.state == .ready }
        assert(!controller.ownsProcess && controller.canStop)
        controller.stop()
        try await wait("external model unloads without terminating service") { controller.state == .available }
        let unloaded = await proxy.availability(configuration: config)
        assert(unloaded == .available)
        controller.start()
        try await wait("manual load restores readiness") { controller.state == .ready }
        controller.draftDisplayName = "测试 Whisper"
        assert(controller.save())
        try await wait("saved config reconnects") { controller.state == .ready }
        assert(AudioTranscriptionProxy.Configuration.load(runtimeDirectory: temporary.path)?.displayName == "测试 Whisper")
        controller.draftBaseURL = "http://user:secret@127.0.0.1:44234/v1"
        assert(!controller.save())
        controller.restoreDraft()
        assert(controller.draftBaseURL == config.baseURL.absoluteString)
        fixture.terminate(); fixture.waitUntilExit()
        controller.refresh(force: true)
        try await wait("stopped external service is not shown ready") { controller.state == .stopped }
        controller.start()
        try await wait("missing launch script reports failure") { controller.state == .failed }
        assert(controller.error?.contains("未配置启动脚本") == true)
        let launcher = temporary.appendingPathComponent("start-audio.sh")
        try "#!/bin/sh\nexec '\(RuntimePaths.saved.python)' '\(root.appendingPathComponent("Tests/audio_fixture.py").path)' 44234\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        controller.draftLaunchScript = launcher.path
        assert(controller.save())
        controller.start()
        try await wait("Gateway starts and loads owned process") { controller.state == .ready }
        assert(controller.ownsProcess)
        controller.stop()
        try await wait("owned process stops") { controller.state == .stopped }
        let stopped = await proxy.availability(configuration: config)
        assert(stopped == .unavailable && !controller.ownsProcess)
        print("PASS: audio controller detects, unloads, reloads and configures external services; unavailable service and invalid config are explicit")
    }
}
