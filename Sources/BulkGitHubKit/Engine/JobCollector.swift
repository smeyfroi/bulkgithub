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
    private var logs: [String] = []
    private var auditEvents: [AuditEvent] = []
    private var state: [String: Any] = [:]
    private let onEvent: (RunEvent) -> Void

    public init(onEvent: @escaping (RunEvent) -> Void) {
        self.onEvent = onEvent
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

    public func recordReceipt(repo: String, path: String) {
        lock.lock(); defer { lock.unlock() }
        receipts.insert("\(repo)|\(path)")
    }

    public func hasReceipt(repo: String, path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return receipts.contains("\(repo)|\(path)")
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
