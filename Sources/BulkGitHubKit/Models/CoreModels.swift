import Foundation

// MARK: - Repositories and pull requests

public struct RepoRef: Codable, Hashable, Sendable, Identifiable {
    public var fullName: String
    public var name: String
    public var defaultBranch: String
    public var archived: Bool
    public var isPrivate: Bool

    public var id: String { fullName }

    public init(fullName: String, name: String? = nil, defaultBranch: String = "main",
                archived: Bool = false, isPrivate: Bool = true) {
        self.fullName = fullName
        self.name = name ?? fullName.split(separator: "/").last.map(String.init) ?? fullName
        self.defaultBranch = defaultBranch
        self.archived = archived
        self.isPrivate = isPrivate
    }

    /// Shape exposed to scripts (matches the `Repo` interface in bulkgh.d.ts).
    public var scriptValue: [String: Any] {
        ["fullName": fullName, "name": name, "defaultBranch": defaultBranch,
         "archived": archived, "private": isPrivate]
    }
}

// MARK: - Repository custom properties

/// One custom-property value. GitHub custom properties are name/value metadata
/// defined at the organisation level; a value is free-text/single-select
/// (`string`), multi-select (`list`), or unset (`null`). True/false properties
/// arrive as the strings "true"/"false" and ride in `.string`.
public enum PropertyValue: Codable, Hashable, Sendable {
    case string(String)
    case list([String])
    case null

    /// Shape exposed to scripts: a JS string, array of strings, or null.
    public var scriptValue: Any {
        switch self {
        case .string(let s): return s
        case .list(let a): return a
        case .null: return NSNull()
        }
    }

    /// Human-readable form for plan summaries and diffs.
    public var displayString: String {
        switch self {
        case .string(let s): return s
        case .list(let a): return "[" + a.joined(separator: ", ") + "]"
        case .null: return "(unset)"
        }
    }
}

/// An organisation custom-property definition — the schema a value must satisfy.
/// Used to validate writes (single/multi-select values outside `allowedValues`
/// are rejected by GitHub) before they reach the API.
public struct PropertyDef: Codable, Hashable, Sendable {
    public var name: String
    /// "string" | "single_select" | "multi_select" | "true_false".
    public var valueType: String
    /// Permitted values for single/multi-select properties; nil for free-text.
    public var allowedValues: [String]?

    public init(name: String, valueType: String, allowedValues: [String]? = nil) {
        self.name = name
        self.valueType = valueType
        self.allowedValues = allowedValues
    }

    public var scriptValue: [String: Any] {
        ["name": name, "valueType": valueType,
         "allowedValues": allowedValues ?? NSNull()]
    }
}

/// A repository paired with its custom-property values — the unit returned by
/// the authoritative org-wide bulk read that powers property queries.
public struct RepoProperties: Sendable {
    public let repo: RepoRef
    public let properties: [String: PropertyValue]

    public init(repo: RepoRef, properties: [String: PropertyValue]) {
        self.repo = repo
        self.properties = properties
    }
}

public struct PullRequestRef: Codable, Hashable, Sendable {
    public var repo: String
    public var number: Int
    public var headRef: String
    public var headSha: String
    /// The squash-merge commit on the base branch once merged (else nil) —
    /// distinct from headSha (the source-branch tip). Lets a merge confirmed
    /// after a transient error report the real merge commit. Optional for
    /// backward-compatible decoding of previously-persisted refs.
    public var mergeCommitSha: String?
    public var state: String // "open" | "closed" | "merged"
    public var url: String
    /// The PR body/description. Optional for backward-compatible decoding of
    /// previously-persisted refs and dry-run synthesized refs.
    public var body: String?

    public init(repo: String, number: Int, headRef: String, headSha: String,
                state: String, url: String, mergeCommitSha: String? = nil,
                body: String? = nil) {
        self.repo = repo
        self.number = number
        self.headRef = headRef
        self.headSha = headSha
        self.state = state
        self.url = url
        self.mergeCommitSha = mergeCommitSha
        self.body = body
    }

    public var scriptValue: [String: Any] {
        var value: [String: Any] = ["repo": repo, "number": number, "headRef": headRef,
                                    "headSha": headSha, "state": state, "url": url]
        if let body { value["body"] = body }
        return value
    }
}

// MARK: - Results

