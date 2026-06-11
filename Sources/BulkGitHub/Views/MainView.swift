import SwiftUI
import BulkGitHubKit

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Plain VStack rather than a safeAreaInset overlay: the footer takes
        // its own space, so scrolling content (console, results) can never
        // hide its last line underneath it.
        VStack(spacing: 0) {
            // Deterministic three-pane tiling via HSplitView, NOT
            // NavigationSplitView: on macOS 26 the navigation sidebars are
            // glass panels floating over a full-width content layer, and the
            // safe-area insets that should keep content out from under them
            // are lost inside VSplitView — SwiftUI rows ended up laid out
            // under both panels (AppKit-backed editor/table re-inset
            // themselves, which is why only some rows looked broken).
            // HSplitView has no overlay layer: panes are always side-by-side
            // and dividers always drag. The middle workbench is the only
            // pane free to flex.
            // HSplitView/VSplitView panes are not greedy: each needs an
            // explicit max to fill its slot instead of collapsing to its
            // ideal size and centering.
            HSplitView {
                SidebarView()
                    .frame(minWidth: 170, idealWidth: 210, maxWidth: 300,
                           maxHeight: .infinity)
                // Split views measure children with unspecified proposals, so
                // a child with a wide ideal (the code editor's longest line)
                // can win the pane width and overflow-centre past both edges.
                // Pin every pane to the measured column width instead.
                GeometryReader { geo in
                    VSplitView {
                        ScriptPane()
                            .frame(width: geo.size.width)
                            .frame(minHeight: 240, maxHeight: .infinity)
                        ResultsPane()
                            .frame(width: geo.size.width)
                            .frame(minHeight: 160, maxHeight: .infinity)
                        ConsolePane()
                            .frame(width: geo.size.width)
                            .frame(minHeight: 80, idealHeight: 120, maxHeight: 240)
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                DetailPane()
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 560,
                           maxHeight: .infinity)
            }
            // HSplitView is not greedy — without this it collapses to its
            // children's minimum height inside the VStack.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
