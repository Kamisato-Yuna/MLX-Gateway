import Foundation

/// Explicit, opt-in real model smoke host, using the same services as the app.
@main
struct LiveModelHost {
    static func main() throws {
        let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/verification/live-backend.log")
        let registry = ModelRegistry.shared
        let backend = BackendManager(logURL: logURL)
        let server = GatewayServer(registry: registry, backendManager: backend, host: "127.0.0.1", port: 44319)
        try server.start()
        defer { server.stop(); backend.shutdown() }
        while let id = readLine() {
            if id == "stop" { backend.shutdown(); continue }
            guard let model = registry.model(id: id) else { continue }
            backend.start(model: model, host: "127.0.0.1", port: 44320)
        }
    }
}
