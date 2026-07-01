import Foundation
import Testing
@testable import BulkGitHubKit

/// Pure-helper tests for the live GitHub client — the parts that don't need a
/// network round-trip. The head-filter format is the one that bricked live
/// runs: a bare branch is silently ignored by GitHub, so createPR's preflight
/// matched unrelated PRs and halted with a false "PR exists".
@Suite("Live GitHub client helpers")
struct GitHubClientTests {

    @Test("listPRs head filter is formatted as owner:branch")
    func headQueryValueFormat() {
        #expect(LiveGitHubClient.headQueryValue(repo: "geome/shelltridentmcpapi",
                                                head: "bulkgh/remove-legacy-deploy-key")
                == "geome:bulkgh/remove-legacy-deploy-key")
        // A bare/owner-less repo degrades to the bare branch rather than
        // producing a leading-colon value.
        #expect(LiveGitHubClient.headQueryValue(repo: "lonely-repo", head: "bulkgh/x") == "bulkgh/x")
    }

    @Test("merge retries transient 5xx/network errors, not definitive 4xx")
    func transientMergeErrorClassification() {
        // 5xx and network blips are ambiguous/transient → re-check + retry.
        #expect(LiveGitHubClient.isTransientMergeError(.http(502, "Bad Gateway")))
        #expect(LiveGitHubClient.isTransientMergeError(.http(503, "Service Unavailable")))
        #expect(LiveGitHubClient.isTransientMergeError(.network("timeout")))
        // 4xx are definitive failures → surface immediately, never retry.
        #expect(!LiveGitHubClient.isTransientMergeError(.http(409, "head moved")))
        #expect(!LiveGitHubClient.isTransientMergeError(.http(405, "not mergeable")))
        #expect(!LiveGitHubClient.isTransientMergeError(.rateLimited(retryAfter: 30, resetAt: nil)))
    }

    @Test("read retry classifier: 5xx retryable; rate-limit honored within cap; 4xx not")
    func readRetryClassifier() {
        #expect(LiveGitHubClient.isRetryableStatus(502))
        #expect(LiveGitHubClient.isRetryableStatus(503))
        #expect(!LiveGitHubClient.isRetryableStatus(404))
        #expect(!LiveGitHubClient.isRetryableStatus(409))

        let client = LiveGitHubClient(apiHost: "https://api.github.com",
                                      tokenProvider: { "tok" }, jitter: { 1 })
        #expect(client.retryDelay(for: .network("x"), attempt: 1) == 0.5)
        #expect(client.retryDelay(for: .rateLimited(retryAfter: 5, resetAt: nil), attempt: 1) == 5)
        // A rate-limit wait beyond the 60s cap fails fast (surface the quota).
        #expect(client.retryDelay(for: .rateLimited(retryAfter: 120, resetAt: nil), attempt: 1) == nil)
        #expect(client.retryDelay(for: .http(409, "head moved"), attempt: 1) == nil)
        #expect(client.retryDelay(for: .notFound("x"), attempt: 1) == nil)
    }

    @Test("backoff is exponential with full jitter, capped at 8s")
    func backoffSchedule() {
        let full = LiveGitHubClient(apiHost: "https://api.github.com",
                                    tokenProvider: { "tok" }, jitter: { 1 })  // jitter 1 → raw value
        #expect(full.backoffDelay(attempt: 1) == 0.5)
        #expect(full.backoffDelay(attempt: 2) == 1.0)
        #expect(full.backoffDelay(attempt: 3) == 2.0)
        #expect(full.backoffDelay(attempt: 4) == 4.0)
        #expect(full.backoffDelay(attempt: 5) == 8.0)
        #expect(full.backoffDelay(attempt: 6) == 8.0)   // capped
        let none = LiveGitHubClient(apiHost: "https://api.github.com",
                                    tokenProvider: { "tok" }, jitter: { 0 })
        #expect(none.backoffDelay(attempt: 3) == 0)
    }
}

/// Integration: drive fetch()'s retry loop through a stubbed URLSession to
/// confirm reads retry transient 5xx (to the budget) while writes do not.
// Serialized: the tests share StubURLProtocol's static request counter, so they
// must not run concurrently (Swift Testing parallelizes by default).
@Suite("GitHub client transient retry", .serialized)
struct GitHubClientRetryTests {

