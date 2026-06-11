import SwiftUI
import BulkGitHubKit

struct ResultsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.resultsAreStale {
                StaleResultsBanner()
            }
            // Per-mode tables: the update table keeps the check verdict
            // visible next to the update status so the funnel reads
            // found-by-Check → planned-by-Update.
            if model.phase == .update {
                updateTable
            } else {
                checkTable
            }
        }
    }

    private var checkTable: some View {
        @Bindable var model = model
        return Table(model.results, selection: $model.selectedRepo) {
            TableColumn("Status") { (result: RepoResult) in
                StatusBadge(status: result.status)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Repository") { (result: RepoResult) in
                RepoCell(repo: result.repo)
            }

            TableColumn("Branch") { (result: RepoResult) in
                Text(result.repo.defaultBranch)
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)

            TableColumn("Detail") { (result: RepoResult) in
                DetailCell(result: result)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        }
    }

    private var updateTable: some View {
        @Bindable var model = model
        return Table(model.updateRows, selection: $model.selectedRepo) {
            TableColumn("Check") { (row: AppModel.UpdateRow) in
                if let check = row.check {
                    StatusBadge(status: check.status)
                        .opacity(0.6)
                        .help("Verdict from the last check run")
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 90, ideal: 110)

            TableColumn("Update") { (row: AppModel.UpdateRow) in
                if let update = row.update {
                    StatusBadge(status: update.status)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                        .help("No update run yet for this repo")
                }
            }
            .width(min: 90, ideal: 110)

            TableColumn("Repository") { (row: AppModel.UpdateRow) in
                RepoCell(repo: row.repo, isCanary: model.canaryRepo == row.id)
            }

            TableColumn("Branch") { (row: AppModel.UpdateRow) in
                Text(row.repo.defaultBranch)
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)

            TableColumn("Detail") { (row: AppModel.UpdateRow) in
                if let result = row.update ?? row.check {
                    DetailCell(result: result)
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        if let id = ids.first {
            Button("Use \"\(id)\" as canary target") {
                model.useAsCanary(id)
            }
        }
    }
}

struct RepoCell: View {
    let repo: RepoRef
    var isCanary = false

    var body: some View {
        HStack(spacing: 4) {
            if isCanary {
                Image(systemName: "scope")
                    .foregroundStyle(.purple)
                    .help("Canary target — update runs touch only this repo")
            }
            Text(repo.fullName)
            if repo.archived {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                    .help("Archived")
            }
            if !repo.isPrivate {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .help("Public")
            }
        }
    }
}

struct DetailCell: View {
    let result: RepoResult

    var body: some View {
        Text(detailText)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var detailText: String {
        if let reason = result.reason, !reason.isEmpty { return reason }
        if !result.evidence.isEmpty {
            return result.evidence.map(\.path).joined(separator: ", ")
        }
        return ""
    }
}

/// Shown when the editor script no longer matches the script that produced
/// the visible results — they stay (a live run costs quota) but are flagged.
struct StaleResultsBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("The script has changed since these results were produced — Run to refresh.")
                .font(.callout)
            Spacer()
            Button("Clear results") { model.clearResults() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct StatusBadge: View {
    let status: RepoStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .verifiedMatch, .merged, .approved: return .green
        case .candidate: return .blue
        case .skipped, .alreadyUpToDate: return .orange
        case .failed, .blocked, .conflicted: return .red
        case .cancelled, .noMatch: return .gray
        case .planned, .branchExists, .prExists, .prRaised: return .purple
        }
    }
}

struct ConsolePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("▸") ? .primary : .secondary)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(.black.opacity(0.04))
            .onChange(of: model.logs.count) {
                if let last = model.logs.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}
