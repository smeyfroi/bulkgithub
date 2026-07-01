import Foundation
import Testing
@testable import BulkGitHubKit

/// A hand-advanced clock so the gate's pause/resume timing is deterministic.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ start: Date) { t = start }
    func advance(_ dt: TimeInterval) { lock.lock(); t += dt; lock.unlock() }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
}

@Suite("Quota gate")
struct QuotaGateTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func response(remaining: Int, resetOffset: TimeInterval) -> HTTPURLResponse {
        let headers = ["x-ratelimit-remaining": String(remaining),
                       "x-ratelimit-limit": "5000",
                       "x-ratelimit-reset": String(start.timeIntervalSince1970 + resetOffset),
                       "x-ratelimit-resource": "core"]
        return HTTPURLResponse(url: URL(string: "https://api.github.com")!,
                               statusCode: 200, httpVersion: nil, headerFields: headers)!
    }

    private func monitor(remaining: Int, resetOffset: TimeInterval) -> RateLimitMonitor {
        let fixed = start
        let m = RateLimitMonitor(now: { fixed })
        m.update(from: response(remaining: remaining, resetOffset: resetOffset))
        return m
    }

    // MARK: decide() — the pure core

    @Test("healthy quota clears immediately")
    func healthyClears() {
        let gate = QuotaGate(rateLimit: monitor(remaining: 4000, resetOffset: 3600),
                             floor: 25, now: { start })
        #expect(gate.decide(now: start) == .clear)
    }

    @Test("spent quota resetting within the cap waits with auto-resume")
    func spentWithinCapWaitsAuto() {
        let gate = QuotaGate(rateLimit: monitor(remaining: 5, resetOffset: 300),
                             floor: 25, autoResumeCap: 900, now: { start })
        #expect(gate.decide(now: start)
                == .wait(resumeAt: start.addingTimeInterval(300), exceedsCap: false))
    }

    @Test("spent quota resetting beyond the cap holds for manual resume")
    func spentBeyondCapHolds() {
        let gate = QuotaGate(rateLimit: monitor(remaining: 5, resetOffset: 3600),
                             floor: 25, autoResumeCap: 900, now: { start })
        #expect(gate.decide(now: start)
                == .wait(resumeAt: start.addingTimeInterval(3600), exceedsCap: true))
    }

    @Test("a reset already in the past clears — the window rolled")
    func pastResetClears() {
        let gate = QuotaGate(rateLimit: monitor(remaining: 5, resetOffset: -60),
                             floor: 25, now: { start })
        #expect(gate.decide(now: start) == .clear)
    }

    // MARK: awaitClearance() — the async loop

    @Test("an in-cap pause auto-resumes at the reset and banks the paused time")
    func autoResumesAtReset() async throws {
        let clock = MutableClock(start)
        // No-op sleep that advances the virtual clock, so time passes without
        // real waiting and the loop terminates deterministically at the reset.
        let gate = QuotaGate(rateLimit: monitor(remaining: 5, resetOffset: 5),
                             floor: 25, autoResumeCap: 900, tick: 0.5,
                             now: { clock.now }, sleep: { clock.advance($0) })
        try await gate.awaitClearance(isCancelled: { false })
        #expect(gate.totalPausedSeconds == 5.0)
        #expect(gate.pauseState == nil)
    }

    @Test("cancellation throws out of a wait")
    func cancelThrows() async {
        let gate = QuotaGate(rateLimit: monitor(remaining: 5, resetOffset: 3600),
                             floor: 25, now: { start }, sleep: { _ in })
        await #expect(throws: CancellationError.self) {
            try await gate.awaitClearance(isCancelled: { true })
        }
    }

    @Test("resume-now releases a held (beyond-cap) pause")
    func resumeNowReleases() async throws {
        let gate = QuotaGate(rateLimit: monitor(remaining: 5, resetOffset: 3600),
                             floor: 25, autoResumeCap: 900, now: { start }, sleep: { _ in })
        gate.resumeNow()   // the next clearance check consumes it and proceeds
        try await gate.awaitClearance(isCancelled: { false })
        #expect(gate.pauseState == nil)
    }
}