    private func stubbedClient() -> LiveGitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        // jitter 0 → zero backoff → the retry loop runs instantly.
        return LiveGitHubClient(apiHost: "https://api.github.com",
                                tokenProvider: { "tok" },
                                session: URLSession(configuration: config),
                                jitter: { 0 })
    }

    @Test("a read retries a transient 5xx up to the budget, then surfaces")
    func readRetriesThenSurfaces() async throws {
        StubURLProtocol.reset(status: 502)
        let client = stubbedClient()
        do {
            _ = try await client.getRepo(fullName: "owner/name")
            Issue.record("expected the read to throw after exhausting retries")
        } catch is GitHubClientError {}
        #expect(StubURLProtocol.requestCount == 4)   // 1 attempt + 3 retries
    }

    @Test("a transient 5xx that clears is retried through to success")
    func readRetriesThenSucceeds() async throws {
        StubURLProtocol.reset(status: 502, succeedAfter: 2,
                              successBody: #"{"full_name":"owner/name","default_branch":"main"}"#)
        let client = stubbedClient()
        let repo = try await client.getRepo(fullName: "owner/name")
        #expect(repo.fullName == "owner/name")
        #expect(StubURLProtocol.requestCount == 3)   // 502, 502, 200
    }

    @Test("a write does not retry a definitive (4xx) error")
    func writeDoesNotRetryDefinitiveError() async throws {
        // 422 is definitive, not transient — the write must surface after one
        // attempt, never re-issue.
        let posts = Counter()
        StubURLProtocol.respond { request in
            if request.httpMethod == "POST" { _ = posts.next(); return (422, "{}") }
            return (200, "[]")   // verify: no existing PR
        }
        let client = stubbedClient()
        do {
            _ = try await client.createPR(repo: "o/n", head: "bulkgh/x",
                                          base: "main", title: "t", body: "b")
            Issue.record("expected the write to throw on a 422")
        } catch is GitHubClientError {}
        #expect(posts.value == 1)   // no re-POST on a definitive error
    }

    @Test("a write that already landed is NOT re-issued — the re-check wins")
    func writeReChecksBeforeRetry() async throws {
        // POST /pulls 502s, but the verify GET /pulls finds the PR already open,
        // so createPR returns it without re-POSTing (no double-create).
        let posts = Counter()
        StubURLProtocol.respond { request in
            if request.httpMethod == "POST" { _ = posts.next(); return (502, "{}") }
            return (200, #"[{"number":7,"head":{"ref":"bulkgh/x"},"html_url":"https://github.com/o/n/pull/7","state":"open"}]"#)
        }
        let client = stubbedClient()
        let pr = try await client.createPR(repo: "o/n", head: "bulkgh/x",
                                           base: "main", title: "t", body: "b")
        #expect(pr.number == 7)     // came from the re-check, not a re-POST
        #expect(posts.value == 1)   // the POST ran exactly once
    }

    @Test("a write that hadn't landed is re-issued after the transient error")
    func writeRetriesThenSucceeds() async throws {
        let posts = Counter()
        StubURLProtocol.respond { request in
            guard request.httpMethod == "POST" else { return (200, "[]") }  // verify: no PR yet
            return posts.next() == 1
                ? (502, "{}")
                : (201, #"{"number":9,"head":{"ref":"bulkgh/x"},"html_url":"https://github.com/o/n/pull/9","state":"open"}"#)
        }
        let client = stubbedClient()
        let pr = try await client.createPR(repo: "o/n", head: "bulkgh/x",
                                           base: "main", title: "t", body: "b")
        #expect(pr.number == 9)
        #expect(posts.value == 2)   // re-issued exactly once
    }
}

/// Conditional-GET (ETag) caching: a repeated single-object read is re-issued
/// with If-None-Match, and a 304 replays the cached body without re-decoding a
/// fresh one. Uses its own URLProtocol (not StubURLProtocol) so it shares no
/// static state with the retry suite — the two suites run in parallel.
@Suite("GitHub client ETag caching", .serialized)
struct GitHubClientETagTests {
    private func cachingClient(cache: ETagCache) -> LiveGitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConditionalStubProtocol.self]
        return LiveGitHubClient(apiHost: "https://api.github.com",
                                tokenProvider: { "tok" },
                                session: URLSession(configuration: config),
                                etagCache: cache, jitter: { 0 })
    }

    @Test("a repeated read is issued conditionally and a 304 replays the cached body")
    func conditionalGetReplaysOn304() async throws {
        let body = #"{"full_name":"o/n","default_branch":"trunk"}"#
        ConditionalStubProtocol.respond { request in
            // The second call must carry the validator from the first response.
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" {
                return (304, [:], "")
            }
            return (200, ["Etag": "\"v1\""], body)
        }
        let cache = ETagCache()
        let client = cachingClient(cache: cache)

        let first = try await client.getRepo(fullName: "o/n")
        #expect(first.defaultBranch == "trunk")
        #expect(cache.count == 1)

        // The 304 carries no body, yet the repo still decodes — proof the cached
        // body was replayed as a synthetic 200.
        let second = try await client.getRepo(fullName: "o/n")
        #expect(second.fullName == "o/n")
        #expect(second.defaultBranch == "trunk")
        #expect(ConditionalStubProtocol.requestCount == 2)
    }

    @Test("a changed resource returns a fresh 200 and refreshes the cached ETag")
    func changedResourceRefreshesCache() async throws {
        let counter = Counter()
        ConditionalStubProtocol.respond { _ in
            // Always answer 200 with a new body/etag — the resource keeps changing,
            // so the server never returns 304.
            let n = counter.next()
            return (200, ["Etag": "\"v\(n)\""], #"{"full_name":"o/n","default_branch":"b\#(n)"}"#)
        }
        let cache = ETagCache()
        let client = cachingClient(cache: cache)

        let first = try await client.getRepo(fullName: "o/n")
        let second = try await client.getRepo(fullName: "o/n")
        #expect(first.defaultBranch == "b1")
        #expect(second.defaultBranch == "b2")   // fresh body, not a stale replay
        #expect(cache.count == 1)                // one URL, ETag refreshed in place
    }
}

