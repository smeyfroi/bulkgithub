import Foundation

/// Shell-style glob matching for repository paths: `*` matches within a path
/// segment, `**` spans segments (`**/` also matches zero directories), `?`
/// matches one non-slash character, `[abc]`/`[!abc]` character classes pass
/// through. Anchored to the whole path.
public enum GlobMatcher {

    public static func regexPattern(forGlob glob: String) -> String {
        var out = "^"
        var i = glob.startIndex
        while i < glob.endIndex {
            let character = glob[i]
            switch character {
            case "*":
                let next = glob.index(after: i)
                if next < glob.endIndex, glob[next] == "*" {
                    var after = glob.index(after: next)
                    if after < glob.endIndex, glob[after] == "/" {
                        // "**/" — any number of complete segments, including none
                        out += "(?:[^/]*/)*"
                        after = glob.index(after: after)
                    } else {
                        out += ".*"
                    }
                    i = after
                    continue
                }
                out += "[^/]*"
            case "?":
                out += "[^/]"
            case "[":
                var j = glob.index(after: i)
                var body = ""
                if j < glob.endIndex, glob[j] == "!" {
                    body += "^"
                    j = glob.index(after: j)
                }
                var closed = false
                while j < glob.endIndex {
                    let inner = glob[j]
                    if inner == "]" { closed = true; break }
                    body += inner == "\\" ? "\\\\" : String(inner)
                    j = glob.index(after: j)
                }
                if closed, !body.isEmpty, body != "^" {
                    out += "[" + body + "]"
                    i = glob.index(after: j)
                    continue
                }
                out += "\\["
            default:
                out += NSRegularExpression.escapedPattern(for: String(character))
            }
            i = glob.index(after: i)
        }
        return out + "$"
    }

    public static func matches(_ path: String, glob: String) -> Bool {
        filter([path], glob: glob).count == 1
    }

    public static func filter(_ paths: [String], glob: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: regexPattern(forGlob: glob)) else {
            return []
        }
        return paths.filter { path in
            regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
        }
    }
}
