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

                    if let actions = model.plannedActions[result.id], !actions.isEmpty {
                        PlanView(actions: actions)
                    }

                    ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, evidence in
                        EvidenceView(evidence: evidence, repo: result.repo,
                                     webHost: model.settings.webHost)
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
            case .createPR(_, _, let body):
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            case .createBranch:
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

            ScrollView(.horizontal) {
                Text(evidence.excerpt)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}
