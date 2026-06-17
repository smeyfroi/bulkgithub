import Foundation

/// Surfaces in-flight transient-retry activity from the GitHub client to the UI,
/// mirroring RateLimitMonitor's inject-and-read pattern: the client updates it
/// deep inside fetch()/merge/write retries (off the main actor, NSLock-guarded),
/// and AppModel reads `display` to show a "retrying…" line so a run grinding
/// through 502s doesn't look hung.
///
/// Activity is keyed per call (a UUID) because up to `maxConcurrentHostCalls`
/// fetches run in parallel — a single scalar would let one call's retries
/// flicker against another's. `display` surfaces the deepest-attempt one.
public final class RetryMonitor: @unchecked Sendable {
    public struct Activity: Sendable, Equatable {
        public var label: String
        public var attempt: Int
        public var maxAttempts: Int
        public init(label: String, attempt: Int, maxAttempts: Int) {
            self.label = label
            self.attempt = attempt
            self.maxAttempts = maxAttempts
        }
    }

    private let lock = NSLock()
    private var inFlight: [UUID: Activity] = [:]
    private var _total = 0

    public init() {}

    /// Record that a call is about to back off before its next attempt.
    public func begin(id: UUID, _ activity: Activity) {
        lock.lock(); defer { lock.unlock() }
        inFlight[id] = activity
        _total += 1
    }

    /// Clear a call's activity on success or final failure.
    public func clear(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        inFlight.removeValue(forKey: id)
    }

    /// Total retry attempts ever recorded — snapshot before/after a run to tell
    /// whether it hit retries (drives the completion notification).
    public var totalRetries: Int {
        lock.lock(); defer { lock.unlock() }
        return _total
    }

    /// The single line to show in the footer; nil when nothing is retrying.
    public var display: String? {
        lock.lock(); defer { lock.unlock() }
        guard let deepest = inFlight.values.max(by: { $0.attempt < $1.attempt }) else { return nil }
        let more = inFlight.count > 1 ? " (+\(inFlight.count - 1) more)" : ""
        return "Retrying GitHub — \(deepest.label) \(deepest.attempt)/\(deepest.maxAttempts)\(more)"
    }
}
