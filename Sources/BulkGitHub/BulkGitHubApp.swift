import AppKit
import SwiftUI
import BulkGitHubKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var onTerminate: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.onTerminate?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct BulkGitHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("BulkGitHub") {
            MainView()
                .environment(model)
                // Wide enough for all three column minimums plus chrome, so
                // the split view never has to overlay the side panels.
                .frame(minWidth: 1080, minHeight: 620)
                .onAppear {
                    let model = self.model
                    AppDelegate.onTerminate = {
                        MainActor.assumeIsolated { model.saveNow() }
                    }
                }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
