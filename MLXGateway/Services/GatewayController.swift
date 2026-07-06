import Foundation
import AppKit

final class GatewayController: ObservableObject {
    @Published var gatewayHost = "127.0.0.1"
    @Published var gatewayPort = "44110"
    @Published var modelHost = "127.0.0.1"
    @Published var modelPort = "44100"
    @Published var statusText = "Starting"
    @Published var lastError: String?

    let registry = ModelRegistry.shared
    let backendManager = BackendManager()
    private lazy var server = GatewayServer(
        registry: registry,
        backendManager: backendManager,
        host: gatewayHost,
        port: UInt16(gatewayPort) ?? 44110,
        modelHost: modelHost,
        modelPort: UInt16(modelPort) ?? 44100
    )

    init() {
        startGateway()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.backendManager.stop()
            self?.server.stop()
        }
    }

    var baseURL: String {
        "http://\(gatewayHost):\(gatewayPort)/v1"
    }

    var anthropicBaseURL: String {
        "http://\(gatewayHost):\(gatewayPort)"
    }

    var backendStatus: [String: Any] {
        backendManager.publicStatus
    }

    func restartGateway() {
        let gatewayPortValue = UInt16(gatewayPort) ?? 44110
        let modelPortValue = UInt16(modelPort) ?? 44100
        do {
            try server.restart(host: gatewayHost, port: gatewayPortValue, modelHost: modelHost, modelPort: modelPortValue)
            statusText = "Ready"
            lastError = nil
        } catch {
            statusText = "Failed"
            lastError = error.localizedDescription
        }
    }

    func stopBackend() {
        backendManager.stop()
    }

    private func startGateway() {
        do {
            try server.start()
            statusText = "Ready"
            lastError = nil
        } catch {
            statusText = "Failed"
            lastError = error.localizedDescription
        }
    }
}
