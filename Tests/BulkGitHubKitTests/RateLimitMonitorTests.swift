import Foundation
import Testing
@testable import BulkGitHubKit

/// The quota indicator is written from every response, and concurrent calls
/// land in any order. Within a pool, remaining only falls as the window is
/// consumed, so the monitor keeps the LOWEST reading and accepts a rise only
/// after the reset time has passed (a real rollover). It must NOT order
/// responses by reset timestamp — GitHub's distributed limiter reports
/// non-monotonic resets within a single pool (the live "frozen gauge" bug).
@Suite("Rate-limit monitor")
struct RateLimitMonitorTests {
    // Fixed "now" so rollover detection is deterministic.
    private let nowDate = Date(timeIntervalSince1970: 2_000_000_000)
    private func monitor() -> RateLimitMonitor {
        let now = nowDate
        return RateLimitMonitor(now: { now })
    }
    private var futureReset: Double { nowDate.timeIntervalSince1970 + 3600 }
    private var pastReset: Double { nowDate.timeIntervalSince1970 - 60 }

    private func response(resource: String = "core", remaining: Int?,
                          limit: Int? = 5000, reset: Double) -> HTTPURLResponse {
        var headers = ["x-ratelimit-reset": String(reset), "x-ratelimit-resource": resource]
        if let remaining { headers["x-ratelimit-remaining"] = String(remaining) }
        if let limit { headers["x-ratelimit-limit"] = String(limit) }
        return HTTPURLResponse(url: URL(string: "https://api.github.com")!,
                               statusCode: 200, httpVersion: nil, headerFields: headers)!
    }

    @Test("within a window remaining only falls; out-of-order higher readings are ignored")
    func keepsLowestWithinWindow() {
        let monitor = monitor()
        monitor.update(from: response(remaining: 4983, reset: futureReset))
        #expect(monitor.snapshot.remaining == 4983)
        // A stale, out-of-order HIGHER reading mid-window must not overwrite.
        monitor.update(from: response(remaining: 4999, reset: futureReset))
        #expect(monitor.snapshot.remaining == 4983)
        // Consumption continues downward.
        monitor.update(from: response(remaining: 4960, reset: futureReset))
        #expect(monitor.snapshot.remaining == 4960)
    }

    @Test("replica reset-skew within a pool must not freeze the gauge")
    func resetSkewDoesNotFreeze() {
        // Reproduces the live bug: the first reading carries a LATER reset than
        // the readings that follow (GitHub replicas disagree on the boundary by
        // ~minutes). The gauge must still track consumption downward, not latch.
        let monitor = monitor()
        monitor.update(from: response(remaining: 4983, reset: futureReset + 172))
        monitor.update(from: response(remaining: 4960, reset: futureReset))
        monitor.update(from: response(remaining: 4920, reset: futureReset))
        #expect(monitor.snapshot.remaining == 4920)
    }

    @Test("a real rollover (reset time elapsed) raises the quota again")
    func rolloverRaisesQuota() {
        let monitor = monitor()
        // Window whose reset is already in the past relative to `now`.
        monitor.update(from: response(remaining: 40, reset: pastReset))
        #expect(monitor.snapshot.remaining == 40)
        // A higher reading after the window has reset is accepted.
        monitor.update(from: response(remaining: 5000, reset: futureReset))
        #expect(monitor.snapshot.remaining == 5000)
    }

    @Test("a later-resetting pool (graphql) does not pollute the core gauge")
    func crossResourcePoolsAreIndependent() {
        let monitor = monitor()
        monitor.update(from: response(resource: "core", remaining: 4994, reset: futureReset))
        monitor.update(from: response(resource: "graphql", remaining: 4919, reset: futureReset + 135))
        monitor.update(from: response(resource: "core", remaining: 4765, reset: futureReset))
        #expect(monitor.snapshot.remaining == 4765)
        #expect(monitor.snapshot.limit == 5000)
    }

    @Test("the search pool (limit 30) does not pollute the displayed core gauge")
    func searchPoolDoesNotPolluteCore() {
        let monitor = monitor()
        monitor.update(from: response(resource: "core", remaining: 4900, reset: futureReset))
        monitor.update(from: response(resource: "search", remaining: 1, limit: 30, reset: futureReset))
        #expect(monitor.snapshot.remaining == 4900)
        #expect(monitor.snapshot.limit == 5000)
        #expect(monitor.display == "API 4900/5000")
    }

    @Test("reset countdown reports the time until the displayed pool's window rolls over")
    func resetCountdown() {
        let monitor = monitor()
        // Exhausted core pool whose window resets an hour out.
        monitor.update(from: response(remaining: 0, reset: futureReset))
        #expect(monitor.isLow)
        #expect(monitor.resetDisplay == "resets in 60 min")
    }

    @Test("reset countdown drops to seconds under a minute out")
    func resetCountdownSeconds() {
        let monitor = monitor()
        monitor.update(from: response(remaining: 0, reset: nowDate.timeIntervalSince1970 + 30))
        #expect(monitor.resetDisplay == "resets in 30s")
    }

    @Test("no reset countdown once the window has already passed")
    func resetCountdownPastWindow() {
        let monitor = monitor()
        monitor.update(from: response(remaining: 0, reset: pastReset))
        #expect(monitor.resetDisplay == nil)
    }
}
