import SwiftUI
import BulkGitHubKit

struct MainView: View {
    @Environment(AppModel.self) private var model
    // Measured width of the middle workbench column, used to pin its panes.
    @State private var workbenchWidth: CGFloat = 0

    var body: some View {
        @Bindable var model = model
        // Plain VStack rather than a safeAreaInset overlay: the footer takes
        // its own space, so scrolling content (console, results) can never
        // hide its last line underneath it.
        VStack(spacing: 0) {
            if let pause = model.quotaPauseText {
                QuotaPauseBanner(text: pause, held: model.quotaPauseIsHeld,
                                 onResume: { model.resumeQuotaWait() })
            }
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
                    // The catalog's titles outgrew the original 210 ideal —
                    // give the library room to read at its default width.
                    .frame(minWidth: 170, idealWidth: 235, maxWidth: 300,
                           maxHeight: .infinity)
                // Split views measure children with unspecified proposals, so
                // a child with a wide ideal (the code editor's longest line)
                // can win the pane width and overflow-centre past both edges.
                // Pin every pane to the measured column width instead — but
                // measure it in a *background* GeometryReader, never by wrapping
                // the panes in one: a GeometryReader sinks the toolbar's top
                // safe-area inset on macOS 26's floating glass toolbar, dropping
                // ScriptPane's first row (the run-mode banner) underneath the
                // toolbar. As a direct child the VSplitView insets normally.
                VSplitView {
                    ScriptPane()
                        .frame(width: workbenchWidth > 0 ? workbenchWidth : nil)
                        .frame(minHeight: 240, maxHeight: .infinity)
                    ResultsPane()
                        .frame(width: workbenchWidth > 0 ? workbenchWidth : nil)
                        .frame(minHeight: 160, maxHeight: .infinity)
                    ConsolePane()
                        .frame(width: workbenchWidth > 0 ? workbenchWidth : nil)
                        .frame(minHeight: 80, idealHeight: 120, maxHeight: 240)
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.size.width, initial: true) { _, width in
                                workbenchWidth = width
                            }
                    }
                }
                .layoutPriority(1)
                // The detail pane holds the diffs — the actual work under
                // review — so it may open out wide at the workbench's expense.
                DetailPane()
                    .frame(minWidth: 320, idealWidth: 460, maxWidth: 760,
                           maxHeight: .infinity)
            }
            // HSplitView is not greedy — without this it collapses to its
            // children's minimum height inside the VStack.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("BulkGitHub")
            .toolbar {
                // The workflow's spine, centred in the title bar.
                ToolbarItem(placement: .principal) {
                    PhaseFlowControl()
                }
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
                        .disabled(completeNotApplicable
                                  || model.scriptText.isEmpty || model.validating || model.generating
                                  || (model.writeArmed && !model.canArmWrites)
                                  || (model.writeArmed && model.armTargets.isEmpty)
                                  || !model.prFieldsComplete)
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
            Button("Discard Job and Reset Registry", role: .destructive) {
                model.discardJobAndReset()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Starting a new job would abandon what this job created on the remote — the artifact registry is the only authority that can merge or cancel it. Merge the approved PRs or run the \"Cancel job\" recipe first.\n\nIf those paths can't recover this job, you can force a reset: it discards everything and ABANDONS tracking of any PR or branch still live on the remote (they stay on GitHub; this app can never touch them again). The audit trail keeps a record.")
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

    /// The Complete step finalizes the PRs an Update created. A job that opened
    /// none — e.g. a metadata-only update like custom properties, which applies
    /// directly at Update — has nothing to complete.
    private var completeNotApplicable: Bool {
        model.phase == .merge && model.mergeRows.isEmpty
    }

    private var buttonTitle: String {
        if completeNotApplicable { return "Nothing to Complete" }
        if model.writeArmed { return "Apply…" }
        return model.phase == .check ? "Run" : "Dry Run"
    }

    private var buttonHelp: String {
        if completeNotApplicable {
            return "This job created no pull requests to complete — metadata updates such as custom properties apply directly at the Update step."
        }
        if model.writeArmed {
            return "Apply the reviewed plan: choose repositories and confirm — this writes"
        }
        if !model.prFieldsComplete {
            return "Fill in the PR title and description above — they're required and become the title/body of every PR this job opens"
        }
        return model.phase == .check
            ? "Validate and run the script (the find phase is read-only)"
            : "Run the script in dry-run mode — writes are recorded as a reviewable plan, nothing is written"
    }
}

