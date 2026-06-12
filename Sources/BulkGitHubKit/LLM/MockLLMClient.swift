import Foundation

/// Offline script "generation": returns the golden recipe with params patched
/// from whatever the prompt obviously specifies. Deterministic, instant, and
/// good enough to exercise the whole validate→review→run loop without network.
public final class MockLLMClient: LLMClient, @unchecked Sendable {

    public init() {}

    public func makeScript(prompt: String, context: ScriptGenerationContext) async throws -> String {
        // The selected phase decides what kind of script comes back, exactly
        // like the real client's system prompt does; keywords only refine the
        // recipe choice within the check phase.
        switch context.phase {
        case .update:
            if prompt.range(of: #"\b(add|append|insert)\b"#,
                            options: [.regularExpression, .caseInsensitive]) != nil {
                return try addSectionScript(for: prompt)
            }
            if prompt.range(of: "marker", options: .caseInsensitive) != nil {
                return try markerDeletionScript(for: prompt)
            }
            if prompt.range(of: #"\bchange\b|\bfrom\b.+\bto\b"#,
                            options: [.regularExpression, .caseInsensitive]) != nil {
                return try changeValueScript(for: prompt)
            }
            return try lineRemovalScript(for: prompt)
        case .merge:
            let recipe = prompt.range(of: "cancel", options: .caseInsensitive) != nil
                ? "cancel_job" : "merge_approved_prs"
            guard let script = ResourceLocator.recipe(named: recipe) else {
                throw LLMClientError.invalidResponse("recipe resource missing from bundle")
            }
            return script
        case .check:
            // Absence phrasing wins over presence: "does not contain" also
            // contains the word "contain".
            if prompt.range(of: #"(not contain|doesn't contain|missing|without)"#,
                            options: [.regularExpression, .caseInsensitive]) != nil {
                return try missingStringScript(for: prompt)
            }
            // A glob means "shape known, path unknown" — the glob-scanning
            // key/value recipe, not the fixed-path one.
            if prompt.range(of: "**") != nil {
                return try globKeyValueScript(for: prompt)
            }
            if prompt.range(of: "contains", options: .caseInsensitive) != nil {
                return try stringScanScript(for: prompt)
            }
            return try yamlKeyValueScript(for: prompt)
        }
    }

    private func globKeyValueScript(for prompt: String) throws -> String {
        guard var script = ResourceLocator.recipe(named: "find_yaml_key_value_glob") else {
            throw LLMClientError.invalidResponse("recipe resource missing from bundle")
        }
        if let glob = firstMatch(in: prompt, pattern: #"(?:in|under)\s+([\w./*-]+)"#) {
            script = Self.replaceParam(in: script, name: "glob", value: glob)
        }
        if let key = firstMatch(in: prompt, pattern: #"key\s+["']?([A-Za-z0-9_.-]+)"#) {
            script = Self.replaceParam(in: script, name: "key", value: key)
        }
        if let value = firstMatch(in: prompt, pattern: #"value\s+(?:of\s+|is\s+)?["']([^"']+)["']"#) {
            script = Self.replaceParam(in: script, name: "value", value: value)
        }
        return script
    }

    private func changeValueScript(for prompt: String) throws -> String {
        guard var script = ResourceLocator.recipe(named: "change_yaml_value") else {
            throw LLMClientError.invalidResponse("recipe resource missing from bundle")
        }
        if let key = firstMatch(in: prompt, pattern: #"(?:value of|key)\s+["']([A-Za-z0-9_.-]+)["']"#) {
            script = Self.replaceParam(in: script, name: "key", value: key)
        }
        if let from = firstMatch(in: prompt, pattern: #"from\s+["']([^"']+)["']"#) {
            script = Self.replaceParam(in: script, name: "from", value: from)
        }
        if let to = firstMatch(in: prompt, pattern: #"to\s+["']([^"']+)["']"#) {
            script = Self.replaceParam(in: script, name: "to", value: to)
        }
        // Glob needs a path-ish shape ("/" or "*") — "in yaml files" is prose.
        if let glob = firstMatch(in: prompt, pattern: #"(?:in|under)\s+([\w.-]*[/*][\w./*-]*)"#) {
            script = Self.replaceParam(in: script, name: "glob", value: glob)
        }
        if let title = firstMatch(in: prompt, pattern: #"pull request title:\s*"([^"]+)""#) {
            script = Self.replaceParam(in: script, name: "prTitle", value: title)
        }
        return script
    }

    private func markerDeletionScript(for prompt: String) throws -> String {
        guard var script = ResourceLocator.recipe(named: "delete_lines_between_markers") else {
            throw LLMClientError.invalidResponse("recipe resource missing from bundle")
        }
        if let start = firstMatch(in: prompt, pattern: #"marker\s+["']([^"']+)["']"#) {
            script = Self.replaceParam(in: script, name: "startMarker", value: start)
        }
        if let end = firstMatch(in: prompt, pattern: #"next\s+marker\s+["']([^"']+)["']"#) {
            script = Self.replaceParam(in: script, name: "endMarker", value: end)
        }
        if let glob = firstMatch(in: prompt, pattern: #"(?:in|under)\s+([\w./]*\*[\w./*-]*)"#) {
            script = Self.replaceParam(in: script, name: "glob", value: glob)
        }
        if let title = firstMatch(in: prompt, pattern: #"pull request title:\s*"([^"]+)""#) {
            script = Self.replaceParam(in: script, name: "prTitle", value: title)
        }
        return script
    }