public enum RepoStatus: String, Codable, Sendable, CaseIterable {
    case candidate
    /// Examined during the run but nothing was reported: distinguishes "we
    /// looked and found nothing" from "still being examined" (candidate).
    case noMatch = "no match"
    case verifiedMatch = "verified match"
    case skipped
    case failed
    /// Dry-run update: write actions recorded for this repo, awaiting review.
    case planned
    case alreadyUpToDate = "already up to date"
    case branchExists = "branch exists"
    case prExists = "PR exists"
    case prRaised = "PR raised"
    case blocked
    case conflicted
    case approved
    case merged
    case cancelled
    /// A direct repository-metadata write landed (e.g. a custom property set).
    /// Unlike file changes there is no branch/PR/merge — the change is terminal
    /// the moment it is written.
    case updated

    /// Stable ordinal for sorting tables by status — declaration order tracks
    /// the funnel/lifecycle (candidate → match → planned → raised → merged).
    public var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public struct Evidence: Codable, Hashable, Sendable {
    public var path: String
    public var excerpt: String
    public var explanation: String?
    /// Surrounding lines from the fetched file, captured by the host when the
    /// script reports a match — the script only supplies the excerpt.
    public var context: String?
    /// 1-based line number of the first context line, for display.
    public var contextStartLine: Int?
    /// Absolute 1-based file line numbers the host located as the match. The
    /// UI highlights exactly these — it does no matching of its own. Empty when
    /// the match has no single line to point at (see `noSpecificLine`).
    /// Optional so previously-persisted results (which lack the key) still
    /// decode; treat nil as "none".
    public var matchLines: [Int]?
    /// True when the match isn't pinned to specific lines — e.g. the script
    /// reported the whole file, or the excerpt couldn't be located in it. The
    /// UI then shows context without highlighting and captions why. Optional
    /// for backward-compatible decoding; treat nil as false.
    public var noSpecificLine: Bool?

    public init(path: String, excerpt: String, explanation: String? = nil,
                context: String? = nil, contextStartLine: Int? = nil,
                matchLines: [Int]? = nil, noSpecificLine: Bool? = nil) {
        self.path = path
        self.excerpt = excerpt
        self.explanation = explanation
        self.context = context
        self.contextStartLine = contextStartLine
        self.matchLines = matchLines
        self.noSpecificLine = noSpecificLine
    }
}

public struct RepoResult: Codable, Hashable, Sendable, Identifiable {
    public var repo: RepoRef
    public var status: RepoStatus
    public var reason: String?
    public var evidence: [Evidence]

    public var id: String { repo.fullName }

    public init(repo: RepoRef, status: RepoStatus, reason: String? = nil, evidence: [Evidence] = []) {
        self.repo = repo
        self.status = status
        self.reason = reason
        self.evidence = evidence
    }
}

// MARK: - Jobs

public enum JobPhase: String, Codable, Sendable, CaseIterable {
    case check
    case update
    case merge

    /// User-facing phase name. The contract keeps the rawValues ("check",
    /// "merge") stable — meta.phase in scripts, persistence keys, and the LLM
    /// prompt all use them — but the UI names the phases differently. The
    /// "merge" phase is script-driven and may merge, cancel/close, or take any
    /// finalizing action (see ADR 0002), so it's named action-neutrally.
    public var displayName: String {
        switch self {
        case .check: return "Find"
        case .update: return "Update"
        case .merge: return "Complete"
        }
    }
}

public struct AuditEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var kind: String   // e.g. "gh.searchCode", "gh.getContent", "job.reportMatch"
    public var repo: String?
    public var detail: String

    public init(kind: String, repo: String? = nil, detail: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.repo = repo
        self.detail = detail
    }
}

