import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BulkGitHubKit

/// Recipe interchange via plain-text file panels. A recipe is a `.ts` file, so
/// importing is "copy a file in" (after validation) and exporting is "write the
/// source out" — the same format used for bundled and user recipes alike.
@MainActor
func importRecipeViaPanel(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "ts") ?? .plainText]
    panel.allowsMultipleSelection = false
    panel.message = "Choose a recipe (.ts) to import"
    panel.prompt = "Import"
    if panel.runModal() == .OK, let url = panel.url {
        model.importRecipe(from: url)
    }
}

@MainActor
func exportRecipeViaPanel(_ recipe: Recipe, _ model: AppModel) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "ts") ?? .plainText]
    panel.nameFieldStringValue = "\(recipe.id).ts"
    panel.prompt = "Export"
    if panel.runModal() == .OK, let url = panel.url {
        model.exportRecipe(recipe, to: url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var onTerminate: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.onTerminate?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private extension View {
    /// Hide the window title's display (macOS 15+; earlier systems keep it).
    @ViewBuilder
    func windowTitleHidden() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

@main
struct BulkGitHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        // Window, not WindowGroup: a single-workspace app. WindowGroup let
        // the system offer "New BulkGitHub Window" — a second live mirror of
        // the same job, useless here and confusing next to File > New Job.
        Window("BulkGitHub", id: "main") {
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
                // The app's name lives in the menu bar; displayed in the
                // window it crowds the traffic lights next to the flow
                // control. The title itself stays — Mission Control and
                // the Window menu use it — it just isn't drawn.
                .windowTitleHidden()
        }
        .commands {
            // Single-workspace app: ⌘N starts a fresh job (after
            // confirmation in MainView), not a new window.
            CommandGroup(replacing: .newItem) {
                Button("New Job…") { model.requestNewJob() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.running || model.generating || model.validating)
            }
            // The app has no document save; ⌘S captures the workspace into
            // the recipe library instead.
            CommandGroup(replacing: .saveItem) {
                Button("Save Script as Recipe…") { model.requestSaveRecipe() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.running || model.generating || model.scriptText.isEmpty)
                Button("Import Recipe…") { importRecipeViaPanel(model) }
                    .disabled(model.running || model.generating)
            }
            // The flow bar's menu home (every control needs one): phase
            // switching from the View menu, Mail/Finder-style.
            CommandGroup(after: .toolbar) {
                Button("Find Phase") { model.setPhase(.check) }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(model.running || model.generating)
                Button("Update Phase") { model.setPhase(.update) }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(model.running || model.generating)
                Button("Complete Phase") { model.setPhase(.merge) }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(model.running || model.generating)
                Divider()
                Button("Reset GitHub Connection") { model.resetGitHubSession() }
                    .disabled(model.running)
                    .help("Tear down and rebuild the GitHub connection pool if a run seems wedged")
                Divider()
            }
            #if DEBUG
            // Documentation screenshots: renders the app's own window — no
            // screen-recording permission involved.
            CommandMenu("Debug") {
                Button("Save Window Snapshot") { WindowSnapshotter.save() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Resize Window for Screenshots") { WindowSnapshotter.resizeForScreenshots() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            #endif
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
