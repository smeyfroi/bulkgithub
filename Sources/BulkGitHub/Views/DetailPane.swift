import AppKit
import SwiftUI
import BulkGitHubKit

struct DetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let result = model.selectedResult {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.repo.fullName)
                            .font(.headline)
                        HStack(spacing: 8) {
                            StatusBadge(status: result.status)
                            if let reason = result.reason {
                                Text(reason)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button {
                        open("\(model.settings.webHost)/\(result.repo.fullName)")
                    } label: {
                        Label("Open repository on GitHub", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.link)

                    if model.canaryRepo == result.id {
                        HStack(spacing: 8) {
                            Label("Canary target — update runs touch only this repo",
                                  systemImage: "scope")
                                .font(.callout)
                                .foregroundStyle(.purple)
                            Button("Clear") { model.canaryRepo = "" }
                                .controlSize(.small)
                        }
                    } else if model.phase != .merge, !model.running,
                              !model.artifacts.contains(where: {
                                  $0.repo == result.id && $0.kind == .pullRequest
                              }) {
                        // Only offer the dry-run-this-repo affordance when it
                        // means something: not mid-run (the live run is already
                        // acting), and not once this repo has a raised PR.
                        Button {
                            model.useAsCanary(result.id)
                        } label: {
                            Label("Dry-run the update on just this repo",
                                  systemImage: "scope")
                        }
                        .controlSize(.small)
                        .help("Sets this repo as the canary target and switches to the update phase")
                    }

                    // The artifact registry for this repo: what armed runs
                    // actually created. Merge/cancel operates only on these.
                    let repoArtifacts = model.artifacts.filter { $0.repo == result.id }
                    if !repoArtifacts.isEmpty {
                        ArtifactsView(artifacts: repoArtifacts)
                    }

                    // Merge phase: the receipts behind this PR — the reviewed
                    // diffs as actually applied — so approval doesn't require
                    // jumping back to the Update screen (or to GitHub).
                    if model.phase == .merge,
                       let applied = model.appliedPlan[result.id], !applied.isEmpty {
                        AppliedChangesView(actions: applied)
                    }

                    // Plan or evidence, never both: once actions are planned,
                    // their diffs are the authoritative "what changes" — the
                    // match evidence below them just read as a second, confusing
                    // set of diffs. Evidence remains the detail for check
                    // results and for update repos with nothing planned.
                    if model.phase != .check,
                       let actions = model.activePlan[result.id], !actions.isEmpty {
                        PlanView(actions: actions,
                                 status: result.status,
                                 runIsArmed: model.currentRunIsArmed)
                    } else {
                        ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, evidence in
                            EvidenceView(evidence: evidence, repo: result.repo,
                                         webHost: model.settings.webHost)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else {
            ContentUnavailableView(
                "No repository selected",
                systemImage: "square.dashed",
                description: Text("Run a find script, then select a repository to inspect its evidence.")
            )
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// What armed runs created on the remote for this repository — branches and
/// PRs the job holds receipts for.
struct ArtifactsView: View {
    let artifacts: [Artifact]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Created by armed runs", systemImage: "bolt.fill")
                .font(.headline)
                .foregroundStyle(.red)

            ForEach(artifacts) { artifact in
                HStack(spacing: 6) {
                    Image(systemName: artifact.kind == .branch
                            ? "arrow.triangle.branch" : "arrow.triangle.pull")
                        .foregroundStyle(.secondary)
                    Text("\(artifact.kind.rawValue) \(artifact.name)")
                        .font(.callout)
                    Spacer()
                    if let url = artifact.url, let link = URL(string: url) {
                        Link(destination: link) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .help(url)
                    }
                }
            }
        }
        .padding(10)
        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// What this job's PR changes in the repository: the reviewed plan as it was
/// actually applied — content diffs only, for approval review in the merge
/// phase.
struct AppliedChangesView: View {
    let actions: [PlannedAction]

    private var edits: [PlannedAction] {
        actions.filter {
            switch $0 {
            case .putContent, .deleteFile: return true
            default: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What this PR changes", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
                .foregroundStyle(.blue)

            ForEach(Array(edits.enumerated()), id: \.offset) { _, action in
                PlannedActionView(action: action)
            }
        }
        .padding(10)
        .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// What one repository's reviewed plan shows: the recorded writes with native
/// before/after diffs. Purple "dry run" while nothing has executed; flips to
/// red "Applying…/Applied" once a Write run is armed or the row has reached a
/// write outcome — the plan survives an armed run (it is the reference the
/// engine checked the writes against), so the header must not keep claiming
/// "nothing executed" against a repo whose PR was raised.
struct PlanView: View {
    let actions: [PlannedAction]
    /// The current status of the repo this plan belongs to — drives whether
    /// the plan reads as a dry run or as applied writes.
    let status: RepoStatus
    /// True while THIS run is armed (writes in flight), from model.currentRunIsArmed.
    let runIsArmed: Bool

    /// The plan has been (or is being) applied: an armed run is live, or the
    /// row has already reached a write outcome.
    private var isApplying: Bool {
        runIsArmed || [.prRaised, .merged, .cancelled, .conflicted, .blocked].contains(status)
    }

    private var headerText: String {
        guard isApplying else { return "Execution plan — dry run, nothing executed" }
        return runIsArmed ? "Applying the reviewed plan…" : "Applied — what this PR changed"
    }

    private var tint: Color { isApplying ? .red : .purple }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(headerText,
                  systemImage: isApplying ? "bolt.fill" : "list.bullet.clipboard")
                .font(.headline)
                .foregroundStyle(tint)

            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                PlannedActionView(action: action)
            }
        }
        .padding(10)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PlannedActionView: View {
    @Environment(AppModel.self) private var model
    let action: PlannedAction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(action.summary, systemImage: icon)
                .font(.callout.weight(.medium))

            switch action {
            case .putContent(_, _, _, let before, let after):
                // Provenance: content that is byte-identical to an attached
                // local file gets named — the reviewer should know these
                // bytes came from outside the repo.
                if let attachment = model.fileAttachmentLabel(forPlannedContent: after) {
                    Label(attachment, systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DiffView(lines: DiffBuilder.lines(before: before ?? "", after: after))
            case .deleteFile(_, _, _, let before):
                // A deletion is the file's content going to nothing — every
                // line shows as removed.
                DiffView(lines: DiffBuilder.lines(before: before ?? "", after: ""))
            case .createPR(_, _, let body) where !body.isEmpty:
                // The PR description this action will open, shown verbatim so
                // the review pane is faithful to exactly what gets posted —
                // markdown rendering only handles inline syntax and would
                // mangle multi-line block structure (headings, lists, code).
                Text(verbatim: body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .editPR(_, let body) where !body.isEmpty:
                // The new PR body this edit will post, shown verbatim.
                Text(verbatim: body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            default:
                // The summary line is enough for the rest — putContent diffs
                // above already show what a PR will contain, and merge-phase
                // actions are fully described by their summaries.
                EmptyView()
            }
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var icon: String {
        switch action {
        case .createBranch: return "arrow.triangle.branch"
        case .putContent: return "pencil.line"
        case .deleteFile: return "trash"
        case .createPR: return "arrow.triangle.pull"
        case .setProperties: return "tag"
        case .mergePR: return "arrow.triangle.merge"
        case .closePR: return "xmark.circle"
        case .editPR: return "pencil"
        case .deleteBranch: return "trash"
        }
    }
}

struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(spacing: 6) {
                        Text(marker(for: line.kind))
                            .foregroundStyle(color(for: line.kind))
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.kind == .context ? .secondary : .primary)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(background(for: line.kind))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .textSelection(.enabled)
    }

    private func marker(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .context: return " "
        case .removed: return "-"
        case .added: return "+"
        }
    }

    private func color(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .context: return .secondary
        case .removed: return .red
        case .added: return .green
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .context: return .clear
        case .removed: return .red.opacity(0.12)
        case .added: return .green.opacity(0.12)
        }
    }
}

struct EvidenceView: View {
    let evidence: Evidence
    let repo: RepoRef
    let webHost: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(evidence.path, systemImage: "doc.text")
                    .font(.system(.callout, design: .monospaced))
                Spacer()
                Button {
                    let url = "\(webHost)/\(repo.fullName)/blob/\(repo.defaultBranch)/\(evidence.path)"
                    if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .help("Open file on GitHub")
            }

            if let explanation = evidence.explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            // The host located the match against the real file at reportMatch
            // time and recorded which lines to highlight; the view just renders
            // them. Falls back to the script's excerpt when the host had no
            // cached content to anchor in, so the pane is never blank.
            if evidence.noSpecificLine == true {
                Text("No specific line to highlight — this match is described above.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(contextLines(evidence.context ?? evidence.excerpt), id: \.number) { line in
                        HStack(spacing: 8) {
                            Text(String(line.number))
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 28, alignment: .trailing)
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(line.isMatch ? .primary : .secondary)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(line.isMatch ? Color.yellow.opacity(0.18) : .clear)
                    }
                }
                .padding(.vertical, 4)
                .textSelection(.enabled)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private struct ContextLine {
        let number: Int
        let text: String
        let isMatch: Bool
    }

    // The host decided which lines are the match (against the real file) and
    // recorded their absolute numbers; this is a pure integer-membership
    // render with no string matching and no silent degradation.
    private func contextLines(_ context: String) -> [ContextLine] {
        let start = evidence.contextStartLine ?? 1
        let matchSet = Set(evidence.matchLines ?? [])
        return context.components(separatedBy: "\n").enumerated().map { offset, text in
            let number = start + offset
            return ContextLine(number: number, text: text, isMatch: matchSet.contains(number))
        }
    }
}
