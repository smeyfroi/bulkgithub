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
            // found-by-Check → planned-by-Update; the merge table is the
            // approval queue over the job's PR artifacts.
            switch model.phase {
            case .update:
                updateTable
            case .merge:
                mergeTable
            case .check:
                checkTable
            }
        }
    }

    @ViewBuilder
    private var mergeTable: some View {
        @Bindable var model = model
        if model.mergeRows.isEmpty {
            ContentUnavailableView(
                "No job pull requests",
                systemImage: "arrow.triangle.pull",
                description: Text("Apply an update plan first — the PRs it creates appear here for approval and merging.")
            )
        } else {
            let approvedCount = model.mergeRows.filter(\.approved).count
            HStack(spacing: 12) {
                Text("\(approvedCount) of \(model.mergeRows.count) approved")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Approve all") { model.approveAll() }
                    .controlSize(.small)
                    .disabled(model.running || approvedCount == model.mergeRows.count)
                Button("Clear approvals") { model.clearApprovals() }
                    .controlSize(.small)
                    .disabled(model.running || approvedCount == 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) { Divider() }

            Table(model.mergeRows, selection: $model.selectedRepo) {
                TableColumn("Approved") { (row: AppModel.MergeRow) in
                    Toggle("", isOn: Binding(
                        get: { row.approved },
                        set: { _ in model.toggleApproval(repo: row.artifact.repo, prNumber: row.number) }
                    ))
                    .labelsHidden()
                    .help(row.approved
                            ? "Approved — merging requires the head to still match the approved SHA"
                            : "Approve this PR for merging (captures the current head SHA)")
                    .disabled(model.running)
                }
                .width(min: 55, ideal: 60, max: 70)

                TableColumn("Merge") { (row: AppModel.MergeRow) in
                    if let result = row.result {
                        StatusBadge(status: result.status)
                    } else {
                        Text("—")
                            .foregroundStyle(.tertiary)
                            .help("No merge run yet")
                    }
                }
                .width(min: 80, ideal: 95, max: 130)

                TableColumn("Repository") { (row: AppModel.MergeRow) in
                    RepoCell(repo: row.repo)
                }
                .width(min: 140, ideal: 210)

                TableColumn("PR") { (row: AppModel.MergeRow) in
                    if let url = row.artifact.url, let link = URL(string: url) {
                        Link(row.artifact.name, destination: link)
                    } else {
                        Text(row.artifact.name)
                    }
                }
                .width(min: 45, ideal: 60, max: 90)

                TableColumn("Detail") { (row: AppModel.MergeRow) in
                    if let result = row.result {
                        DetailCell(result: result)
                    }
                }
            }
        }
    }

    private var checkTable: some View {
        @Bindable var model = model
        return Table(model.results, selection: $model.selectedRepo) {
            TableColumn("Status") { (result: RepoResult) in
                StatusBadge(status: result.status)
            }
            .width(min: 80, ideal: 95, max: 130)

            TableColumn("Repository") { (result: RepoResult) in
                RepoCell(repo: result.repo, isCanary: model.canaryRepo == result.id)
            }
            .width(min: 140, ideal: 210)

            TableColumn("Branch") { (result: RepoResult) in
                Text(result.repo.defaultBranch)
                    .foregroundStyle(.secondary)
            }
            .width(min: 45, ideal: 60, max: 90)

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
            .width(min: 80, ideal: 95, max: 130)

            TableColumn("Update") { (row: AppModel.UpdateRow) in
                if let update = row.update {
                    StatusBadge(status: update.status)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                        .help("No update run yet for this repo")
                }
            }
            .width(min: 80, ideal: 95, max: 130)

            TableColumn("Repository") { (row: AppModel.UpdateRow) in
                RepoCell(repo: row.repo, isCanary: model.canaryRepo == row.id)
            }
            .width(min: 140, ideal: 210)

            TableColumn("Branch") { (row: AppModel.UpdateRow) in
                Text(row.repo.defaultBranch)
                    .foregroundStyle(.secondary)
            }
            .width(min: 45, ideal: 60, max: 90)

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
            Text(model.staleReason ?? "")
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

/// The bottom pane: the last run's log, and the job's full audit trail —
/// every API call and write across all runs, run boundaries marked.
struct ConsolePane: View {
    @Environment(AppModel.self) private var model
    @State private var showAudit = false
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Quiet, Xcode-style pane tabs — this is pane furniture, not
                // a control that deserves accent colour.
                HStack(spacing: 2) {
                    PaneTab(title: "Log", isOn: !showAudit) { showAudit = false }
                    PaneTab(title: "Audit", isOn: showAudit) { showAudit = true }
                }
                if showAudit {
                    TextField("Filter by kind, repo, or text…", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.caption)
                        .frame(maxWidth: 220)
                    Text("\(filteredAudit.count) event(s)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(alignment: .bottom) { Divider() }

            if showAudit {
                auditList
            } else {
                logList
            }
        }
    }

    private var logList: some View {
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

    private var filteredAudit: [AuditEvent] {
        guard !filter.isEmpty else { return model.auditTrail }
        let needle = filter.lowercased()
        return model.auditTrail.filter {
            $0.kind.lowercased().contains(needle)
                || ($0.repo?.lowercased().contains(needle) ?? false)
                || $0.detail.lowercased().contains(needle)
        }
    }

    private var auditList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredAudit) { event in
                        AuditRow(event: event)
                            .id(event.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(.black.opacity(0.04))
            .onAppear {
                if let last = filteredAudit.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: model.auditTrail.count) {
                if let last = filteredAudit.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

/// A quiet text tab for switching pane content (Log / Audit).
struct PaneTab: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(isOn ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

struct AuditRow: View {
    let event: AuditEvent

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.time.string(from: event.timestamp))
                .foregroundStyle(.tertiary)
            Text(event.kind)
                .fontWeight(event.kind == "run" || event.kind.hasPrefix("write.") ? .bold : .regular)
                .foregroundStyle(kindColor)
                .frame(minWidth: 110, alignment: .leading)
            if let repo = event.repo {
                Text(repo)
                    .foregroundStyle(.primary)
            }
            Text(event.detail)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .padding(.vertical, event.kind == "run" ? 3 : 0)
        .background(event.kind == "run" ? Color.primary.opacity(0.05) : .clear)
    }

    private var kindColor: Color {
        if event.kind == "run" { return .primary }
        if event.kind.hasPrefix("write.") { return .red }
        if event.kind.hasPrefix("plan.") { return .purple }
        if event.kind.hasPrefix("job.") { return .blue }
        return .secondary
    }
}
