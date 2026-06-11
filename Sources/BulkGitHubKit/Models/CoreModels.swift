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

public struct PullRequestRef: Codable, Hashable, Sendable {
    public var repo: String
    public var number: Int
    public var headRef: String
    public var headSha: String
    public var state: String // "open" | "closed" | "merged"
    public var url: String

    public init(repo: String, number: Int, headRef: String, headSha: String, state: String, url: String) {
        self.repo = repo
        self.number = number
        self.headRef = headRef
        self.headSha = headSha
        self.state = state
        self.url = url
    }

    public var scriptValue: [String: Any] {
        ["repo": repo, "number": number, "headRef": headRef, "headSha": headSha,
         "state": state, "url": url]
    }
}

// MARK: - Results

public enum RepoStatus: String, Codable, Sendable, CaseIterable {
    case candidate
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
}

public struct Evidence: Codable, Hashable, Sendable {
    public var path: String
    public var excerpt: String
    public var explanation: String?

    public init(path: String, excerpt: String, explanation: String? = nil) {
        self.path = path
        self.excerpt = excerpt
        self.explanation = explanation
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
    /// Cross-phase job state (writeState/readState), JSON-encoded per key.
    public var state: [String: String]?
    /// Prompt per phase — switching phases must not carry prompts across.
    public var promptsByPhase: [String: String]?
    public var prTitle: String?
    public var canaryRepo: String?

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
/// GitHub in phase 3: the recording handle synthesizes plausible responses
/// and accumulates these for native review.
public enum PlannedAction: Codable, Hashable, Sendable {
    case createBranch(name: String, fromSha: String)
    case putContent(path: String, branch: String, message: String,
                    before: String?, after: String)
    case createPR(headRef: String, title: String, body: String)

    public var summary: String {
        switch self {
        case .createBranch(let name, let sha):
            return "Create branch \(name) from \(String(sha.prefix(12)))"
        case .putContent(let path, let branch, _, let before, _):
            return before == nil ? "Create \(path) on \(branch)" : "Update \(path) on \(branch)"
        case .createPR(let head, let title, _):
            return "Open PR \"\(title)\" from \(head)"
        }
    }
}

// MARK: - Engine run types

public enum RunEvent: Sendable {
    case log(String)
    case progress(String)
    case repo(RepoResult)
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
    public let duration: TimeInterval
}

// MARK: - Settings

public struct AppSettings: Codable, Sendable, Equatable {
    public var organisation: String = "geome"
    public var webHost: String = "https://github.com"
    public var apiHost: String = "https://api.github.com"
    public var aiModel: String = ""        // empty = client default
    public var useMockLLM: Bool = true
    public var useFixtureGitHub: Bool = true
    public var maxConcurrentOps: Int = 8
    public var syncSliceSeconds: Double = 2.0
    public var maxSyncBudgetSeconds: Double = 60.0
    public var maxRunSeconds: Double = 900
    public var confirmBeforePRs: Bool = true
    public var confirmBeforeCancel: Bool = true
    public var saveHistoryOnQuit: Bool = true

    public init() {}
}
