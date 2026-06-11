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
                    } else if model.phase != .merge {
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
                    // actually created. Merge/cancel in later phases operate
                    // only on these.
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
                        PlanView(actions: actions)
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
                description: Text("Run a check, then select a repository to inspect its evidence.")
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
            if case .putContent = $0 { return true }
            return false
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

/// Dry-run execution plan for one repository: the recorded writes, with
/// native before/after diffs for content changes. Nothing here has executed.
struct PlanView: View {
    let actions: [PlannedAction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Execution plan — dry run, nothing executed",
                  systemImage: "list.bullet.clipboard")
                .font(.headline)
                .foregroundStyle(.purple)

            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                PlannedActionView(action: action)
            }
        }
        .padding(10)
        .background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PlannedActionView: View {
    let action: PlannedAction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(action.summary, systemImage: icon)
                .font(.callout.weight(.medium))

            switch action {
            case .putContent(_, _, _, let before, let after):
                DiffView(lines: DiffBuilder.lines(before: before ?? "", after: after))
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
        case .createPR: return "arrow.triangle.pull"
        case .mergePR: return "arrow.triangle.merge"
        case .closePR: return "xmark.circle"
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

            // Context captured by the host at reportMatch time: the match in
            // situ with line numbers, not just the excerpt the script passed.
            if let context = evidence.context {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(contextLines(context), id: \.number) { line in
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
            } else {
                ScrollView(.horizontal) {
                    Text(evidence.excerpt)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private struct ContextLine {
        let number: Int
        let text: String
        let isMatch: Bool
    }

    private func contextLines(_ context: String) -> [ContextLine] {
        let matchLines = Set(evidence.excerpt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) })
        let start = evidence.contextStartLine ?? 1
        return context.components(separatedBy: "\n").enumerated().map { offset, text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return ContextLine(number: start + offset,
                               text: text,
                               isMatch: !trimmed.isEmpty && matchLines.contains(trimmed))
        }
    }
}
