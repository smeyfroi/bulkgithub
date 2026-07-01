import Foundation
import Testing
@testable import BulkGitHubKit

/// A test clock advanced by hand so the pacer's slot math is deterministic
/// without real sleeps.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ start: Date) { t = start }
    func advance(_ dt: TimeInterval) { lock.lock(); t += dt; lock.unlock() }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
}

@Suite("Write pacer")
struct WritePacerTests {
    // 1.5s spacing off an integer epoch stays exactly representable, so the
    // returned delays compare cleanly.
    @Test("successive mutating requests queue a minimum interval apart")
    func spacesSuccessiveWrites() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        // No-op sleep: we assert on the reserved delay, not wall-clock time.
        let pacer = WritePacer(minInterval: 1.5, now: { clock.now }, sleep: { _ in })

        // Three back-to-back calls at the same instant reserve 1.5s-spaced slots.
        #expect(try await pacer.waitForSlot() == 0)
        #expect(try await pacer.waitForSlot() == 1.5)
        #expect(try await pacer.waitForSlot() == 3.0)
    }

    @Test("a request after its slot has already passed waits no time")
    func noWaitWhenIdle() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let pacer = WritePacer(minInterval: 1.0, now: { clock.now }, sleep: { _ in })

        #expect(try await pacer.waitForSlot() == 0)
        // Real time moves well past the reserved next slot before the next call.
        clock.advance(5)
        #expect(try await pacer.waitForSlot() == 0)
    }
}
