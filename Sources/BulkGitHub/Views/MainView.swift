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
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                // The detail pane holds the diffs — the actual work under
                // review — so it may open out wide at the workbench's expense.
                DetailPane()
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 760,
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
                        // The run mode is an explicit, visible toggle — not
                        // an implication of which button you found. Check is
                        // always read-only, so it has no toggle. Write only
                        // unlocks once a fresh reviewed plan exists, and
                        // snaps back to Dry Run after every armed run.
                        if model.phase != .check {
                            Picker("Mode", selection: $model.writeArmed) {
                                Text("Dry Run").tag(false)
                                Text("Write").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .disabled(!model.canArmWrites && !model.writeArmed)
                            .help(model.canArmWrites
                                    ? "Dry Run records a reviewable plan; Write applies the reviewed plan to selected repos"
                                    : "Write unlocks after a dry run produces a plan (and the script hasn't changed since)")
                        }

                        Button {
                            if model.writeArmed {
                                model.showApplySheet = true
                            } else {
                                model.run()
                            }
                        } label: {
                            Label(buttonTitle, systemImage: model.writeArmed ? "bolt.fill" : "play.fill")
                                .foregroundStyle(model.writeArmed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        }
                        .help(buttonHelp)
                        // Generation streams into the editor, so running
                        // mid-generation would execute a truncated script.
                        .disabled(model.scriptText.isEmpty || model.validating || model.generating
                                  || (model.writeArmed && !model.canArmWrites))
                    }
                }
            }

            EnvironmentFooter()
        }
        .sheet(isPresented: $model.showApplySheet) {
            ApplySheet()
        }
        .alert("Start a new job?", isPresented: $model.showNewJobConfirmation) {
            Button("Discard and Start New Job", role: .destructive) {
                model.startNewJob()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards the whole job — prompts, scripts, results, the reviewed plan, and the audit trail, in every phase. Settings and credentials are kept.")
        }
        .alert("This job still has open PRs or branches", isPresented: $model.showNewJobBlocked) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Starting a new job would abandon what this job created on the remote — the artifact registry is the only authority that can merge or cancel it. Merge the approved PRs or run the \"Cancel job\" recipe first.")
        }
        .alert("Save script as recipe", isPresented: $model.showSaveRecipePrompt) {
            TextField("Recipe name", text: $model.recipeNameDraft)
            Button("Save") { model.saveCurrentAsRecipe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the prompt, script, and phase to your recipe library (Application Support). Results and plans are not part of a recipe.")
        }
        .alert("Rename recipe", isPresented: renamingPresented, presenting: model.renamingRecipe) { recipe in
            TextField("Recipe name", text: $model.recipeNameDraft)
            Button("Rename") { model.renameRecipe(recipe) }
            Button("Cancel", role: .cancel) {}
        } message: { recipe in
            Text("Rename \"\(recipe.title)\".")
        }
        .alert("Delete recipe?", isPresented: deletingPresented, presenting: model.deletingRecipe) { recipe in
            Button("Delete \"\(recipe.title)\"", role: .destructive) {
                model.deleteRecipe(recipe)
            }
            Button("Cancel", role: .cancel) {}
        } message: { recipe in
            Text("\"\(recipe.title)\" is removed from your library. Scripts in the editor are not affected.")
        }
        .onChange(of: model.settings.useFixtureGitHub) {
            model.dataSourceChanged()
        }
    }

    private var renamingPresented: Binding<Bool> {
        Binding(
            get: { model.renamingRecipe != nil },
            set: { if !$0 { model.renamingRecipe = nil } }
        )
    }

    private var deletingPresented: Binding<Bool> {
        Binding(
            get: { model.deletingRecipe != nil },
            set: { if !$0 { model.deletingRecipe = nil } }
        )
    }

    private var buttonTitle: String {
        if model.writeArmed { return "Apply…" }
        return model.phase == .check ? "Run" : "Dry Run"
    }

    private var buttonHelp: String {
        if model.writeArmed {
            return "Apply the reviewed plan: choose repositories and confirm — this writes"
        }
        return model.phase == .check
            ? "Validate and run the script (check phase is read-only)"
            : "Run the script in dry-run mode — writes are recorded as a reviewable plan, nothing is written"
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
                Label("Writes go to: LIVE GITHUB — organisation \"\(model.settings.organisation)\". Branches and PRs will really be created.",
                      systemImage: "bolt.horizontal.circle.fill")
                    .font(.callout.weight(.semibold))
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
                .disabled(selected.isEmpty)
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
    /// Recipe groups are collapsible; open by default for discoverability.
    @State private var expandedGroups: Set<JobPhase> = Set(JobPhase.allCases)

    var body: some View {
        // Phase switching is locked while a run or generation is in flight —
        // swapping workspaces mid-action invites confusion (the run keeps
        // writing into the phase it started in).
        let busy = model.running || model.generating
        List(selection: phaseSelection) {
            Section("Job phases") {
                Label("Check", systemImage: "magnifyingglass")
                    .tag(JobPhase.check)
                    .help("Prompts generate read-only search scripts")
                    .selectionDisabled(busy)
                Label("Update", systemImage: "pencil")
                    .tag(JobPhase.update)
                    .help("Generate update scripts — dry run by default; arm writes via Apply")
                    .selectionDisabled(busy)
                Label("Merge", systemImage: "arrow.triangle.merge")
                    .tag(JobPhase.merge)
                    .help("Approve job PRs, then merge scripts act on this job's artifacts only")
                    .selectionDisabled(busy)
            }

            // The user's own recipes, saved from the workspace (File > Save
            // Script as Recipe…). Hidden until the first save.
            if !model.userRecipes.isEmpty {
                Section("Saved recipes") {
                    ForEach(model.userRecipes) { recipe in
                        Button {
                            model.loadRecipe(recipe.asRecipe)
                        } label: {
                            Label(recipe.title, systemImage: "bookmark")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .selectionDisabled()
                        .help("\(recipe.phase.rawValue) — \(recipe.prompt)")
                        .contextMenu {
                            Button("Rename…") {
                                model.recipeNameDraft = recipe.title
                                model.renamingRecipe = recipe
                            }
                            Button("Delete…", role: .destructive) {
                                model.deletingRecipe = recipe
                            }
                        }
                    }
                }
            }

            // The recipe LIBRARY is reference material, not navigation: it
            // lives under its own header, one collapsible group per phase,
            // with quieter styling so it doesn't compete with the workflow.
            Section("Recipe library") {
                ForEach(JobPhase.allCases, id: \.self) { phase in
                    let recipes = RecipeCatalog.all.filter { $0.phase == phase }
                    if !recipes.isEmpty {
                        DisclosureGroup(isExpanded: expansionBinding(for: phase)) {
                            ForEach(recipes) { recipe in
                                Button {
                                    model.loadRecipe(recipe)
                                } label: {
                                    Label(recipe.title, systemImage: recipe.systemImage)
                                        .font(.callout)
                                }
                                .buttonStyle(.plain)
                                .disabled(busy)
                                .selectionDisabled()
                                .help(recipe.prompt)
                            }
                        } label: {
                            Text(phase.rawValue.capitalized)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func expansionBinding(for phase: JobPhase) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(phase) },
            set: { isOpen in
                if isOpen { expandedGroups.insert(phase) } else { expandedGroups.remove(phase) }
            }
        )
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
