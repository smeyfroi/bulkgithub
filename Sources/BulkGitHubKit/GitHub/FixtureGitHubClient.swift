import Foundation

/// In-memory GitHub client for offline development and tests.
/// Behaviour is fully deterministic: canned repos, file contents keyed by
/// repo/path, canned search results, and per-repo error injection.
public final class FixtureGitHubClient: GitHubClient, @unchecked Sendable {
    public var repos: [RepoRef]
    /// fullName -> path -> content
    public var contents: [String: [String: String]]
    /// Returned for any code search query.
    public var searchResults: [RepoRef]
    /// fullName -> error message thrown from getContent
    public var errorInjections: [String: String]
    /// Artificial latency per call, for cancellation tests and UI realism.
    public var delay: Duration

    private let lock = NSLock()
    private var _callLog: [String] = []
    public var callLog: [String] {
        lock.lock(); defer { lock.unlock() }
        return _callLog
    }

    public init(repos: [RepoRef] = [],
                contents: [String: [String: String]] = [:],
                searchResults: [RepoRef] = [],
                errorInjections: [String: String] = [:],
                delay: Duration = .zero) {
        self.repos = repos
        self.contents = contents
        self.searchResults = searchResults
        self.errorInjections = errorInjections
        self.delay = delay
    }

    private func record(_ call: String) {
        lock.lock(); defer { lock.unlock() }
        _callLog.append(call)
    }

    private func pause() async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
    }

    public func listOrgRepos(org: String) async throws -> [RepoRef] {
        record("listOrgRepos(\(org))")
        try await pause()
        return repos
    }

    public func searchCode(org: String, query: String) async throws -> [RepoRef] {
        record("searchCode(\(query))")
        try await pause()
        return searchResults
    }

    public func getContent(repo: String, path: String, ref: String?) async throws -> String? {
        record("getContent(\(repo), \(path))")
        try await pause()
        if let message = errorInjections[repo] {
            throw GitHubClientError.network(message)
        }
        guard let files = contents[repo] else {
            throw GitHubClientError.notFound("repository \(repo)")
        }
        return files[path]
    }

    public func listFiles(repo: String, ref: String?) async throws -> [String] {
        record("listFiles(\(repo))")
        try await pause()
        if let message = errorInjections[repo] {
            throw GitHubClientError.network(message)
        }
        guard let files = contents[repo] else {
            throw GitHubClientError.notFound("repository \(repo)")
        }
        return files.keys.sorted()
    }

    public func getRef(repo: String, ref: String) async throws -> String? {
        record("getRef(\(repo), \(ref))")
        try await pause()
        guard repos.contains(where: { $0.fullName == repo }) else { return nil }
        // Deterministic fake SHA derived from inputs.
        let basis = "\(repo)#\(ref)"
        let sha = basis.unicodeScalars.reduce(into: UInt64(5381)) { $0 = ($0 << 5) &+ $0 &+ UInt64($1.value) }
        return String(format: "%016llx%016llx", sha, ~sha)
    }

    public func listPRs(repo: String, head: String?, state: String) async throws -> [PullRequestRef] {
        record("listPRs(\(repo))")
        try await pause()
        return []
    }

    public func searchPRs(org: String, query: String) async throws -> [PullRequestRef] {
        record("searchPRs(\(query))")
        try await pause()
        return []
    }
}

extension FixtureGitHubClient {
    /// The demo dataset used by the app's fixture mode and the golden recipe test.
    /// Exercises every interesting path of a check script: clean matches, a
    /// value mismatch, an archived repo, a stale search hit whose file is gone,
    /// and a repo where content fetch fails.
    public static func demo() -> FixtureGitHubClient {
        let api = RepoRef(fullName: "geome/api-service")
        let web = RepoRef(fullName: "geome/web-frontend")
        let pipeline = RepoRef(fullName: "geome/data-pipeline", defaultBranch: "master")
        let legacy = RepoRef(fullName: "geome/legacy-batch", archived: true)
        let infra = RepoRef(fullName: "geome/infra-tools")
        let flaky = RepoRef(fullName: "geome/flaky-service")
        let docs = RepoRef(fullName: "geome/docs-site", isPrivate: false)

        let matchingYAML = """
        # production deployment
        account_id: "481832923858"
        region: eu-west-1
        stack: production
        """

        let differingYAML = """
        account_id: "999911112222"
        region: eu-west-1
        stack: production
        """

        return FixtureGitHubClient(
            repos: [api, web, pipeline, legacy, infra, flaky, docs],
            contents: [
                api.fullName: ["deploy/prod.yml": matchingYAML,
                               ".github/dependabot.yml": "version: 2\nupdates: []\n"],
                web.fullName: ["deploy/prod.yml": differingYAML],
                pipeline.fullName: ["deploy/prod.yml": matchingYAML],
                legacy.fullName: ["deploy/prod.yml": matchingYAML],
                infra.fullName: [:],  // stale search hit: repo exists, file absent
                flaky.fullName: ["deploy/prod.yml": matchingYAML], // unreachable: error injected
                docs.fullName: ["README.md": "# Docs\n"],
            ],
            searchResults: [api, web, pipeline, legacy, infra, flaky],
            errorInjections: [flaky.fullName: "connection reset by peer"]
        )
    }
}
