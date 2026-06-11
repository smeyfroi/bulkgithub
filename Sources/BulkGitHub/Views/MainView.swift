import SwiftUI
import BulkGitHubKit

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Plain VStack rather than a safeAreaInset overlay: the footer takes
        // its own space, so scrolling content (console, results) can never
        // hide its last line underneath it.
        VStack(spacing: 0) {
            // Every column gets a full min/ideal/max range: a column without a
            // max (the old detail pane) balloons until the split view can't
            // satisfy the widths side-by-side, at which point macOS floats the
            // side panels OVER the content and the dividers stop responding.
            // The middle workbench is the one column left free to flex.
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 300)
            } content: {
                VSplitView {
                    ScriptPane()
                        .frame(minHeight: 240)
                    ResultsPane()
                        .frame(minHeight: 160)
                    ConsolePane()
                        .frame(minHeight: 80, idealHeight: 120, maxHeight: 240)
                }
                .navigationSplitViewColumnWidth(min: 480, ideal: 720)
            } detail: {
                DetailPane()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 560)
            }
            .navigationSplitViewStyle(.balanced)
            .navigationTitle("BulkGitHub")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await model.validate() }
                    } label: {
                        Label("Check", systemImage: "checkmark.shield")
                    }
                    .help("Lint and type-check the script against the host API")
                    .disabled(model.running || model.validating || model.generating)

                    if model.running {
                        Button {
                            model.cancel()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .foregroundStyle(.red)
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Cancel the run — pending operations are abandoned")
                    } else {
                        Button {
                            model.run()
                        } label: {
                            Label("Run", systemImage: "play.fill")
                        }
                        .help("Validate and run the script (check phase is read-only; update phase records a dry-run plan)")
                        // Generation streams into the editor, so running
                        // mid-generation would execute a truncated script.
                        .disabled(model.scriptText.isEmpty || model.validating || model.generating)
                    }
                }
            }

            EnvironmentFooter()
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: phaseSelection) {
            Section("Job phases") {
                Label("Check", systemImage: "magnifyingglass")
                    .tag(JobPhase.check)
                    .help("Prompts generate read-only search scripts")
                Label("Update (dry run)", systemImage: "pencil")
                    .tag(JobPhase.update)
                    .help("Prompts generate dry-run update scripts — nothing reaches GitHub")
                Label("Merge", systemImage: "arrow.triangle.merge")
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
                    .help("Later phase — guarded merge")
            }

            Section("Recipes") {
                ForEach(RecipeCatalog.all) { recipe in
                    Button {
                        model.loadRecipe(recipe)
                    } label: {
                        Label(recipe.title, systemImage: recipe.systemImage)
                    }
                    .buttonStyle(.plain)
                    .help(recipe.prompt)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var phaseSelection: Binding<JobPhase?> {
        Binding(
            get: { model.phase },
            set: { phase in
                if let phase { model.setPhase(phase) }
            }
        )
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
            if let quota = model.quotaText {
                Label(quota, systemImage: "gauge.with.needle")
                    .help("GitHub API quota remaining")
            }
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
