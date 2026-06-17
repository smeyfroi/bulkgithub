import Foundation

/// Tracks the GitHub API quota from response headers
/// (x-ratelimit-remaining/limit/reset/resource). Shared with the UI so
/// operations surface their budget as they run.
///
/// Two realities make this fiddly:
///  • Independent quota pools ("resources": core, search, graphql, …), each with
///    its own remaining/limit/reset. We bucket by `x-ratelimit-resource`.
///  • Within a pool, GitHub's distributed limiter reports reset timestamps that
///    are NOT globally monotonic — different API replicas disagree on the window
///    boundary by minutes, and responses arrive out of order under concurrency.
///    So responses cannot be ordered by reset time. Instead, within a pool we
///    keep the LOWEST remaining (it only falls as the window is consumed) and
///    accept a RISE only once the window's reset time has actually passed — a
///    genuine rollover. This survives both out-of-order jitter (the original
///    "jumps around" bug) and replica reset-skew (the "frozen gauge" bug).
public final class RateLimitMonitor: @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        public var remaining: Int?
        public var limit: Int?
        public var resetAt: Date?
    }

    private let lock = NSLock()
    private var byResource: [String: Status] = [:]
    private var lastResource: String?
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func update(from response: HTTPURLResponse) {
        let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init)
        let limit = response.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init)
        let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init)
        guard remaining != nil || limit != nil else { return }
        // Which pool this response counted against; default to "core" when the
        // header is absent (older GHES, proxies).
        let resource = response.value(forHTTPHeaderField: "x-ratelimit-resource") ?? "core"
        let incomingReset = reset.map { Date(timeIntervalSince1970: $0) }

        lock.lock(); defer { lock.unlock() }
        lastResource = resource
        var status = byResource[resource] ?? Status()

        if let limit { status.limit = limit }

        if let remaining {
            if let current = status.remaining {
                if remaining <= current {
                    // Consumption (or a duplicate/stale-equal reading): within a
                    // window remaining only falls, so keep the lowest. Extend the
                    // boundary to the furthest reset seen so replica skew can't
                    // trigger a premature rollover.
                    status.remaining = remaining
                    if let incomingReset {
                        status.resetAt = Swift.max(status.resetAt ?? incomingReset, incomingReset)
                    }
                } else if let resetAt = status.resetAt, now() >= resetAt {
                    // A rise is real only once the window has actually reset.
                    status.remaining = remaining
                    status.resetAt = incomingReset ?? resetAt
                }
                // else: out-of-order stale reading mid-window → ignore.
            } else {
                status.remaining = remaining
                status.resetAt = incomingReset ?? status.resetAt
            }
        } else if let incomingReset {
            status.resetAt = Swift.max(status.resetAt ?? incomingReset, incomingReset)
        }

        byResource[resource] = status
    }

    /// The pool to surface in the UI: the main hourly "core" quota once seen,
    /// otherwise whichever pool most recently reported. Caller must hold `lock`.
    private var displayStatus: Status? {
        if let core = byResource["core"] { return core }
        if let last = lastResource { return byResource[last] }
        return nil
    }

    public var snapshot: Status {
        lock.lock(); defer { lock.unlock() }
        return displayStatus ?? Status()
    }

    /// "API 4987/5000" — nil until a live response has been seen.
    public var display: String? {
        lock.lock(); defer { lock.unlock() }
        guard let current = displayStatus, let remaining = current.remaining else { return nil }
        let limit = current.limit.map { "/\($0)" } ?? ""
        return "API \(remaining)\(limit)"
    }

    public var isLow: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let remaining = displayStatus?.remaining else { return false }
        return remaining < 100
    }
}
