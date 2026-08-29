import SwiftUI
import VNACore

@main
struct MightyVNAApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("MightyVNA", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1680, height: 1020)
        .defaultPosition(.center)
        .commands { AppCommands(model: model) }

        Settings {
            PreferencesView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
