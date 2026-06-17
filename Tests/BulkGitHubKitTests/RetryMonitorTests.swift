import Foundation
import Testing
@testable import BulkGitHubKit

@Suite("Retry monitor")
struct RetryMonitorTests {
    @Test("display surfaces the deepest in-flight attempt and clears when empty")
    func displayAndTotals() {
        let monitor = RetryMonitor()
        #expect(monitor.display == nil)

        let a = UUID(), b = UUID()
        monitor.begin(id: a, .init(label: "o/r", attempt: 2, maxAttempts: 4))
        #expect(monitor.display == "Retrying GitHub — o/r 2/4")

        // A second concurrent retry, deeper: it leads, with a "+N more" tail.
        monitor.begin(id: b, .init(label: "x/y", attempt: 3, maxAttempts: 4))
        #expect(monitor.display == "Retrying GitHub — x/y 3/4 (+1 more)")

        monitor.clear(id: b)
        #expect(monitor.display == "Retrying GitHub — o/r 2/4")
        monitor.clear(id: a)
        #expect(monitor.display == nil)

        #expect(monitor.totalRetries == 2)   // two begins, cumulative
    }
}