/// The arming flow: pick which planned repositories the reviewed plan is
/// applied to, see exactly where writes will go, confirm explicitly.
struct ApplySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var isMerge: Bool { model.phase == .merge }
    private var count: Int { model.armTargets.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Arm writes", systemImage: "bolt.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)

            Text(isMerge
                    ? "The reviewed plan re-runs with writes enabled, acting on the \(count) PR\(count == 1 ? "" : "s") in this job's registry. Only PRs you approved are acted on; a PR whose head moved since you approved it halts with nothing done."
                    : "The reviewed dry-run plan re-runs with writes enabled, for the \(count) repositor\(count == 1 ? "y" : "ies") you selected in the table. Every write must match the reviewed plan exactly; a repository that drifted since the dry run halts with nothing written.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.settings.useFixtureGitHub {
                Label("Writes go to: fixture data (offline test mode)", systemImage: "shippingbox")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Label(isMerge
                        ? "Writes go to: LIVE GITHUB — organisation \"\(model.settings.organisation)\". Approved PRs are acted on per the reviewed plan (e.g. squash-merged or closed) and job branches cleaned up."
                        : "Writes go to: LIVE GITHUB — organisation \"\(model.settings.organisation)\". Branches and PRs will really be created.",
                      systemImage: "bolt.horizontal.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive) {
                    let repos = model.armTargets
                    dismiss()
                    model.applyPlan(to: repos)
                } label: {
                    Label(isMerge
                            ? "Arm and apply to \(count) PR\(count == 1 ? "" : "s")"
                            : "Arm and apply to \(count) repo\(count == 1 ? "" : "s")",
                          systemImage: "bolt.fill")
                }
                .disabled(model.armTargets.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}

/// The workflow's spine in the title bar: Find ▸ Update ▸ Complete at standard
/// toolbar metrics. Chevron separators carry the direction (the
/// path-control idiom); only the ACTIVE stage wears a tinted capsule — bold
/// colour belongs in content, not chrome. Tints extend the app's existing
/// language: Find blue, Update purple in dry run and red the moment writes
/// are armed, Complete green. Each stage carries its product count.
struct PhaseFlowControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Phase switching is locked while a run or generation is in flight —
        // swapping workspaces mid-action invites confusion (the run keeps
        // writing into the phase it started in).
        let busy = model.running || model.generating
        HStack(spacing: 4) {
            stage(.check, label: "Find", systemImage: "magnifyingglass",
                  badge: model.matchedCount,
                  help: "Prompts generate read-only search scripts; matches feed Update (⌘1)")
            chevron
            stage(.update, label: "Update", systemImage: "pencil",
                  badge: model.plannedRepoCount,
                  help: "Update scripts dry-run into a reviewable plan; arm writes via Apply (⌘2)")
            chevron
            stage(.merge, label: "Complete", systemImage: "flag.checkered",
                  badge: model.registryPRCount,
                  help: "Approve job PRs, then the script acts on this job's artifacts only — merge or cancel (⌘3)")
        }
        // The principal toolbar slot compresses its item once the badges
        // appear, truncating the active stage's label — refuse compression;
        // the title bar has the room.
        .fixedSize()
        .disabled(busy)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func color(for phase: JobPhase) -> Color {
        switch phase {
        case .check: return .blue
        case .update: return (model.writeArmed || model.currentRunIsArmed) ? .red : .purple
        case .merge: return .green
        }
    }

    private func stage(_ phase: JobPhase, label: String, systemImage: String,
                       badge: Int, help: String) -> some View {
        let isCurrent = model.phase == phase
        let tint = color(for: phase)
        return Button {
            model.setPhase(phase)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                Text(label)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    // Refuse truncation: the principal toolbar slot can hand the
                    // label a narrow proposal once the count badge claims width,
                    // clipping it to "Find 2…". Pin the label to its full width.
                    .fixedSize(horizontal: true, vertical: false)
                // Render the badge slot unconditionally and just hide the count
                // until it exists — the pill is then sized for "label + count"
                // from the start, so room for the suffix is reserved before the
                // operation completes and the geometry doesn't jump when it does.
                Text("\(badge)")
                    .font(.caption2.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 0.5)
                    .background((isCurrent ? tint : Color.secondary).opacity(0.16),
                                in: Capsule())
                    .foregroundStyle(isCurrent ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                    .opacity(badge > 0 ? 1 : 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(isCurrent ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(.clear),
                        in: Capsule())
            .overlay(
                Capsule().strokeBorder(tint.opacity(isCurrent ? 0.6 : 0), lineWidth: 1)
            )
            .foregroundStyle(isCurrent ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Recipe groups are collapsible; open by default for discoverability.
    @State private var expandedGroups: Set<JobPhase> = Set(JobPhase.allCases)

    var body: some View {
        let busy = model.running || model.generating
        List {
            // The recipe LIBRARY is reference material, not navigation: it
            // lives under its own header, one collapsible group per phase,
            // with quieter styling so it doesn't compete with the workflow.
            // Bundled and user-saved recipes share the groups — a recipe is
            // a recipe; only rename/delete (context menu) is saved-only.
            Section("Recipe library") {
                if model.recipes.isEmpty && model.recipesLoading {
                    Label("Loading recipes…", systemImage: "hourglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(JobPhase.allCases, id: \.self) { phase in
                    let bundled = model.recipes.filter { $0.phase == phase && $0.origin == .bundled }
                    let saved = model.userRecipes.filter { $0.phase == phase }
                    if !bundled.isEmpty || !saved.isEmpty {
                        DisclosureGroup(isExpanded: expansionBinding(for: phase)) {
                            ForEach(bundled) { recipe in
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
                                .contextMenu {
                                    Button("Export…") { exportRecipeViaPanel(recipe, model) }
                                }
                            }
                            ForEach(saved) { recipe in
                                Button {
                                    model.loadRecipe(recipe)
                                } label: {
                                    Label(recipe.title, systemImage: "bookmark")
                                        .font(.callout)
                                }
                                .buttonStyle(.plain)
                                .disabled(busy)
                                .selectionDisabled()
                                .help(recipe.prompt)
                                .contextMenu {
                                    Button("Rename…") {
                                        model.recipeNameDraft = recipe.title
                                        model.renamingRecipe = recipe
                                    }
                                    Button("Export…") { exportRecipeViaPanel(recipe, model) }
                                    Divider()
                                    Button("Delete…", role: .destructive) {
                                        model.deletingRecipe = recipe
                                    }
                                }
                            }
                        } label: {
                            Text(phase.displayName)
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

}

/// Ambient environment status — deliberately out of the sidebar so it doesn't
/// compete with the workflow; lives in a quiet footer across the window.
/// A run-halting banner shown while the quota gate has paused the run: the
/// countdown/held message, plus a manual Resume. Stop stays in the toolbar.
struct QuotaPauseBanner: View {
    let text: String
    let held: Bool
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: held ? "exclamationmark.triangle.fill" : "pause.circle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Resume now", action: onResume)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(held ? 0.20 : 0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

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
                Label(model.quotaResetText.map { "\(quota) · \($0)" } ?? quota,
                      systemImage: "gauge.with.needle")
                    .foregroundStyle(model.quotaResetText == nil ? Color.primary : .orange)
                    .help(model.quotaResetText.map { "GitHub API quota exhausted — \($0)" }
                          ?? "GitHub API quota remaining")
            }
            if let retry = model.retryText {
                Label(retry, systemImage: "arrow.clockwise")
                    .foregroundStyle(.orange)
                    .help("Retrying a transient GitHub error — the run is grinding through it, not hung")
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
