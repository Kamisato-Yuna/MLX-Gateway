import AppKit
import SwiftUI
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A caught signal resets to the default in the Python child after exec.
        // SIG_IGN would instead make children inherit an ignored SIGTERM.
        signal(SIGTERM) { _ in }
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
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
        MenuBarExtra("MLX Gateway", systemImage: "cpu") {
            Text(controller.backend.title)
            Divider()
            Button("显示主窗口") {
                openWindow(id: "status")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("启动所选模型", action: controller.startSelectedModel)
                .disabled(!controller.canStart)
            Button("停止 MLX 服务") {
                controller.stopBackend()
            }
            .disabled(!controller.canStop)
            Divider()
            Button("退出") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Window("MLX Gateway", id: "status") {
            StatusWindowView(controller: controller)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("设置…") { controller.showingSettings = true; openWindow(id: "status") }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        .defaultSize(width: 1060, height: 760)
        .defaultLaunchBehavior(.presented)
    }
}
