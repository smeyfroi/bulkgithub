import SwiftUI
import BulkGitHubKit

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } content: {
            VSplitView {
                ScriptPane()
                    .frame(minHeight: 240)
                ResultsPane()
                    .frame(minHeight: 160)
                ConsolePane()
                    .frame(minHeight: 80, idealHeight: 120, maxHeight: 240)
            }
            .navigationSplitViewColumnWidth(min: 480, ideal: 620)
        } detail: {
            DetailPane()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        }
        .navigationTitle("BulkGitHub")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            EnvironmentFooter()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.validate() }
                } label: {
                    Label("Check", systemImage: "checkmark.shield")
                }
                .help("Lint and type-check the script against the host API")
                .disabled(model.running || model.validating)

                if model.running {
                    Button {
                        model.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Cancel the run")
                } else {
                    Button {
                        model.run()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .help("Validate and run the script (check phase is read-only)")
                    .disabled(model.scriptText.isEmpty || model.validating)
                }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Job phases") {
                Label("Check", systemImage: "magnifyingglass")
                Label("Update (dry run)", systemImage: "pencil")
                    .help("Update scripts record an execution plan — nothing reaches GitHub")
                Label("Merge", systemImage: "arrow.triangle.merge")
                    .foregroundStyle(.tertiary)
                    .help("Later phase — guarded merge")
            }

            Section("Recipes") {
                Button {
                    model.loadRecipe(named: "find_yaml_key_value")
                } label: {
                    Label("Find YAML key/value", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.plain)

                Button {
                    model.loadRecipe(named: "find_string_in_path")
                } label: {
                    Label("Find string under path", systemImage: "text.magnifyingglass")
                }
                .buttonStyle(.plain)

                Button {
                    model.loadRecipe(named: "remove_line_with_string")
                } label: {
                    Label("Delete lines with string", systemImage: "pencil.slash")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }
}

/// Ambient environment status — deliberately out of the sidebar so it doesn't
/// compete with the workflow; lives in a quiet footer across the window.
struct EnvironmentFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            Label("org \(model.settings.organisation)", systemImage: "building.2")
            Label(model.settings.useFixtureGitHub ? "Fixture data" : "Live GitHub",
                  systemImage: model.settings.useFixtureGitHub ? "shippingbox" : "network")
            Label(model.settings.useMockLLM ? "Mock LLM" : "Anthropic",
                  systemImage: model.settings.useMockLLM ? "cpu" : "sparkles")
            Label(model.typeCheckerLabel,
                  systemImage: model.typeCheckingAvailable ? "checkmark.seal" : "xmark.seal")
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
