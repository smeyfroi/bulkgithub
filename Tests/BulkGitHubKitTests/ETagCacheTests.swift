import Foundation
import Testing
@testable import BulkGitHubKit

@Suite("ETag cache")
struct ETagCacheTests {
    private func entry(_ etag: String, bytes: Int) -> ETagCache.Entry {
        ETagCache.Entry(etag: etag, data: Data(count: bytes), headers: [:],
                        url: URL(string: "https://api.github.com/x")!)
    }

    @Test("stores and returns an entry by key")
    func storesAndReturns() {
        let cache = ETagCache()
        cache.store(key: "a", entry: entry("\"v1\"", bytes: 10))
        #expect(cache.entry(for: "a")?.etag == "\"v1\"")
        #expect(cache.entry(for: "missing") == nil)
        #expect(cache.count == 1)
    }

    @Test("refreshing a key replaces it in place without growing the cache")
    func refreshInPlace() {
        let cache = ETagCache()
        cache.store(key: "a", entry: entry("\"v1\"", bytes: 10))
        cache.store(key: "a", entry: entry("\"v2\"", bytes: 10))
        #expect(cache.entry(for: "a")?.etag == "\"v2\"")
        #expect(cache.count == 1)
    }

    @Test("evicts the oldest entries once the byte budget is exceeded")
    func evictsOldestOverBudget() {
        // Budget holds two 40-byte bodies; a third pushes the oldest out (FIFO).
        let cache = ETagCache(maxBytes: 100)
        cache.store(key: "a", entry: entry("\"a\"", bytes: 40))
        cache.store(key: "b", entry: entry("\"b\"", bytes: 40))
        cache.store(key: "c", entry: entry("\"c\"", bytes: 40))   // total 120 > 100
        #expect(cache.entry(for: "a") == nil)                     // oldest evicted
        #expect(cache.entry(for: "b") != nil)
        #expect(cache.entry(for: "c") != nil)
        #expect(cache.count == 2)
    }

    @Test("a body larger than the whole budget is not cached")
    func skipsOversizeBody() {
        let cache = ETagCache(maxBytes: 100)
        cache.store(key: "big", entry: entry("\"big\"", bytes: 200))
        #expect(cache.entry(for: "big") == nil)
        #expect(cache.count == 0)
    }
}