    private func missingStringScript(for prompt: String) throws -> String {
        guard var script = ResourceLocator.recipe(named: "find_file_missing_string") else {
            throw LLMClientError.invalidResponse("recipe resource missing from bundle")
        }
        if let path = firstMatch(in: prompt, pattern: #"([\w./+-]+\.(?:ya?ml|json|toml|txt|md))"#) {
            script = Self.replaceParam(in: script, name: "path", value: path)
        }
        if let marker = firstMatch(in: prompt, pattern: #"["']([^"']+)["']"#) {
            script = Self.replaceParam(in: script, name: "marker", value: marker)
        }
        return script
    }

    private func addSectionScript(for prompt: String) throws -> String {
        guard var script = ResourceLocator.recipe(named: "add_section_to_file") else {
            throw LLMClientError.invalidResponse("recipe resource missing from bundle")
        }
        if let path = firstMatch(in: prompt, pattern: #"([\w./+-]+\.(?:ya?ml|json|toml|txt|md))"#) {
            script = Self.replaceParam(in: script, name: "path", value: path)
        }
        if let heading = firstMatch(in: prompt, pattern: #"["']([^"']+)["']\s+section"#)
            ?? firstMatch(in: prompt, pattern: #"["']([^"']+)["']"#) {
            script = Self.replaceParam(in: script, name: "heading", value: heading)
        }
        if let body = firstMatch(in: prompt, pattern: #"(?:with|body)(?:\s+body)?\s+["']([^"']+)["']"#) {
            script = Self.replaceParam(in: script, name: "body", value: body)
        }
        if let title = firstMatch(in: prompt, pattern: #"pull request title:\s*"([^"]+)""#) {
            script = Self.replaceParam(in: script, name: "prTitle", value: title)
        }
        return script
    }

    private func lineRemovalScript(for prompt: String) throws -> String {
        guard var script = ResourceLocator.recipe(named: "remove_line_with_string") else {
            throw LLMClientError.invalidResponse("recipe resource missing from bundle")
        }
        if let needle = firstMatch(in: prompt, pattern: #"`([^`]+)`"#) {
            script = Self.replaceParam(in: script, name: "needle", value: needle)
        }
        if let directory = firstMatch(in: prompt, pattern: #"files?\s+(?:in|under)\s+([\w./-]+)"#) {
            let trimmed = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            script = Self.replaceParam(in: script, name: "glob", value: "\(trimmed)/**")
        }
        if let title = firstMatch(in: prompt, pattern: #"pull request title:\s*"([^"]+)""#) {
            script = Self.replaceParam(in: script, name: "prTitle", value: title)
        }
        return script
    }

    private func yamlKeyValueScript(for prompt: String) throws -> String {
        guard var script = ResourceLocator.recipe(named: "find_yaml_key_value") else {
            throw LLMClientError.invalidResponse("recipe resource missing from bundle")
        }
        if let path = firstMatch(in: prompt, pattern: #"([\w./+-]+\.(?:ya?ml|json|toml|txt|md))"#) {
            script = Self.replaceParam(in: script, name: "path", value: path)
        }
        // "a value of "x"" / "value is 'x'" — anchored on the word "value" so
        // a quoted path or key earlier in the prompt can't be mistaken for it.
        if let value = firstMatch(in: prompt, pattern: #"value\s+(?:of\s+|is\s+)?["']([^"']+)["']"#) {
            script = Self.replaceParam(in: script, name: "value", value: value)
        }
        // "the key account_id" or "the 'type' value".
        if let key = firstMatch(in: prompt, pattern: #"key\s+["'`]?([A-Za-z0-9_.-]+)["'`]?"#)
            ?? firstMatch(in: prompt, pattern: #"["']([A-Za-z0-9_.-]+)["']\s+value"#) {
            script = Self.replaceParam(in: script, name: "key", value: key)
        }
        return script
    }

    private func stringScanScript(for prompt: String) throws -> String {
        guard var script = ResourceLocator.recipe(named: "find_string_in_path") else {
            throw LLMClientError.invalidResponse("recipe resource missing from bundle")
        }
        if let needle = firstMatch(in: prompt, pattern: #"`([^`]+)`"#)
            ?? firstMatch(in: prompt, pattern: #""([^"]+)""#) {
            script = Self.replaceParam(in: script, name: "needle", value: needle)
        }
        if let directory = firstMatch(in: prompt, pattern: #"files?\s+(?:in|under)\s+([\w./-]+)"#) {
            let trimmed = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            script = Self.replaceParam(in: script, name: "glob", value: "\(trimmed)/**")
        }
        return script
    }

    /// Fake-streams the patched recipe line by line so the offline demo
    /// exercises the same live-generation UI path as the real client.
    public func streamScript(prompt: String, context: ScriptGenerationContext)
        -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let script = try await makeScript(prompt: prompt, context: context)
                    continuation.yield(.delta("```typescript\n"))
                    for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
                        try await Task.sleep(for: .milliseconds(12))
                        continuation.yield(.delta(String(line) + "\n"))
                    }
                    continuation.yield(.delta("```"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
