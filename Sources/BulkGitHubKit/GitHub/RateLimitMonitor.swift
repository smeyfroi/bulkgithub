import Foundation

/// Tracks the GitHub API quota from response headers
/// (x-ratelimit-remaining/limit/reset). Shared with the UI so operations
/// surface their budget as they run.
public final class RateLimitMonitor: @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        public var remaining: Int?
        public var limit: Int?
        public var resetAt: Date?
    }

    private let lock = NSLock()
    private var status = Status()

    public init() {}

    public func update(from response: HTTPURLResponse) {
        let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init)
        let limit = response.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init)
        let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init)
        guard remaining != nil || limit != nil else { return }
        lock.lock(); defer { lock.unlock() }
        if let remaining { status.remaining = remaining }
        if let limit { status.limit = limit }
        if let reset { status.resetAt = Date(timeIntervalSince1970: reset) }
    }

    public var snapshot: Status {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    /// "API 4 987/5 000" — nil until a live response has been seen.
    public var display: String? {
        let current = snapshot
        guard let remaining = current.remaining else { return nil }
        let limit = current.limit.map { "/\($0)" } ?? ""
        return "API \(remaining)\(limit)"
    }

    public var isLow: Bool {
        let current = snapshot
        guard let remaining = current.remaining else { return false }
        return remaining < 100
    }
}