public struct Job: Codable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var prompt: String
    public var phase: JobPhase
    public var scriptSource: String
    public var params: [String: String]
    public var results: [RepoResult]
    public var logs: [String]
    public var auditEvents: [AuditEvent]
    public var lastRunStatus: String?
    /// Optional so pre-phase-3 saved state still decodes.
    public var plannedActions: [String: [PlannedAction]]?
    /// Which phase's dry run produced plannedActions (JobPhase rawValue).
    public var planPhase: String?
    /// Cross-phase job state (writeState/readState), JSON-encoded per key.
    public var state: [String: String]?
    /// Prompt per phase — switching phases must not carry prompts across.
    public var promptsByPhase: [String: String]?
    public var prTitle: String?
    public var prBody: String?
    public var canaryRepo: String?
    /// Results per phase (keyed by JobPhase rawValue) — check results survive
    /// a switch into update and back. `results` remains the legacy single list.
    public var resultsByPhase: [String: [RepoResult]]?
    /// The script source each phase's results were produced by, for staleness
    /// detection after the script is regenerated or edited.
    public var ranScriptByPhase: [String: String]?
    /// The effective params each phase's results were produced with — param
    /// edits stale results just like source edits.
    public var ranParamsByPhase: [String: [String: String]]?
    /// The meta.params defaults captured at validation, so the params bar
    /// can mark edited values across relaunches.
    public var declaredParamsByPhase: [String: [String: String]]?
    /// Each phase is a separate workspace: its own script and params, like
    /// promptsByPhase. `scriptSource`/`params` remain the legacy single slots.
    public var scriptsByPhase: [String: String]?
    public var paramsByPhase: [String: [String: String]]?
    /// Everything armed runs of this job created on the remote.
    public var artifacts: [Artifact]?
    /// User approvals of job PRs for merging (merge phase).
    public var approvals: [Approval]?
    /// The reviewed plan as actually applied per repo (armed update runs):
    /// the receipts behind each PR, diffs included, so the merge phase can
    /// show what a PR changes without re-fetching or depending on the
    /// current working plan.
    public var appliedPlans: [String: [PlannedAction]]?
    /// Cumulative audit trail across ALL of this job's runs (capped), with a
    /// synthetic "run" event marking each run boundary. `auditEvents` remains
    /// the last run only.
    public var auditTrail: [AuditEvent]?

    public init(prompt: String = "", phase: JobPhase = .check, scriptSource: String = "",
                params: [String: String] = [:]) {
        self.id = UUID()
        self.createdAt = Date()
        self.prompt = prompt
        self.phase = phase
        self.scriptSource = scriptSource
        self.params = params
        self.results = []
        self.logs = []
        self.auditEvents = []
        self.lastRunStatus = nil
    }
}

// MARK: - Script metadata and validation

public struct ScriptMeta: Sendable, Equatable {
    public var title: String
    public var phase: JobPhase
    public var params: [String: String]
    public var apiVersion: Int

    public init(title: String = "Untitled", phase: JobPhase = .check,
                params: [String: String] = [:], apiVersion: Int = 1) {
        self.title = title
        self.phase = phase
        self.params = params
        self.apiVersion = apiVersion
    }
}

public struct Diagnostic: Sendable, Hashable, Identifiable {
    public enum Severity: String, Sendable { case error, warning, info }
    public var severity: Severity
    public var message: String
    public var line: Int      // 1-based; 0 = whole file
    public var column: Int
    public var code: Int?

    public var id: String { "\(line):\(column):\(code ?? 0):\(message)" }

    public init(severity: Severity, message: String, line: Int = 0, column: Int = 0, code: Int? = nil) {
        self.severity = severity
        self.message = message
        self.line = line
        self.column = column
        self.code = code
    }
}

// MARK: - Execution plans (dry-run updates)

/// One recorded write from an update script's dry run. Nothing reaches
/// GitHub during a dry run: the recording handle synthesizes plausible
/// responses and accumulates these for native review.
public enum PlannedAction: Codable, Hashable, Sendable {
    case createBranch(name: String, fromSha: String)
    case putContent(path: String, branch: String, message: String,
                    before: String?, after: String)
    /// Update phase: remove a file from a "bulkgh/" branch. `before` is the
    /// file's content at review time — for the deletion diff and the armed
    /// drift guard. nil before means the file was already absent at review.
    case deleteFile(path: String, branch: String, message: String, before: String?)
    case createPR(headRef: String, title: String, body: String)
    /// Update phase: set/clear repository custom-property values. No branch or
    /// PR — a direct, terminal repo-metadata write. `before` is the values for
    /// exactly these keys at review time, for the diff and the armed drift guard.
    case setProperties(values: [String: PropertyValue], before: [String: PropertyValue])
    // Merge phase: these operate only on the job's own artifacts.
    case mergePR(number: Int, expectedHeadSha: String)
    case closePR(number: Int)
    case editPR(number: Int, body: String)
    case deleteBranch(name: String)

