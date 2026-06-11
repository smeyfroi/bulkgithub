import Foundation

/// Offline script "generation": returns the golden recipe with params patched
/// from whatever the prompt obviously specifies. Deterministic, instant, and
/// good enough to exercise the whole validate→review→run loop without network.
public final class MockLLMClient: LLMClient, @unchecked Sendable {

    public init() {}

    public func makeScript(prompt: String, context: ScriptGenerationContext) async throws -> String {
        guard var script = ResourceLocator.goldenRecipe else {
            throw LLMClientError.invalidResponse("golden recipe resource missing from bundle")
        }
        if let path = firstMatch(in: prompt, pattern: #"([\w./+-]+\.(?:ya?ml|json|toml|txt|md))"#) {
            script = Self.replaceParam(in: script, name: "path", value: path)
        }
        if let value = firstMatch(in: prompt, pattern: #""([^"]+)""#) {
            script = Self.replaceParam(in: script, name: "value", value: value)
        }
        if let key = firstMatch(in: prompt, pattern: #"key\s+`?([A-Za-z0-9_.-]+)`?"#) {
            script = Self.replaceParam(in: script, name: "key", value: key)
        }
        return script
    }

    public func reviseScript(_ script: String, prompt: String, diagnostics: [Diagnostic],
                             context: ScriptGenerationContext) async throws -> String {
        let summary = diagnostics.first.map { "\($0.line):\($0.column) \($0.message)" } ?? "no diagnostics"
        return "// mock revision (was: \(summary))\n" + script
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func replaceParam(in script: String, name: String, value: String) -> String {
        let pattern = "(\\b\(NSRegularExpression.escapedPattern(for: name)):\\s*\")[^\"]*(\")"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return script }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return regex.stringByReplacingMatches(in: script,
                                              range: NSRange(script.startIndex..., in: script),
                                              withTemplate: "$1\(escaped)$2")
    }
}
