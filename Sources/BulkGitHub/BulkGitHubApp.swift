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
        .commands {
            // Single-workspace app: ⌘N starts a fresh job (after
            // confirmation in MainView), not a new window.
            CommandGroup(replacing: .newItem) {
                Button("New Job…") { model.requestNewJob() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.running || model.generating || model.validating)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
