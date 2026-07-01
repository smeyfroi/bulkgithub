import Foundation
import Testing
@testable import BulkGitHubKit

/// A stub that answers the GraphQL POST with a canned body and counts requests.
/// Isolated statics so it never races other suites under parallel execution.
final class GraphQLStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _count = 0
    private static var body = "{\"data\":{}}"

    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _count }

    static func reset(body: String) {
        lock.lock(); defer { lock.unlock() }
        _count = 0; Self.body = body
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock(); Self._count += 1; let body = Self.body; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["x-ratelimit-remaining": "4999",
                                                      "x-ratelimit-resource": "graphql"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("GraphQL batched reads", .serialized)
struct GraphQLBatchTests {
    private func client() -> LiveGitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GraphQLStubProtocol.self]
        return LiveGitHubClient(apiHost: "https://api.github.com",
                                tokenProvider: { "tok" },
                                session: URLSession(configuration: config),
                                jitter: { 0 })
    }

    @Test("a batch resolves to texts aligned with input, with null for a missing blob")
    func alignedWithNulls() async throws {
        GraphQLStubProtocol.reset(body: #"""
        {"data":{"r0":{"object":{"text":"alpha"}},"r1":{"object":null},"r2":{"object":{"text":"gamma"}}}}
        """#)
        let results = try await client().getContentBatch([
            ContentRequest(repo: "o/a", path: "f"),
            ContentRequest(repo: "o/b", path: "f"),
            ContentRequest(repo: "o/c", path: "f"),
        ])
        #expect(results == ["alpha", nil, "gamma"])
        #expect(GraphQLStubProtocol.requestCount == 1)   // one round-trip for three files
    }

    @Test("more than a chunk's worth of requests splits into multiple queries")
    func chunksLargeBatches() async throws {
        // A canned 100-alias response; each chunk reads only the aliases it asked
        // for (r0…), so one fixed body serves both the 100- and 20-item chunk.
        let aliases = (0..<100).map { "\"r\($0)\":{\"object\":{\"text\":\"x\"}}" }.joined(separator: ",")
        GraphQLStubProtocol.reset(body: "{\"data\":{\(aliases)}}")
        let requests = (0..<120).map { ContentRequest(repo: "o/r\($0)", path: "f") }
        let results = try await client().getContentBatch(requests)
        #expect(results.count == 120)
        #expect(results.allSatisfy { $0 == "x" })
        #expect(GraphQLStubProtocol.requestCount == 2)   // 100 + 20
    }

    @Test("a malformed repo yields nil and issues no query when the whole chunk is invalid")
    func malformedRepoSkipped() async throws {
        GraphQLStubProtocol.reset(body: "{\"data\":{}}")
        let results = try await client().getContentBatch([ContentRequest(repo: "no-slash", path: "f")])
        #expect(results == [nil])
        #expect(GraphQLStubProtocol.requestCount == 0)   // nothing valid to fetch
    }

    @Test("an empty batch returns empty without a round-trip")
    func emptyBatch() async throws {
        GraphQLStubProtocol.reset(body: "{\"data\":{}}")
        let results = try await client().getContentBatch([])
        #expect(results.isEmpty)
        #expect(GraphQLStubProtocol.requestCount == 0)
    }
}
