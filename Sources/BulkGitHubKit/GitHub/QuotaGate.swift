import Foundation

/// Proactive rate-limit gate. Every GitHub host call clears through this before
/// executing, so a run *glides to a stop and resumes* instead of charging into a
/// hard 403 and failing. It reads the `RateLimitMonitor` (updated on every
/// response) and, when the displayed pool is nearly spent, pauses until the
/// window resets.
///
/// Resume policy (the "cap the wait" contract):
///  • reset within `autoResumeCap` → auto-resume the instant the window rolls.
///  • reset beyond the cap → *held*: don't auto-wait a long stretch. Surface it
///    and wait for a manual resume or cancel. (The host decides how to notify.)
///
/// Cancellation rides the existing `CancelBox`: the wait polls `isCancelled` and
/// throws `CancellationError` (which the host maps to a cancelled run), so the
/// Stop button pre-empts a pause. Paused time is reported via
/// `totalPausedSeconds` so the run's wall-clock watchdog can exclude it — a
/// deliberate pause is not a hung run.
public final class QuotaGate: @unchecked Sendable {
    public struct PauseState: Sendable, Equatable {
        /// When the exhausted pool's window rolls over.
        public var resumeAt: Date
        /// true when the reset is beyond the auto-wait cap, so the run is
        /// holding for a manual resume rather than auto-waiting.
        public var heldForManual: Bool
    }

    /// Decision for a single clearance check — the pure, testable core.
    enum Clearance: Equatable {
        case clear
        case wait(resumeAt: Date, exceedsCap: Bool)
    }

    private let rateLimit: RateLimitMonitor
    /// Pause once the displayed pool drops to/below this, leaving headroom above
    /// the concurrency bound so in-flight calls can't overshoot to a real 403.
    private let floor: Int
    private let autoResumeCap: TimeInterval
    private let tick: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private let lock = NSLock()
    private var _pause: PauseState?
    private var resumeRequested = false
    private var heldLatched = false
    private var heldResumeAt: Date?
    private var waitStartedAt: Date?
    private var _accumulatedPaused: TimeInterval = 0

    public init(rateLimit: RateLimitMonitor,
                floor: Int = 50,
                autoResumeCap: TimeInterval = 15 * 60,
                tick: TimeInterval = 0.5,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
                }) {
        self.rateLimit = rateLimit
        self.floor = floor
        self.autoResumeCap = autoResumeCap
        self.tick = tick
        self.now = now
        self.sleep = sleep
    }

    /// Clear all pause state — call at the start of each run so a prior run's
    /// paused-time and held latch never leak forward.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        _pause = nil
        resumeRequested = false
        heldLatched = false
        heldResumeAt = nil
        waitStartedAt = nil
        _accumulatedPaused = 0
    }

    /// Force the run past a pause (manual "Resume now").
    public func resumeNow() {
        lock.lock(); defer { lock.unlock() }
        resumeRequested = true
    }

    /// The current pause, or nil when running — read by the UI.
    public var pauseState: PauseState? {
        lock.lock(); defer { lock.unlock() }
        return _pause
    }

    /// Total seconds spent paused so far, including any wait in progress — the
    /// run's wall-clock watchdog subtracts this so a pause isn't seen as a hang.
    public var totalPausedSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let inProgress = waitStartedAt.map { now().timeIntervalSince($0) } ?? 0
        return _accumulatedPaused + max(0, inProgress)
    }

    /// The pure decision: given the current quota, should a call proceed?
    func decide(now moment: Date) -> Clearance {
        let status = rateLimit.snapshot
        guard let remaining = status.remaining, let resetAt = status.resetAt else { return .clear }
        if remaining > floor { return .clear }
        if resetAt <= moment { return .clear }   // window already rolled
        return .wait(resumeAt: resetAt, exceedsCap: resetAt.timeIntervalSince(moment) > autoResumeCap)
    }

    /// Block until this call may proceed. Returns immediately when quota is
    /// healthy; otherwise pauses per the resume policy. Throws `CancellationError`
    /// if the run is cancelled while waiting.
    public func awaitClearance(isCancelled: @Sendable () -> Bool) async throws {
        while true {
            if isCancelled() { endWait(); throw CancellationError() }
            let moment = now()

            // A manual resume consumes the wait and lets this call try again;
            // if quota is still spent the next loop re-pauses appropriately.
            if takeResumeRequested() {
                endWait()
                return
            }

            if heldLatched {
                // Beyond-cap hold: never auto-release — wait for resume or cancel.
                beginWaitIfNeeded(at: moment)
                publish(PauseState(resumeAt: heldResumeAt ?? moment, heldForManual: true))
                try await sleep(tick)
                continue
            }

            switch decide(now: moment) {
            case .clear:
                endWait()
                return
            case .wait(let resumeAt, let exceedsCap):
                beginWaitIfNeeded(at: moment)
                if exceedsCap {
                    heldLatched = true
                    heldResumeAt = resumeAt
                }
                publish(PauseState(resumeAt: resumeAt, heldForManual: exceedsCap))
                try await sleep(tick)
            }
        }
    }

    // MARK: - State helpers

    private func takeResumeRequested() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard resumeRequested else { return false }
        resumeRequested = false
        heldLatched = false
        heldResumeAt = nil
        return true
    }

    private func beginWaitIfNeeded(at moment: Date) {
        lock.lock(); defer { lock.unlock() }
        if waitStartedAt == nil { waitStartedAt = moment }
    }

    private func publish(_ state: PauseState) {
        lock.lock(); defer { lock.unlock() }
        _pause = state
    }

    /// Close out any in-progress wait: bank its elapsed time and clear the
    /// published pause so the UI shows the run moving again.
    private func endWait() {
        lock.lock(); defer { lock.unlock() }
        if let started = waitStartedAt {
            _accumulatedPaused += max(0, now().timeIntervalSince(started))
            waitStartedAt = nil
        }
        heldLatched = false
        heldResumeAt = nil
        _pause = nil
    }
}
