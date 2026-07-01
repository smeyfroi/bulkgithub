import Foundation

/// Serialises and paces content-mutating requests (POST/PATCH/PUT/DELETE) to
/// respect GitHub's *secondary* rate limit. GitHub recommends waiting at least
/// one second between mutating requests and caps content-creating requests at
/// 80 per minute; bursting past that trips an opaque 403 that carries no
/// countdown header, so the only defense is pacing on our side. Reads are never
/// paced — they're cheap and pacing them would cripple large scans.
///
/// This addresses the per-minute burst limit, NOT the 500-content-requests/hour
/// ceiling: that one can only be respected by doing fewer writes or spreading
/// them across the reset window (a resume-across-reset run, handled elsewhere).
public actor WritePacer {
    private let minInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// The earliest instant the next mutating request may start.
    private var nextEarliest: Date?

    public init(minInterval: TimeInterval = 1.0,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
                }) {
        self.minInterval = max(0, minInterval)
        self.now = now
        self.sleep = sleep
    }

    /// Blocks until the caller may issue its mutating request, reserving the
    /// following slot *before* it sleeps so a second caller entering during the
    /// wait queues after this one rather than alongside it. Returns the delay
    /// waited (for tests/inspection). Cancellation-aware: a cancelled run
    /// pre-empts the sleep.
    @discardableResult
    public func waitForSlot() async throws -> TimeInterval {
        let current = now()
        let slot = Swift.max(current, nextEarliest ?? current)
        // Reserve synchronously (no await between read and write of
        // nextEarliest) so concurrent callers can't claim the same slot.
        nextEarliest = slot.addingTimeInterval(minInterval)
        let delay = slot.timeIntervalSince(current)
        if delay > 0 { try await sleep(delay) }
        return delay
    }
}