/// A header-aware URLProtocol for the ETag suite: the responder returns
/// (statusCode, response headers, body) and can read the request's
/// If-None-Match. Isolated statics so it never races the retry suite.
final class ConditionalStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _count = 0
    private static var responder: ((URLRequest) -> (Int, [String: String], String))?

    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _count }

    static func respond(_ responder: @escaping (URLRequest) -> (Int, [String: String], String)) {
        lock.lock(); defer { lock.unlock() }
        _count = 0
        Self.responder = responder
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self._count += 1
        let responder = Self.responder
        Self.lock.unlock()
        let (code, extra, body) = responder?(request) ?? (200, [:], "{}")
        var headers = ["x-ratelimit-remaining": "100", "x-ratelimit-resource": "core"]
        for (key, value) in extra { headers[key] = value }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Thread-safe call counter for the retry tests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Returns `status` for requests until `succeedAfter` is exceeded, then 200 with
/// `successBody`. Drives the retry-loop integration tests.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _count = 0
    private static var status = 502
    private static var succeedAfter: Int?      // nil = always fail
    private static var successBody = "{}"
    private static var responder: ((URLRequest) -> (Int, String))?

    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _count }

    static func reset(status: Int, succeedAfter: Int? = nil, successBody: String = "{}") {
        lock.lock(); defer { lock.unlock() }
        _count = 0; responder = nil
        Self.status = status
        Self.succeedAfter = succeedAfter
        Self.successBody = successBody
    }

    /// Request-aware responder returning (statusCode, body) per request — lets
    /// the guarded-write tests answer the write POST and the verify GET differently.
    static func respond(_ responder: @escaping (URLRequest) -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }
        _count = 0
        Self.responder = responder
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self._count += 1
        let responder = Self.responder
        let canned: (Int, String) = {
            if let after = Self.succeedAfter, Self._count > after { return (200, Self.successBody) }
            return (Self.status, "{}")
        }()
        Self.lock.unlock()
        let (code, body) = responder?(request) ?? canned
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: ["x-ratelimit-remaining": "100",
                                                      "x-ratelimit-resource": "core"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
