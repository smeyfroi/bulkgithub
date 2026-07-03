import Foundation

/// Sets fields inside a recipe's `const meta = { … }` object without a full
/// parse. User recipes are self-describing `.ts` files, so saving or renaming
/// one updates its `meta.title` (the display name) and `meta.prompt` in place.
///
/// Operates on the canonical meta shape the app and the LLM produce — a
/// top-level object literal with `field: "…"` entries, before `function main`.
/// Returns nil when it can't match, so callers fall back to the source
/// unchanged (its own `meta.title` then serves as the name).
enum RecipeMetaWriter {

    /// JSON-escaped, double-quoted form of a string value.
    static func quoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return "\"\"" }
        return string
    }

    /// Replace the first `field: "…"` in the meta region (before `function
    /// main`). Returns nil if the field isn't present there.
    static func setField(_ field: String, to value: String, in source: String) -> String? {
        let ns = source as NSString
        let mainRange = ns.range(of: "function main")
        let searchRange = mainRange.location == NSNotFound
            ? NSRange(location: 0, length: ns.length)
            : NSRange(location: 0, length: mainRange.location)
        let pattern = "\\b\(field)\\s*:\\s*\"(?:\\\\.|[^\"\\\\])*\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: searchRange) else { return nil }
        return ns.replacingCharacters(in: match.range, with: "\(field): \(quoted(value))")
    }

    /// Set both `meta.title` and `meta.prompt`, inserting a prompt after the
    /// title when the meta declares none. Returns nil only if there's no
    /// title field to anchor to.
    static func applying(title: String, prompt: String, to source: String) -> String? {
        guard let titled = setField("title", to: title, in: source) else { return nil }
        if let both = setField("prompt", to: prompt, in: titled) { return both }
        return insertingPrompt(prompt, afterTitleIn: titled) ?? titled
    }

    private static func insertingPrompt(_ prompt: String, afterTitleIn source: String) -> String? {
        let ns = source as NSString
        let pattern = "\\btitle\\s*:\\s*\"(?:\\\\.|[^\"\\\\])*\"\\s*,"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source,
                                           range: NSRange(location: 0, length: ns.length)) else { return nil }
        let insertAt = match.range.location + match.range.length
        let insertion = "\n  prompt: \(quoted(prompt)),"
        return ns.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: insertion)
    }
}
