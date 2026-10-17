import Foundation
import AppKit
import Combine

struct PersistentServiceSnapshot: Decodable, Sendable {
    struct Job: Decodable, Identifiable, Sendable {
        let label: String
        let name: String
        let installed: Bool
        let loaded: Bool
        let login: Bool
        let recovery: Bool
        let state: String
        let pid: Int?
        let runs: Int
        let lastExit: String
        var id: String { label }
    }
    struct Operation: Decodable, Sendable {
        let action: String
        let state: String
        let message: String
        let date: String
    }
    let jobs: [Job]
    let gatewayReady: Bool
    let whisperReady: Bool
    let gatewayURL: String
    let audioURL: String
    let model: String
    let logs: String
    let operation: Operation?
}

@MainActor
final class PersistentServiceController: ObservableObject {
    @Published private(set) var snapshot: PersistentServiceSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var submitting = false
    @Published var login = true
    @Published var recovery = true
    @Published private(set) var editing = false
    let controlOnly: Bool
    var prepareForHandoff: (() -> Void)?
    private let runtime: String
    private let python: String
    private let helper: String?
    private var refreshing = false

    init(paths: RuntimePaths, controlOnly: Bool) {
        runtime = paths.directory
        python = paths.python
        helper = Bundle.main.url(forResource: "service_manager", withExtension: "py")?.path
        self.controlOnly = controlOnly
    }

    var busy: Bool { submitting || snapshot?.operation?.state == "running" }
    var installed: Bool { snapshot?.jobs.count == 2 && snapshot?.jobs.allSatisfy(\.installed) == true }
    var running: Bool { snapshot?.jobs.contains { $0.loaded } == true }

    func changeLogin(_ value: Bool) {
        login = value
        if !value { recovery = false }
        editing = true
    }

    func changeRecovery(_ value: Bool) {
        recovery = value
        editing = true
    }

    func refresh() async {
        guard !refreshing, !submitting else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let data = try await execute(["snapshot", "--runtime", runtime])
            snapshot = try JSONDecoder().decode(PersistentServiceSnapshot.self, from: data)
            if !editing, let jobs = snapshot?.jobs {
                login = !jobs.isEmpty && jobs.allSatisfy(\.login)
                recovery = !jobs.isEmpty && jobs.allSatisfy(\.recovery)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func perform(_ action: String) {
        guard installed, !busy else { return }
        submitting = true
        error = nil
        if running || action == "start" { prepareForHandoff?() }
        Task {
            defer { submitting = false }
            do {
                _ = try await execute(["submit", "--operation", action,
                                       "--login", login ? "true" : "false",
                                       "--recovery", recovery ? "true" : "false",
                                       "--control-pid", controlOnly ? String(ProcessInfo.processInfo.processIdentifier) : "0"])
                if action == "configure" { editing = false }
            } catch { self.error = error.localizedDescription }
        }
    }

    func openLogs() {
        guard let path = snapshot?.logs else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func execute(_ arguments: [String]) async throws -> Data {
        guard let helper else { throw ServiceError.message("应用中缺少服务助手，请重新构建应用。") }
        let executable = python
        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [helper] + arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ServiceError.message(String(data: data, encoding: .utf8) ?? "服务助手执行失败。")
            }
            return data
        }.value
    }

    private enum ServiceError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }
}
