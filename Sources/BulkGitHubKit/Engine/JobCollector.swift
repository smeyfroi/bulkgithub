import Foundation

/// Thread-safe accumulator for everything a script run produces: per-repo
/// results, logs, audit events, cross-phase state, and the content-fetch
/// receipts that make `job.reportMatch` refuse evidence that was never
/// actually fetched.
public final class JobCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var resultsByRepo: [String: RepoResult] = [:]
    private var knownRepos: [String: RepoRef] = [:]
    private var receipts: Set<String> = []
    private var fetchedContents: [String: String] = [:]
    private var plannedActions: [String: [PlannedAction]] = [:]
    private var logs: [String] = []
    private var auditEvents: [AuditEvent] = []
    private var state: [String: Any] = [:]
    private var artifacts: [Artifact] = []
    /// Armed runs: per-repo cursor into the reviewed reference plan, and the
    /// repos where writing has stopped (conflict, drift, already-exists).
    private var planCursors: [String: Int] = [:]
    private var haltedRepos: Set<String> = []
    private let referencePlan: [String: [PlannedAction]]
    private let targetRepos: Set<String>?
    private let onEvent: (RunEvent) -> Void

    public init(initialState: [String: String] = [:],
                targetRepos: Set<String>? = nil,
                referencePlan: [String: [PlannedAction]] = [:],
                onEvent: @escaping (RunEvent) -> Void) {
        self.targetRepos = targetRepos
        self.referencePlan = referencePlan
        self.onEvent = onEvent
        for (key, json) in initialState {
            guard let data = json.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data,
                                                                options: [.fragmentsAllowed]) else { continue }
            state[key] = value
        }
    }

    // MARK: Repos

    public func repo(named fullName: String) -> RepoRef {
        lock.lock(); defer { lock.unlock() }
        return knownRepos[fullName] ?? RepoRef(fullName: fullName)
    }

    /// Repos returned by gh enumeration calls become candidates: they are what
    /// the script is examining. Existing entries are never downgraded.
    public func registerCandidates(_ repos: [RepoRef]) {
        var events: [RunEvent] = []
        lock.lock()
        for repo in repos {
            knownRepos[repo.fullName] = repo
            if resultsByRepo[repo.fullName] == nil {
                let result = RepoResult(repo: repo, status: .candidate)
                resultsByRepo[repo.fullName] = result
                order.append(repo.fullName)
                events.append(.repo(result))
            }
        }
        lock.unlock()
        events.forEach(onEvent)
    }

    /// Record authoritative repo metadata without creating a result row —
    /// gh.getRepo is a lookup, not an enumeration. An existing row is
    /// refreshed so the table shows the real default branch.
    public func remember(_ repo: RepoRef) {
        var event: RunEvent?
        lock.lock()
        knownRepos[repo.fullName] = repo
        if var result = resultsByRepo[repo.fullName], result.repo != repo {
            result.repo = repo
            resultsByRepo[repo.fullName] = result
            event = .repo(result)
        }
        lock.unlock()
        if let event { onEvent(event) }
    }

    /// Run completed: every repo the script enumerated but never reported on
    /// is resolved to "no match". Mid-run, `candidate` means "being examined";
    /// leaving it on the final table reads as if every org repo matched.
    /// Not called for cancelled or failed runs, where candidates genuinely
    /// were still pending.
    public func finalizeUnreportedCandidates() {
        var events: [RunEvent] = []
        lock.lock()
        for fullName in order {
            guard var result = resultsByRepo[fullName],
                  result.status == .candidate else { continue }
            result.status = .noMatch
            result.reason = result.reason ?? "nothing reported"
            resultsByRepo[fullName] = result
            events.append(.repo(result))
        }
        lock.unlock()
        events.forEach(onEvent)
    }

    @discardableResult
    public func upsert(repo: RepoRef, status: RepoStatus, reason: String?,
                       evidence: Evidence? = nil) -> RepoResult {
        lock.lock()
        knownRepos[repo.fullName] = knownRepos[repo.fullName] ?? repo
        var result = resultsByRepo[repo.fullName]
            ?? RepoResult(repo: knownRepos[repo.fullName] ?? repo, status: status)
        if resultsByRepo[repo.fullName] == nil { order.append(repo.fullName) }
        result.status = status
        result.reason = reason ?? result.reason
        if let evidence { result.evidence.append(evidence) }
        resultsByRepo[repo.fullName] = result
        lock.unlock()
        onEvent(.repo(result))
        return result
    }

    // MARK: Receipts (deterministic-verification rule)

    public func recordReceipt(repo: String, path: String, content: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        receipts.insert("\(repo)|\(path)")
        if let content { fetchedContents["\(repo)|\(path)"] = content }
    }

    public func hasReceipt(repo: String, path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return receipts.contains("\(repo)|\(path)")
    }

    /// The content a script fetched earlier in this run — the "before" side of
    /// a planned edit's diff.
    public func fetchedContent(repo: String, path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return fetchedContents["\(repo)|\(path)"]
    }

    // MARK: Execution plan (recording handle, update dry runs)

    /// True when canary targeting excludes this repo from the plan.
    public func isOutsideCanary(_ repo: String) -> Bool {
        guard let targetRepos else { return false }
        return !targetRepos.contains(repo)
    }

    public func recordAction(repo: String, _ action: PlannedAction) {
        if isOutsideCanary(repo) {
            upsert(repo: self.repo(named: repo), status: .skipped,
                   reason: "outside canary target — actions dropped (dry run)")
            return
        }
        lock.lock()
        plannedActions[repo, default: []].append(action)
        let count = plannedActions[repo]?.count ?? 0
        knownRepos[repo] = knownRepos[repo] ?? RepoRef(fullName: repo)
        var result = resultsByRepo[repo] ?? RepoResult(repo: knownRepos[repo]!, status: .planned)
        if resultsByRepo[repo] == nil { order.append(repo) }
        result.status = .planned
        result.reason = "\(count) action\(count == 1 ? "" : "s") planned"
        resultsByRepo[repo] = result
        lock.unlock()
        onEvent(.repo(result))
    }

    public var snapshotPlan: [String: [PlannedAction]] {
        lock.lock(); defer { lock.unlock() }
        return plannedActions
    }

    // MARK: Armed writes (guarded live handle)

    /// The next action the reviewed plan expects for this repo, or nil when
    /// the plan is exhausted (or the repo was never planned).
    public func expectedNextAction(repo: String) -> PlannedAction? {
        lock.lock(); defer { lock.unlock() }
        let cursor = planCursors[repo] ?? 0
        guard let plan = referencePlan[repo], cursor < plan.count else { return nil }
        return plan[cursor]
    }

    public func consumeNextAction(repo: String) {
        lock.lock(); defer { lock.unlock() }
        planCursors[repo] = (planCursors[repo] ?? 0) + 1
    }

    /// Stop writing to a repo (drift, plan deviation, artifact already
    /// exists): records the status and refuses further writes there.
    public func haltRepo(_ repo: String, status: RepoStatus, reason: String) {
        lock.lock()
        haltedRepos.insert(repo)
        lock.unlock()
        upsert(repo: self.repo(named: repo), status: status, reason: reason)
    }

    public func isHalted(_ repo: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return haltedRepos.contains(repo)
    }

    public func recordArtifact(_ artifact: Artifact) {
        lock.lock()
        artifacts.append(artifact)
        lock.unlock()
    }

    public var snapshotArtifacts: [Artifact] {
        lock.lock(); defer { lock.unlock() }
        return artifacts
    }

    /// JSON-encoded state for persistence and cross-run hand-off.
    public var snapshotState: [String: String] {
        lock.lock(); defer { lock.unlock() }
        var encoded: [String: String] = [:]
        for (key, value) in state {
            guard JSONSerialization.isValidJSONObject(value)
                    || value is String || value is NSNumber || value is NSNull,
                  let data = try? JSONSerialization.data(withJSONObject: value,
                                                         options: [.fragmentsAllowed]),
                  let json = String(data: data, encoding: .utf8) else { continue }
            encoded[key] = json
        }
        return encoded
    }

    // MARK: Logs, progress, audit

    public func log(_ message: String) {
        lock.lock()
        logs.append(message)
        lock.unlock()
        onEvent(.log(message))
    }

    public func progress(_ message: String) {
        lock.lock()
        logs.append("▸ \(message)")
        lock.unlock()
        onEvent(.progress(message))
    }

    public func audit(kind: String, repo: String?, detail: String) {
        let event = AuditEvent(kind: kind, repo: repo, detail: detail)
        lock.lock()
        auditEvents.append(event)
        lock.unlock()
        onEvent(.audit(event))
    }

    // MARK: Cross-phase state

    public func writeState(key: String, value: Any) {
        lock.lock(); defer { lock.unlock() }
        state[key] = value
    }

    public func readState(key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return state[key]
    }

    // MARK: Snapshots

    public var snapshotResults: [RepoResult] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { resultsByRepo[$0] }
    }

    public var snapshotLogs: [String] {
        lock.lock(); defer { lock.unlock() }
        return logs
    }

    public var snapshotAudit: [AuditEvent] {
        lock.lock(); defer { lock.unlock() }
        return auditEvents
    }
}
