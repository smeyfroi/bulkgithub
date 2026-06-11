import SwiftUI
import BulkGitHubKit

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
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
                            // Effectful phases say what they do: a plain
                            // "Run" must never read as "this writes".
                            Label(model.phase == .check ? "Run" : "Dry Run",
                                  systemImage: "play.fill")
                        }
                        .help(model.phase == .check
                                ? "Validate and run the script (check phase is read-only)"
                                : "Run the script in dry-run mode — writes are recorded as a reviewable plan, nothing reaches GitHub")
                        // Generation streams into the editor, so running
                        // mid-generation would execute a truncated script.
                        .disabled(model.scriptText.isEmpty || model.validating || model.generating)

                        if model.phase != .check, !model.activePlan.isEmpty {
                            Button {
                                model.showApplySheet = true
                            } label: {
                                Label("Apply…", systemImage: "bolt.fill")
                            }
                            .help("Arm writes: re-run the reviewed plan for selected repositories")
                            .disabled(model.validating || model.generating || model.resultsAreStale)
                        }
                    }
                }
            }

            EnvironmentFooter()
        }
        .sheet(isPresented: $model.showApplySheet) {
            ApplySheet()
        }
    }
}

/// The arming flow: pick which planned repositories the reviewed plan is
/// applied to, see exactly where writes will go, confirm explicitly.
struct ApplySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var plannedRepos: [String] { model.activePlan.keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Arm writes", systemImage: "bolt.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)

            Text("The reviewed dry-run plan re-runs with writes enabled, for the selected repositories only. Every write must match the reviewed plan exactly; a repository that drifted since the dry run halts with nothing written.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.settings.useFixtureGitHub {
                Label("Writes go to: fixture data (offline test mode)", systemImage: "shippingbox")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Label("Live GitHub writes are disabled in this build — switch to fixture data to exercise the armed workflow",
                      systemImage: "lock.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
            }

            List(plannedRepos, id: \.self) { repo in
                HStack {
                    Toggle(isOn: binding(for: repo)) {
                        HStack(spacing: 6) {
                            Text(repo)
                            if model.canaryRepo == repo {
                                Image(systemName: "scope")
                                    .foregroundStyle(.purple)
                                    .help("Canary target")
                            }
                        }
                    }
                    Spacer()
                    Text("\(model.activePlan[repo]?.count ?? 0) action(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive) {
                    let repos = selected
                    dismiss()
                    model.applyPlan(to: repos)
                } label: {
                    Label("Arm and apply to \(selected.count) repo\(selected.count == 1 ? "" : "s")",
                          systemImage: "bolt.fill")
                }
                .disabled(selected.isEmpty || !model.settings.useFixtureGitHub)
            }
        }
        .padding(16)
        .frame(width: 480)
        .onAppear {
            // Canary-first: preselect just the canary when it has a plan,
            // otherwise everything planned.
            if !model.canaryRepo.isEmpty, model.activePlan[model.canaryRepo] != nil {
                selected = [model.canaryRepo]
            } else {
                selected = Set(plannedRepos)
            }
        }
    }

    private func binding(for repo: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(repo) },
            set: { isOn in
                if isOn { selected.insert(repo) } else { selected.remove(repo) }
            }
        )
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
                    .tag(JobPhase.merge)
                    .help("Approve job PRs, then merge scripts act on this job's artifacts only (dry run by default)")
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
            if model.currentRunIsArmed {
                Label("ARMED", systemImage: "bolt.fill")
                    .foregroundStyle(.red)
                    .fontWeight(.bold)
            }
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
