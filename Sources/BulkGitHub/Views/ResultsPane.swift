import SwiftUI
import BulkGitHubKit

struct ResultsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Table(model.results, selection: $model.selectedRepo) {
            TableColumn("Status") { result in
                StatusBadge(status: result.status)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Repository") { result in
                HStack(spacing: 4) {
                    Text(result.repo.fullName)
                    if result.repo.archived {
                        Image(systemName: "archivebox")
                            .foregroundStyle(.secondary)
                            .help("Archived")
                    }
                    if !result.repo.isPrivate {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                            .help("Public")
                    }
                }
            }

            TableColumn("Branch") { result in
                Text(result.repo.defaultBranch)
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)

            TableColumn("Detail") { result in
                Text(detailText(for: result))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func detailText(for result: RepoResult) -> String {
        if let reason = result.reason, !reason.isEmpty { return reason }
        if !result.evidence.isEmpty {
            return result.evidence.map(\.path).joined(separator: ", ")
        }
        return ""
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
        case .cancelled: return .gray
        case .branchExists, .prExists, .prRaised: return .purple
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
