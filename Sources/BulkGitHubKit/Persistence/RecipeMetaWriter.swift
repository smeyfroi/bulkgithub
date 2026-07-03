import Foundation

/// Rewrites a recipe's `const meta = { … }` object. User recipes are
/// self-describing `.ts` files, so saving/renaming one updates its display name
/// (`meta.title`) and `meta.prompt`.
///
/// Rather than edit individual fields with a regex — which mis-fires on nested
/// `params`, on values containing `{`/`}` or `function main`, on single quotes,
/// and can leave duplicate keys — this REGENERATES the entire meta object from
/// parsed values and splices it in by brace-matching the original object. The
/// caller supplies the fields (usually the parsed `ScriptMeta` with title/prompt
/// overridden); the script body is preserved verbatim.
enum RecipeMetaWriter {

    /// Replace the source's meta object literal with a freshly serialized one.
    /// Returns nil if no `const/let/var meta = { … }` object can be located.
    static func replacingMeta(in source: String, title: String, phase: JobPhase,
                              apiVersion: Int, prompt: String?, icon: String?,
                              params: [String: String]) -> String? {
        guard let range = metaObjectRange(in: source) else { return nil }
        let object = serialize(title: title, phase: phase, apiVersion: apiVersion,
                               prompt: prompt, icon: icon, params: params)
        var result = source
        result.replaceSubrange(range, with: object)
        return result
    }

    /// A canonical `{ … }` meta object literal. Empty prompt/icon are omitted.
    static func serialize(title: String, phase: JobPhase, apiVersion: Int,
                          prompt: String?, icon: String?, params: [String: String]) -> String {
        var lines = ["  title: \(quoted(title)),",
                     "  phase: \(quoted(phase.rawValue)),",
                     "  apiVersion: \(apiVersion),"]
        if let prompt, !prompt.isEmpty { lines.append("  prompt: \(quoted(prompt)),") }
        if let icon, !icon.isEmpty { lines.append("  icon: \(quoted(icon)),") }
        if !params.isEmpty {
            lines.append("  params: {")
            for key in params.keys.sorted() {
                lines.append("    \(objectKey(key)): \(quoted(params[key]!)),")
            }
            lines.append("  },")
        }
        return "{\n" + lines.joined(separator: "\n") + "\n}"
    }

    /// JSON-escaped, double-quoted string literal.
    static func quoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return "\"\"" }
        return string
    }

    /// A bare identifier key when valid, else a quoted key.
    private static func objectKey(_ key: String) -> String {
        let isIdentifier = !key.isEmpty
            && !(key.first!.isNumber)
            && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
        return isIdentifier ? key : quoted(key)
    }

    /// The range of the meta object's outermost `{ … }` (braces included), found
    /// by locating the `meta` binding and brace-matching while skipping string
    /// literals (single/double/backtick) and comments.
    private static func metaObjectRange(in source: String) -> Range<String.Index>? {
        guard let decl = source.range(of: #"\b(?:const|let|var)\s+meta\b"#,
                                      options: .regularExpression),
              let open = source[decl.upperBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var quote: Character?
        var escaped = false
        var inLineComment = false
        var inBlockComment = false
        var i = open
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i)
            if inLineComment {
                if c == "\n" { inLineComment = false }
            } else if inBlockComment {
                if c == "*", next < source.endIndex, source[next] == "/" {
                    inBlockComment = false; i = next
                }
            } else if let q = quote {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == q { quote = nil }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c
            } else if c == "/", next < source.endIndex, source[next] == "/" {
                inLineComment = true; i = next
            } else if c == "/", next < source.endIndex, source[next] == "*" {
                inBlockComment = true; i = next
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return open..<source.index(after: i) }
            }
            i = source.index(after: i)
        }
        return nil
    }
}
