import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MLXGatewayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = GatewayController()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("MLX Gateway", systemImage: "point.3.connected.trianglepath.dotted") {
            Text(controller.statusText)
            Divider()
            Button("Show Status") {
                openWindow(id: "status")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Stop Backend") {
                controller.stopBackend()
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        WindowGroup("MLX Gateway", id: "status") {
            StatusWindowView(controller: controller)
        }
        .windowResizability(.contentSize)
    }
}
