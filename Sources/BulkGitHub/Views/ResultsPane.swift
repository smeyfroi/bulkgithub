import SwiftUI
import BulkGitHubKit

/// Row visibility filter for the results tables — lets a big funnel collapse
/// to just what matters. `actionable` = matched (Find) / planned (Update);
/// `selected` = checked to apply (Update, Write mode).
enum RowFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case actionable = "Actionable"
    case selected = "Selected"
    var id: String { rawValue }
}

struct ResultsPane: View {
    @Environment(AppModel.self) private var model
    /// View-local: which rows the tables show. Reset on phase change so a
    /// filter that only makes sense in one phase doesn't leak into another.
    @State private var rowFilter: RowFilter = .all

    // Column sort order, one per table. Defaults to repository name ascending;
    // clicking a header re-sorts. Kept per-table so a phase switch preserves
    // each table's choice.
    @State private var checkSort = [KeyPathComparator(\RepoResult.repo.fullName)]
    @State private var updateSort = [KeyPathComparator(\AppModel.UpdateRow.repo.fullName)]
    @State private var mergeSort = [KeyPathComparator(\AppModel.MergeRow.repo.fullName)]

    /// Table selection that survives streaming updates. While a run is
    /// appending rows, the NSTableView-backed Table reloads and writes nil
    /// back through its selection binding — so clicking a row mid-run
    /// flashed selected and immediately deselected. A run never deselects
    /// on the user's behalf; explicit clicks on other rows still apply.
    private var runSafeSelection: Binding<String?> {
        Binding(
            get: { model.selectedRepo },
            set: { newValue in
                if newValue == nil && model.running { return }
                model.selectedRepo = newValue
            }
        )
    }

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
        .onChange(of: model.phase) { rowFilter = .all }
    }

    /// The filter control for a table header. Offers only the cases that make
    /// sense for the phase (no "Selected" in Find).
    private func filterPicker(includeSelected: Bool) -> some View {
        Picker("Show", selection: $rowFilter) {
            Text("All").tag(RowFilter.all)
            Text("Actionable").tag(RowFilter.actionable)
            if includeSelected {
                Text("Selected").tag(RowFilter.selected)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
        .help("Filter which repositories the table shows")
    }

    /// Find-phase row filter: hide definitive non-matches.
    private func filtered(_ results: [RepoResult]) -> [RepoResult] {
        guard rowFilter != .all else { return results }
        return results.filter { ![.skipped, .noMatch].contains($0.status) }
    }

    /// Update-phase row filter: planned-only, or checked-to-apply-only.
    private func filtered(_ rows: [AppModel.UpdateRow]) -> [AppModel.UpdateRow] {
        switch rowFilter {
        case .all: return rows
        case .actionable: return rows.filter { model.activePlan[$0.id] != nil }
        case .selected: return rows.filter { model.applyTargets.contains($0.id) }
        }
    }

    @ViewBuilder
    private var mergeTable: some View {
        @Bindable var model = model
        if model.mergeRows.isEmpty {
            ContentUnavailableView(
                "No job pull requests",
                systemImage: "arrow.triangle.pull",
                description: Text("Apply an update plan first — the PRs it creates appear here for approval and completion.")
            )
        } else {
            let approvedCount = model.mergeRows.filter(\.approved).count
            TableHeaderStrip(text: "\(approvedCount) of \(model.mergeRows.count) approved") {
                Button("Approve all") { model.approveAll() }
                    .controlSize(.small)
                    .disabled(model.running || approvedCount == model.mergeRows.count)
                Button("Clear approvals") { model.clearApprovals() }
                    .controlSize(.small)
                    .disabled(model.running || approvedCount == 0)
            }

            Table(model.mergeRows.sorted(using: mergeSort), selection: runSafeSelection, sortOrder: $mergeSort) {
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

                TableColumn("Complete", value: \.completeOrder) { (row: AppModel.MergeRow) in
                    if let result = row.result {
                        StatusBadge(status: result.status)
                    } else {
                        Text("—")
                            .foregroundStyle(.tertiary)
                            .help("Not run yet")
                    }
                }
                .width(min: 96, ideal: 100, max: 130)

                TableColumn("Repository", value: \.repo.fullName) { (row: AppModel.MergeRow) in
                    RepoCell(repo: row.repo)
                }
                .width(min: 140, ideal: 210, max: 300)

                TableColumn("PR", value: \.number) { (row: AppModel.MergeRow) in
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

    @ViewBuilder
    private var checkTable: some View {
        @Bindable var model = model
        if model.results.isEmpty {
            ContentUnavailableView(
                "Nothing found yet",
                systemImage: "magnifyingglass",
                description: Text("Describe what to find across the organisation, then Run.")
            )
        } else {
            VStack(spacing: 0) {
                let matched = model.results.filter { $0.status == .verifiedMatch }.count
                let failed = model.results.filter { $0.status == .failed }.count
                // Account for failures too, so the count agrees with what the
                // "Actionable" filter reveals (it keeps matches AND failures).
                TableHeaderStrip(text: failed > 0
                                    ? "\(matched) matched, \(failed) failed of \(model.results.count) scanned"
                                    : "\(matched) matched of \(model.results.count) scanned") {
                    filterPicker(includeSelected: false)
                }
                Table(filtered(model.results).sorted(using: checkSort), selection: runSafeSelection, sortOrder: $checkSort) {
                    TableColumn("Status", value: \.status.sortOrder) { (result: RepoResult) in
                        StatusBadge(status: result.status)
                    }
                    .width(min: 96, ideal: 100, max: 130)

                    TableColumn("Repository", value: \.repo.fullName) { (result: RepoResult) in
                        RepoCell(repo: result.repo, isCanary: model.canaryRepo == result.id)
                    }
                    .width(min: 140, ideal: 210, max: 300)

                    TableColumn("Branch", value: \.repo.defaultBranch) { (result: RepoResult) in
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
        }
    }

    @ViewBuilder
    private var updateTable: some View {
        @Bindable var model = model
        if model.updateRows.isEmpty {
            ContentUnavailableView(
                "No repositories to update",
                systemImage: "pencil",
                description: Text("Run a Find step first — matches carry into Update. Then describe the change and Dry Run to build a plan.")
            )
        } else {
            let plannedCount = model.plannedRepoIDs.count
            VStack(spacing: 0) {
                // The checkbox column is always interactive, so the strip always
                // reports the real selection — how many of the planned repos are
                // checked to action — not just the plan size. Arming then writes
                // exactly this set.
                TableHeaderStrip(text: "\(model.applyTargets.count) of \(plannedCount) repo(s) checked to apply") {
                    Button("Select all") { model.selectAllApplyTargets() }
                        .controlSize(.small)
                        .disabled(model.running || model.applyTargets.count == plannedCount)
                    Button("Deselect all") { model.deselectAllApplyTargets() }
                        .controlSize(.small)
                        .disabled(model.running || model.applyTargets.isEmpty)
                    filterPicker(includeSelected: true)
                }

                Table(filtered(model.updateRows).sorted(using: updateSort), selection: runSafeSelection, sortOrder: $updateSort) {
                TableColumn("Apply") { (row: AppModel.UpdateRow) in
                    let eligible = model.activePlan[row.id] != nil
                    Toggle("", isOn: Binding(
                        get: { model.applyTargets.contains(row.id) },
                        set: { _ in model.toggleApplyTarget(row.id) }
                    ))
                    .labelsHidden()
                    .disabled(model.running || !eligible)
                    // Blank, not just disabled, for repos with nothing planned —
                    // a greyed checkbox reads as "uncheck me", an absent one as
                    // "nothing to apply here".
                    .opacity(eligible ? 1 : 0)
                    .help(eligible
                            ? "Apply the reviewed plan to this repo when you arm writes"
                            : "No planned actions for this repo")
                }
                .width(min: 50, ideal: 55, max: 65)

                TableColumn("Find", value: \.checkOrder) { (row: AppModel.UpdateRow) in
                    if let check = row.check {
                        StatusBadge(status: check.status)
                            .opacity(0.6)
                            .help("Verdict from the last find run")
                    } else {
                        Text("—")
                            .foregroundStyle(.tertiary)
                    }
                }
                .width(min: 96, ideal: 100, max: 130)

                TableColumn("Update", value: \.updateOrder) { (row: AppModel.UpdateRow) in
                    if let update = row.update {
                        StatusBadge(status: update.status)
                    } else {
                        Text("—")
                            .foregroundStyle(.tertiary)
                            .help("No update run yet for this repo")
                    }
                }
                .width(min: 96, ideal: 100, max: 130)

                TableColumn("Repository", value: \.repo.fullName) { (row: AppModel.UpdateRow) in
                    RepoCell(repo: row.repo, isCanary: model.canaryRepo == row.id)
                }
                .width(min: 140, ideal: 210, max: 300)

                TableColumn("Branch", value: \.repo.defaultBranch) { (row: AppModel.UpdateRow) in
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

/// A quiet count header above a results table, with optional trailing controls.
/// Shared by all three phases so they read consistently — the count on the
/// left, any actions (approve-all / select-all) on the right.
struct TableHeaderStrip<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    init(text: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider() }
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
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(status.rawValue)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.18), in: Capsule())
        .foregroundStyle(color)
    }

    /// A warning glyph on the states that need attention, so they don't read as
    /// just another pill.
    private var icon: String? {
        switch status {
        case .failed, .blocked, .conflicted: return "exclamationmark.triangle.fill"
        default: return nil
        }
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
