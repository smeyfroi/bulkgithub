import Foundation

public struct ScriptGenerationContext: Sendable {
    public var organisation: String
    public var phase: JobPhase

    public init(organisation: String, phase: JobPhase = .check) {
        self.organisation = organisation
        self.phase = phase
    }
}

public enum LLMClientError: LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case rateLimited(retryAfter: Double?)
    case invalidResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Anthropic API key configured (Settings → AI)"
        case .http(let code, let message): return "Anthropic API error \(code): \(message)"
        case .rateLimited(let after):
            return "Anthropic API rate limited" + (after.map { ", retry after \(Int($0))s" } ?? "")
        case .invalidResponse(let message): return "Unexpected Anthropic response: \(message)"
        case .network(let message): return "Network error: \(message)"
        }
    }
}

/// Produces scripts, not plans. The host API surface and house rules are part
/// of the prompt; the returned source is TypeScript targeting bulkgh.d.ts.
public protocol LLMClient: Sendable {
    func makeScript(prompt: String, context: ScriptGenerationContext) async throws -> String
    func reviseScript(_ script: String, prompt: String, diagnostics: [Diagnostic],
                      context: ScriptGenerationContext) async throws -> String
}

// MARK: - Prompt library

public enum PromptLibrary {

    /// House rules distilled from the dev-handbook bulk-update scripts.
    public static let houseRules = """
    House rules for BulkGitHub scripts — follow all of them:
    1. Declare `const meta = { title, phase, apiVersion: 1, params }`. Anything a \
    user might reasonably tune (paths, keys, values, branch names) belongs in \
    `meta.params` with a sensible default, and is read back via `job.params`.
    2. Define `async function main(): Promise<void>`. Only declarations at top \
    level — never call gh/job/parse outside main().
    3. GitHub search results are candidates, NEVER proof. Always fetch content \
    with gh.getContent and verify deterministically before job.reportMatch. \
    The host enforces this and will throw otherwise.
    4. Wrap per-repository work in try/catch; report failures with \
    job.error(repo, message) and continue. One bad repo must not kill the run.
    5. Give every skipped repo a clear, specific reason via job.skip.
    6. Skip archived repositories unless the task explicitly includes them.
    7. Report milestones with job.progress (candidate count, completion).
    8. gh.getContent resolves to null when the file is absent — handle it as a \
    skip, not an error.
    9. No imports, no require, no eval, no Function constructor, no network or \
    filesystem access — the host API (gh, job, parse, console) is the entire \
    world, and the script runs in a sandboxed JavaScriptCore context.
    10. Prefer Promise.all fan-out only when per-repo work is independent; the \
    host limits concurrency, so plain loops are fine too.
    """

    public static func systemPrompt(apiDeclaration: String, organisation: String) -> String {
        """
        You write TypeScript scripts for BulkGitHub, a native macOS workbench that \
        finds and updates repositories across the "\(organisation)" GitHub \
        organisation. Your script runs inside the app's sandboxed JavaScriptCore \
        context against the host API declared below. The app type-checks your \
        script against this declaration before running it, shows it to the user \
        for review, and executes it with a capability handle appropriate to its \
        phase (check scripts get a read-only handle).

        \(houseRules)

        Host API declaration (bulkgh.d.ts):
        ```typescript
        \(apiDeclaration)
        ```

        Respond with a single fenced ```typescript code block containing the \
        complete script and nothing else. No prose before or after.
        """
    }

    /// Pulls the script out of a fenced code block; falls back to the whole
    /// response if the model didn't fence it.
    public static func extractCode(from response: String) -> String {
        let pattern = #"```(?:typescript|ts)?\s*\n([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
           let range = Range(match.range(at: 1), in: response) {
            return String(response[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
