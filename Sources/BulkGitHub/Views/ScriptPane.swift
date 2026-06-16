import SwiftUI
import CodeEditor
import BulkGitHubKit

struct ScriptPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            if model.phase != .check {
                WriteModeBanner()
            }
            // The prompt is the user's words — what they recognise the job
            // by — so it gets visual primacy over the generated code, and an
            // unmistakable "this goes to the AI" treatment: sparkles and a
            // soft gradient border, with room to breathe.
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15))
                        .foregroundStyle(LinearGradient(colors: [.purple, .blue],
                                                        startPoint: .top, endPoint: .bottom))
                    TextField(promptPlaceholder,
                              text: $model.prompt, axis: .vertical)
                        .lineLimit(2...6)
                        // The ranged lineLimit grows with content but does
                        // not reserve height — guarantee room for two full
                        // lines so a two-line prompt never scrolls.
                        .frame(minHeight: 40, alignment: .leading)
                        .font(.system(size: 15))
                        .textFieldStyle(.plain)
                        .focusEffectDisabled()
                        .onSubmit { model.generate() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(LinearGradient(colors: [.purple.opacity(0.55), .blue.opacity(0.45)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 1.5)
                )
                Button(model.generating ? "Generating…" : "Generate") {
                    model.generate()
                }
                .controlSize(.large)
                .disabled(model.generating || model.running || model.prompt.isEmpty)
            }
            .padding([.top, .horizontal], 10)

            if model.phase == .update {
                PullRequestFields()
                    .padding(.horizontal, 10)
                CanaryScopeBar()
                    .padding(.horizontal, 10)
            }

            CodeEditor(source: $model.scriptText,
                       language: .typescript,
                       theme: colorScheme == .dark ? .atelierSavannaDark : .atelierSavannaLight,
                       inset: CGSize(width: 8, height: 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 10)

            if !model.visibleParamKeys.isEmpty {
                ParamsBar()
                    .padding(.horizontal, 10)
            }

            if !model.diagnostics.isEmpty {
                DiagnosticsList()
                    .frame(maxHeight: 110)
                    .padding(.horizontal, 10)
            }

            HStack {
                // Determinate meter whenever the run has a known denominator
                // (scan via candidate rows; Update/Merge via the worked set) —
                // otherwise the indeterminate spinner. model.runProgress owns
                // the per-phase logic; here it's just processed-of-total.
                if let progress = model.runProgress {
                    ProgressView(value: Double(progress.processed), total: Double(progress.total))
                        .controlSize(.small)
                        .frame(width: 130)
                    Text("\(progressVerb) \(progress.processed) of \(progress.total)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    if model.running || model.validating || model.generating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.statusLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Text("\(model.visibleRowCount) repos")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding([.horizontal, .bottom], 10)
        }
    }

    private var promptPlaceholder: String {
        switch model.phase {
        case .check: return "Describe what to find across the organisation…"
        case .update: return "Describe the change to make across matching repos…"
        case .merge: return "Describe the merge or cancel action for this job's PRs…"
        }
    }

    /// Leading word for the progress meter: a scan "Scanned" repos; an
    /// update/merge run "Processed" them.
    private var progressVerb: String {
        model.runHadCandidates ? "Scanned" : "Processed"
    }
}

/// Reflects the user-set run mode (the Dry Run / Write toggle) — a real mode,
/// not an implication of which button exists. Purple for dry run, red the
/// moment Write is selected, louder still while an armed run executes.
struct WriteModeBanner: View {
    @Environment(AppModel.self) private var model

    private var target: String {
        model.settings.useFixtureGitHub ? "fixture data" : "LIVE GitHub (org \(model.settings.organisation))"
    }

    var body: some View {
        HStack(spacing: 8) {
            if model.currentRunIsArmed {
                Image(systemName: "bolt.fill")
                Text("WRITING — the reviewed plan is being applied to \(target)")
                    .fontWeight(.semibold)
            } else if model.writeArmed {
                Image(systemName: "bolt.fill")
                Text("WRITE MODE — \"Apply…\" runs the reviewed plan against \(target) for the repos you select")
                    .fontWeight(.semibold)
            } else {
                Image(systemName: "shield.lefthalf.filled")
                Text(model.settings.useFixtureGitHub
                        ? "DRY RUN — writes are recorded as a reviewable plan; nothing reaches GitHub"
                        : "DRY RUN — writes are recorded as a reviewable plan; reads come from live GitHub, nothing is written")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(isWrite ? Color.red : Color.purple)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background((isWrite ? Color.red : Color.purple).opacity(isWrite ? 0.14 : 0.10))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var isWrite: Bool { model.writeArmed || model.currentRunIsArmed }
}

/// Editable parameters surfaced from the script's meta.params — tweak a job
/// without re-prompting or editing code. A wrapping grid of labelled fields:
/// nothing crops off-screen, however many params a script declares.
///
/// The mechanism is stated in the header (these are runtime inputs the
/// script reads as job.params; the source keeps its declared defaults), and
/// an edited value is visibly marked, with the script's own default a click
/// away — so "does editing this do anything?" never needs guessing.
struct ParamsBar: View {
    @Environment(AppModel.self) private var model

    /// meta.params keys that are git/PR structure rather than recipe logic.
    /// They're grouped apart from the search/replace params because they're
    /// "special" — the job branch and commit message, always present in
    /// generated update scripts and structural rather than job-specific.
    static let gitParamKeys: Set<String> = ["branch", "message", "commitMessage"]

    var body: some View {
        let gitKeys = model.visibleParamKeys.filter { Self.gitParamKeys.contains($0) }
        let otherKeys = model.visibleParamKeys.filter { !Self.gitParamKeys.contains($0) }
        VStack(alignment: .leading, spacing: 8) {
            if !otherKeys.isEmpty {
                paramGroup(title: "Parameters", systemImage: "slider.horizontal.3",
                           caption: "override the script's meta.params defaults on the next run (the script reads job.params; the source is untouched)",
                           keys: otherKeys)
            }
            if !gitKeys.isEmpty {
                paramGroup(title: "Branch & commit", systemImage: "arrow.triangle.branch",
                           caption: "the job branch and commit message this run will use",
                           keys: gitKeys)
            }
        }
    }

    private func paramGroup(title: String, systemImage: String,
                            caption: String, keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("— \(caption)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .help("The script declares names and defaults in meta.params and reads the effective values from job.params at run time. Edits here apply to the next run without changing the script source — changed values are marked and can be reset to the script's default.")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 380),
                                         spacing: 8, alignment: .topLeading)],
                      alignment: .leading, spacing: 8) {
                ForEach(keys, id: \.self) { key in
                    paramField(key)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func paramField(_ key: String) -> some View {
        let edited = isEdited(key)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(key)
                    .font(.caption2)
                    .foregroundStyle(edited ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fontWeight(edited ? .semibold : .regular)
                if edited {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button {
                        model.paramsDraft[key] = model.declaredDefault(for: key)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to the script's default: \(model.declaredDefault(for: key) ?? "")")
                }
            }
            TextField(key, text: binding(for: key))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
        }
    }

    /// Edited = differs from the script's declared default. Unknown defaults
    /// (script not validated since it changed) are never marked.
    private func isEdited(_ key: String) -> Bool {
        guard let declared = model.declaredDefault(for: key) else { return false }
        return (model.paramsDraft[key] ?? "") != declared
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { model.paramsDraft[key] ?? "" },
            set: { model.paramsDraft[key] = $0 }
        )
    }
}

/// The pull-request title and description for an update job. These are the
/// user's authored words on the PRs the run will open, so they get a labelled
/// card of their own — visually distinct from the param grid — instead of
/// reading as two more anonymous params. Empty = autogenerated (the generator
/// fills them, mirrored back into these fields after Generate).
struct PullRequestFields: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Pull request", systemImage: "text.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("— title and description for the PRs this job opens (left empty, both are autogenerated)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            TextField("PR title", text: $model.prTitle)
                .textFieldStyle(.roundedBorder)
                .font(.body)
            TextField("PR description", text: $model.prBody, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Run scope for the dry run: confine update runs to a single canary repo so
/// one repo can be exercised before the rest. The canary is also set from a
/// results row (right-click) or the detail pane button, so this bar is a
/// status-plus-shortcut, never the only way in: when set it shows the target
/// as a removable token; when unset it offers a compact field that reads as a
/// scope control, not a dead button.
struct CanaryScopeBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let canary = model.canaryRepo.trimmingCharacters(in: .whitespaces)
        HStack(spacing: 8) {
            Label("Run scope", systemImage: "scope")
                .font(.caption)
                .foregroundStyle(.secondary)
            if canary.isEmpty {
                TextField("Whole match — type a repo to dry-run just one first",
                          text: $model.canaryRepo)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .frame(maxWidth: 320)
                    .help("owner/name or bare repo name; you can also right-click a results row, or use the repo's detail pane, to set the canary")
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                    Text("Confined to \(canary)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        model.canaryRepo = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Clear the canary — runs touch every matching repo again")
                }
                .font(.callout)
                .foregroundStyle(.purple)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.purple.opacity(0.10), in: Capsule())
            }
            Spacer()
        }
    }
}

struct DiagnosticsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.diagnostics) { diagnostic in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: icon(for: diagnostic.severity))
                            .foregroundStyle(color(for: diagnostic.severity))
                            .font(.caption)
                        if diagnostic.line > 0 {
                            Text("\(diagnostic.line):\(diagnostic.column)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(diagnostic.message)
                            .font(.caption)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func icon(for severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(for severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}
