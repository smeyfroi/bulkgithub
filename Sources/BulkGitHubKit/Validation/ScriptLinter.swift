import Foundation

/// Cheap Swift-side checks that run before the type-checker. These are
/// clarity rules, not the sandbox — the JSC context has no ambient
/// capabilities regardless of what a script tries.
public enum ScriptLinter {

    private static let rules: [(pattern: String, message: String)] = [
        (#"\beval\s*\("#, "eval is not permitted in scripts"),
        (#"\bnew\s+Function\b"#, "the Function constructor is not permitted in scripts"),
        (#"^\s*import\s"#, "modules are not supported — scripts are a single file against the host API"),
        (#"^\s*export\s"#, "modules are not supported — scripts are a single file against the host API"),
        (#"\brequire\s*\("#, "require() does not exist — only the host API (gh, job, parse) is available"),
    ]

    public static func lint(_ source: String) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let compiled: [(NSRegularExpression, String)] = rules.compactMap { rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern,
                                                       options: [.anchorsMatchLines]) else { return nil }
            return (regex, rule.message)
        }
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            for (regex, message) in compiled {
                if let match = regex.firstMatch(in: line, range: range) {
                    let column = match.range.location + 1
                    diagnostics.append(Diagnostic(severity: .error, message: message,
                                                  line: index + 1, column: column))
                }
            }
        }
        return diagnostics
    }
}
