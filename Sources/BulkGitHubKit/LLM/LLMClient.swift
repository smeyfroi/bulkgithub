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
    /// The model declined to write a script because the host API lacks a
    /// required capability, and reported what it needs instead. This is the
    /// desired behaviour, not a failure — surface the report to the user.
    case capabilityGap(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Anthropic API key configured (Settings → AI)"
        case .http(let code, let message): return "Anthropic API error \(code): \(message)"
        case .rateLimited(let after):
            return "Anthropic API rate limited" + (after.map { ", retry after \(Int($0))s" } ?? "")
        case .invalidResponse(let message): return "Unexpected Anthropic response: \(message)"
        case .network(let message): return "Network error: \(message)"
        case .capabilityGap(let report): return "Capability gap reported by the model: \(report)"
        }
    }
}

public enum LLMStreamEvent: Sendable {
    /// A chunk of the model's raw response text (fences included). The caller
    /// accumulates chunks and parses the final result with
    /// PromptLibrary.parseGeneration; PromptLibrary.liveScript gives a clean
    /// in-progress view for display.
    case delta(String)
}

/// Produces scripts, not plans. The host API surface and house rules are part
/// of the prompt; the returned source is TypeScript targeting bulkgh.d.ts.
public protocol LLMClient: Sendable {
    func makeScript(prompt: String, context: ScriptGenerationContext) async throws -> String
    func reviseScript(_ script: String, prompt: String, diagnostics: [Diagnostic],
                      context: ScriptGenerationContext) async throws -> String
    /// Streaming generation: yields raw response chunks as the model writes.
    /// Capability gaps and failures arrive as the stream's terminal error or
    /// in the assembled text (parse with PromptLibrary.parseGeneration).
    func streamScript(prompt: String, context: ScriptGenerationContext)
        -> AsyncThrowingStream<LLMStreamEvent, Error>
}

public extension LLMClient {
    /// Non-streaming fallback: one delta with the whole script.
    func streamScript(prompt: String, context: ScriptGenerationContext)
        -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let script = try await makeScript(prompt: prompt, context: context)
                    continuation.yield(.delta(script))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
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
    11. To work across many files in a repository, use gh.listFiles with a \
    glob (one API call), then gh.getContent for the files that matter.
    12. If the request requires capabilities the host API does not provide — \
    other endpoints, write operations beyond the declared surface, \
    history/commits/issues, data the surface cannot reach — do NOT improvise \
    workarounds or approximate the request with what exists. Report the gap \
    instead (see response format): state what the request needs, which host \
    capability is missing, and the closest task that IS achievable today, if \
    any. A clear gap report is the correct, expected output in this \
    situation, not a failure.
    13. Update scripts (phase "update") run as DRY RUNS first: every gh write \
    is recorded into a reviewable execution plan with synthesized responses. \
    Write the script as if it executes for real — the same script later \
    re-runs against a live handle unchanged.
    14. Update scripts follow this shape per repo: gh.getRef on the default \
    branch, one gh.createBranch (the name MUST start with "bulkgh/" — \
    host-enforced), gh.putContent per changed file (always gh.getContent \
    first so the plan can show a diff), then a single gh.createPR.
    15. Compute new file contents with targeted line/string surgery that \
    preserves the rest of the file byte-for-byte; never parse-and-reserialise \
    whole files, which destroys formatting.
    16. NEVER hardcode a branch name — the organisation mixes "master" and \
    "main" defaults. Use repo.defaultBranch from gh.listOrgRepos, or resolve \
    it with gh.getRepo when you only have a name (searchCode results and \
    repo names carried in job state do not have a reliable defaultBranch). \
    Build refs as "heads/" + defaultBranch.
    17. Merge scripts (phase "merge") operate ONLY on this job's artifacts: \
    start from gh.listJobPRs (the registry), merge with the headSha those \
    results carry as expectedHeadSha, and delete a branch only after its PR \
    is merged or closed. Merging requires the user's in-app approval — the \
    host refuses unapproved PRs and heads that moved since approval. All \
    merges are squash merges; there is no other method.
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

        Respond with exactly one fenced code block and no prose outside it:
        - ```typescript — the complete script, when the request is achievable;
        - ```capability-gap — the report described in rule 12, when it is not.
        """
    }

    public enum GenerationOutcome: Sendable {
        case script(String)
        case capabilityGap(String)
    }

    /// Distinguishes a script response from a capability-gap report
    /// (house rule 12).
    public static func parseGeneration(from response: String) -> GenerationOutcome {
        let gapPattern = #"```capability-gap\s*\n([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: gapPattern),
           let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
           let range = Range(match.range(at: 1), in: response) {
            return .capabilityGap(String(response[range]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .script(extractCode(from: response))
    }

    /// Clean in-progress view of a partially streamed response: drops any
    /// prose/fence prefix, shows the code as it arrives, and trims a closing
    /// fence once it lands. Good enough for live display; the final parse is
    /// parseGeneration on the complete text.
    public static func liveScript(fromPartial raw: String) -> String {
        guard let fenceStart = raw.range(of: "```") else { return raw }
        let afterTicks = raw[fenceStart.upperBound...]
        guard let newline = afterTicks.firstIndex(of: "\n") else { return "" }
        var code = String(afterTicks[afterTicks.index(after: newline)...])
        if let closing = code.range(of: "\n```") {
            code = String(code[..<closing.lowerBound])
        }
        return code
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
