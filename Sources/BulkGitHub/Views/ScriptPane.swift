import SwiftUI
import BulkGitHubKit

struct ScriptPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Describe what to find across the organisation…",
                          text: $model.prompt, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.generate() }
                Button(model.generating ? "Generating…" : "Generate") {
                    model.generate()
                }
                .disabled(model.generating || model.running || model.prompt.isEmpty)
            }
            .padding([.top, .horizontal], 10)

            TextEditor(text: $model.scriptText)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 10)

            if !model.paramsDraft.isEmpty {
                ParamsBar()
                    .padding(.horizontal, 10)
            }

            if !model.diagnostics.isEmpty {
                DiagnosticsList()
                    .frame(maxHeight: 110)
                    .padding(.horizontal, 10)
            }

            HStack {
                if model.running || model.validating || model.generating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("\(model.results.count) repos")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding([.horizontal, .bottom], 10)
        }
    }
}

/// Editable parameters surfaced from the script's meta.params — tweak a job
/// without re-prompting or editing code.
struct ParamsBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.secondary)
                .help("Script parameters (meta.params)")
            ForEach(model.paramsDraft.keys.sorted(), id: \.self) { key in
                HStack(spacing: 4) {
                    Text(key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(key, text: binding(for: key))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minWidth: 80, maxWidth: 220)
                }
            }
            Spacer()
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { model.paramsDraft[key] ?? "" },
            set: { model.paramsDraft[key] = $0 }
        )
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
