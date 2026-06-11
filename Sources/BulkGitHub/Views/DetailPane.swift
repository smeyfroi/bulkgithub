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
