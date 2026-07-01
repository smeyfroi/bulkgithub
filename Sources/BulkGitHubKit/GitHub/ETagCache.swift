import Foundation

/// In-memory ETag store for conditional GETs. GitHub does NOT count a
/// conditional request against the primary rate limit when it returns 304 Not
/// Modified, so caching ETags and replaying the cached body on a 304 makes
/// re-scans and resumes nearly free against quota — the biggest lever for a
/// tool that re-reads the same org repeatedly.
///
/// It is server-authoritative and so can never serve stale data: a 304 means
/// the resource is byte-identical to what we cached, and any change makes the
/// server return a fresh 200 (with a new ETag) instead.
///
/// Session-lived and bounded by total body bytes (FIFO eviction) — contents and
/// git-tree bodies can be large, so memory is capped directly rather than by a
/// count of entries.
public final class ETagCache: @unchecked Sendable {
    public struct Entry: Sendable {
        public let etag: String
        public let data: Data
        /// The 200 response's headers, preserved so a replay reconstructs a
        /// faithful response (e.g. the Link header, were paginated GETs ever
        /// cached).
        public let headers: [String: String]
        public let url: URL

        public init(etag: String, data: Data, headers: [String: String], url: URL) {
            self.etag = etag
            self.data = data
            self.headers = headers
            self.url = url
        }
    }

    private let lock = NSLock()
    private let maxBytes: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []          // insertion order; front = oldest
    private var totalBytes = 0

    public init(maxBytes: Int = 64 * 1024 * 1024) {
        self.maxBytes = max(1, maxBytes)
    }

    public func entry(for key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    /// Store (or refresh) the cached body for `key`, evicting oldest entries
    /// until the byte budget holds. A body larger than the whole budget is not
    /// cached (it would evict everything and still not fit).
    public func store(key: String, entry: Entry) {
        guard entry.data.count <= maxBytes else { return }
        lock.lock(); defer { lock.unlock() }
        if let existing = entries.removeValue(forKey: key) {
            totalBytes -= existing.data.count
            if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        }
        entries[key] = entry
        order.append(key)
        totalBytes += entry.data.count
        while totalBytes > maxBytes, let oldest = order.first {
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalBytes -= removed.data.count
            }
        }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