    public var summary: String {
        switch self {
        case .createBranch(let name, let sha):
            return "Create branch \(name) from \(String(sha.prefix(12)))"
        case .putContent(let path, let branch, _, let before, _):
            return before == nil ? "Create \(path) on \(branch)" : "Update \(path) on \(branch)"
        case .deleteFile(let path, let branch, _, _):
            return "Delete \(path) on \(branch)"
        case .createPR(let head, let title, _):
            return "Open PR \"\(title)\" from \(head)"
        case .setProperties(let values, let before):
            let parts = values.sorted { $0.key < $1.key }.map { key, value -> String in
                if let old = before[key], old != value {
                    return "\(key): \(old.displayString) → \(value.displayString)"
                }
                return "\(key) = \(value.displayString)"
            }
            let noun = values.count == 1 ? "property" : "properties"
            return "Set custom \(noun) \(parts.joined(separator: ", "))"
        case .mergePR(let number, let sha):
            return "Squash-merge PR #\(number) at \(String(sha.prefix(12)))"
        case .closePR(let number):
            return "Close PR #\(number) without merging"
        case .editPR(let number, _):
            return "Edit body of PR #\(number)"
        case .deleteBranch(let name):
            return "Delete branch \(name)"
        }
    }
}

/// A user's explicit approval of one job-created PR for merging, capturing
/// the head SHA they approved. Merging later requires the head to still
/// match — an approval is for a specific state of the branch, not forever.
public struct Approval: Codable, Hashable, Sendable, Identifiable {
    public var repo: String
    public var prNumber: Int
    public var headSha: String
    public var approvedAt: Date

    public var id: String { "\(repo)#\(prNumber)" }

    public init(repo: String, prNumber: Int, headSha: String) {
        self.repo = repo
        self.prNumber = prNumber
        self.headSha = headSha
        self.approvedAt = Date()
    }
}

// MARK: - Artifacts (armed runs)

/// Something an armed run actually created on the remote. The registry is the
/// boundary of merge/cancel authority: those operate ONLY on artifacts this
/// job created — the app can never touch a branch or PR it doesn't hold a
/// receipt for.
public struct Artifact: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case branch
        case pullRequest = "pull request"
    }

    public var id: UUID
    public var kind: Kind
    public var repo: String
    /// Branch name, or "#N" for a pull request.
    public var name: String
    public var url: String?
    public var createdAt: Date

    public init(kind: Kind, repo: String, name: String, url: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.repo = repo
        self.name = name
        self.url = url
        self.createdAt = Date()
    }
}

// MARK: - Engine run types

public enum RunEvent: Sendable {
    case log(String)
    case progress(String)
    case repo(RepoResult)
    /// The cumulative dry-run execution plan for one repo, emitted each time
    /// an action is recorded so the detail pane can show diffs mid-run rather
    /// than only after the run completes. `.repo` already carries the count
    /// for the table row; this carries the action list for the plan view.
    case plan(repo: String, actions: [PlannedAction])
    case audit(AuditEvent)
}

public enum RunStatus: Sendable, Equatable {
    case completed
    case failed(String)
    case cancelled

    public var label: String {
        switch self {
        case .completed: return "completed"
        case .failed(let m): return "failed: \(m)"
        case .cancelled: return "cancelled"
        }
    }
}

public struct RunOutcome: Sendable {
    public let status: RunStatus
    public let results: [RepoResult]
    public let logs: [String]
    public let auditEvents: [AuditEvent]
    /// Recorded write actions per repo fullName (update-phase dry runs).
    public let plannedActions: [String: [PlannedAction]]
    /// job.writeState values, JSON-encoded per key — feed into the next
    /// phase's run as initialState so update scripts can reuse check results
    /// instead of re-searching.
    public let state: [String: String]
    /// Remote objects an armed run created (empty for dry runs and checks).
    public let artifacts: [Artifact]
    /// Job branches an armed merge/cancel run deleted — so the app can drop
    /// their registry artifacts even when the repo never reached a
    /// merged/cancelled status (an orphan branch with no PR). Empty otherwise.
    public let consumedBranches: [Artifact]
    public let duration: TimeInterval
}

// MARK: - Settings

public struct AppSettings: Codable, Sendable, Equatable {
    public var organisation: String = "example-org"
    public var webHost: String = "https://github.com"
    public var apiHost: String = "https://api.github.com"
    public var aiModel: String = ""        // empty = client default
    // Fresh installs default to LIVE — both the model and GitHub. A returning
    // user's saved choices in state.json still win; these defaults only apply
    // when no snapshot exists.
    public var useMockLLM: Bool = false
    public var useFixtureGitHub: Bool = false
    public var maxConcurrentOps: Int = 8
    public var syncSliceSeconds: Double = 2.0
    public var maxSyncBudgetSeconds: Double = 60.0
    public var maxRunSeconds: Double = 900

    public init() {}
}
