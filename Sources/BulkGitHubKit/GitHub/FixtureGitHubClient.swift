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

    // MARK: Write state (armed runs are exercised against fixtures)

    /// repo -> branch name -> sha, for branches created through this client.
    private var _branches: [String: [String: String]] = [:]
    /// "repo|branch" -> path -> content: copy-on-write overlay seeded from the
    /// default contents when the branch is created.
    private var _branchContents: [String: [String: String]] = [:]
    private var _pullRequests: [PullRequestRef] = []
    private var _nextPRNumber = 100

    /// Branches created through this client (test inspection).
    public var createdBranches: [String: [String: String]] {
        lock.lock(); defer { lock.unlock() }
        return _branches
    }

    /// PRs created through this client (test inspection).
    public var createdPRs: [PullRequestRef] {
        lock.lock(); defer { lock.unlock() }
        return _pullRequests
    }

    /// Content of a path as committed on a created branch (test inspection).
    public func branchContent(repo: String, branch: String, path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return _branchContents["\(repo)|\(branch)"]?[path]
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

    public func getRepo(fullName: String) async throws -> RepoRef {
        record("getRepo(\(fullName))")
        try await pause()
        guard let repo = repos.first(where: { $0.fullName == fullName }) else {
            throw GitHubClientError.notFound("repository \(fullName)")
        }
        return repo
    }

    public func getContent(repo: String, path: String, ref: String?) async throws -> String? {
        record("getContent(\(repo), \(path))")
        try await pause()
        if let message = errorInjections[repo] {
            throw GitHubClientError.network(message)
        }
        if let ref, let overlay = branchOverlay(repo: repo, branch: ref) {
            return overlay[path]
        }
        guard let files = contents[repo] else {
            throw GitHubClientError.notFound("repository \(repo)")
        }
        return files[path]
    }

    private func branchOverlay(repo: String, branch: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return _branchContents["\(repo)|\(branch)"]
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
        // Branches created through this client resolve to their stored sha.
        if ref.hasPrefix("heads/") {
            let name = String(ref.dropFirst("heads/".count))
            if let created = createdBranchSha(repo: repo, name: name) { return created }
            // Only default branches exist beyond created ones.
            if let repoRef = repos.first(where: { $0.fullName == repo }),
               name != repoRef.defaultBranch {
                return nil
            }
        }
        return Self.fakeSha("\(repo)#\(ref)")
    }

    private func createdBranchSha(repo: String, name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return _branches[repo]?[name]
    }

    public func listPRs(repo: String, head: String?, state: String) async throws -> [PullRequestRef] {
        record("listPRs(\(repo))")
        try await pause()
        return openPRs(repo: repo, head: head, state: state)
    }

    private func openPRs(repo: String, head: String?, state: String) -> [PullRequestRef] {
        lock.lock(); defer { lock.unlock() }
        return _pullRequests.filter { pr in
            pr.repo == repo
                && (head == nil || pr.headRef == head)
                && (state == "all" || pr.state == state)
        }
    }

    public func createBranch(repo: String, name: String, fromSha: String) async throws -> String {
        record("createBranch(\(repo), \(name))")
        try await pause()
        guard contents[repo] != nil || repos.contains(where: { $0.fullName == repo }) else {
            throw GitHubClientError.notFound("repository \(repo)")
        }
        return try doCreateBranch(repo: repo, name: name)
    }

    private func doCreateBranch(repo: String, name: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard _branches[repo]?[name] == nil else {
            throw GitHubClientError.http(422, "Reference already exists")
        }
        let sha = Self.fakeSha("\(repo)#heads/\(name)#created")
        _branches[repo, default: [:]][name] = sha
        _branchContents["\(repo)|\(name)"] = contents[repo] ?? [:]
        return sha
    }

    public func putContent(repo: String, path: String, content: String,
                           branch: String, message: String) async throws -> String {
        record("putContent(\(repo), \(path), \(branch))")
        try await pause()
        return try doPutContent(repo: repo, path: path, content: content, branch: branch)
    }

    private func doPutContent(repo: String, path: String, content: String,
                              branch: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard _branchContents["\(repo)|\(branch)"] != nil else {
            throw GitHubClientError.notFound("branch \(branch) in \(repo)")
        }
        _branchContents["\(repo)|\(branch)"]?[path] = content
        let commit = Self.fakeSha("\(repo)#\(branch)#\(path)#\(content.count)")
        _branches[repo]?[branch] = commit
        return commit
    }

    public func createPR(repo: String, head: String, base: String,
                         title: String, body: String) async throws -> PullRequestRef {
        record("createPR(\(repo), \(head))")
        try await pause()
        return try doCreatePR(repo: repo, head: head)
    }

    private func doCreatePR(repo: String, head: String) throws -> PullRequestRef {
        lock.lock(); defer { lock.unlock() }
        guard !_pullRequests.contains(where: { $0.repo == repo && $0.headRef == head && $0.state == "open" }) else {
            throw GitHubClientError.http(422, "A pull request already exists for \(head)")
        }
        let number = _nextPRNumber
        _nextPRNumber += 1
        let pr = PullRequestRef(repo: repo, number: number, headRef: head,
                                headSha: _branches[repo]?[head] ?? Self.fakeSha("\(repo)#\(head)"),
                                state: "open",
                                url: "https://github.com/\(repo)/pull/\(number)")
        _pullRequests.append(pr)
        return pr
    }

    public func getPR(repo: String, number: Int) async throws -> PullRequestRef {
        record("getPR(\(repo), #\(number))")
        try await pause()
        lock.lock(); defer { lock.unlock() }
        guard var pr = _pullRequests.first(where: { $0.repo == repo && $0.number == number }) else {
            throw GitHubClientError.notFound("PR #\(number) in \(repo)")
        }
        // Like the real API: an open PR's head sha tracks its branch.
        if pr.state == "open", let sha = _branches[repo]?[pr.headRef] {
            pr.headSha = sha
        }
        return pr
    }

    public func mergePR(repo: String, number: Int, expectedHeadSha: String) async throws -> String {
        record("mergePR(\(repo), #\(number))")
        try await pause()
        lock.lock(); defer { lock.unlock() }
        guard let index = _pullRequests.firstIndex(where: { $0.repo == repo && $0.number == number }) else {
            throw GitHubClientError.notFound("PR #\(number) in \(repo)")
        }
        guard _pullRequests[index].state == "open" else {
            throw GitHubClientError.http(405, "Pull request is not open")
        }
        let currentHead = _branches[repo]?[_pullRequests[index].headRef]
            ?? _pullRequests[index].headSha
        guard currentHead == expectedHeadSha else {
            // Mirrors GitHub's merge precondition failure.
            throw GitHubClientError.http(409, "Head branch was modified. Review and try the merge again.")
        }
        _pullRequests[index].state = "merged"
        _pullRequests[index].headSha = currentHead
        return Self.fakeSha("\(repo)#\(number)#merged")
    }

    public func closePR(repo: String, number: Int) async throws {
        record("closePR(\(repo), #\(number))")
        try await pause()
        lock.lock(); defer { lock.unlock() }
        guard let index = _pullRequests.firstIndex(where: { $0.repo == repo && $0.number == number }) else {
            throw GitHubClientError.notFound("PR #\(number) in \(repo)")
        }
        guard _pullRequests[index].state == "open" else {
            throw GitHubClientError.http(422, "Pull request is not open")
        }
        _pullRequests[index].state = "closed"
    }

    public func deleteBranch(repo: String, name: String) async throws {
        record("deleteBranch(\(repo), \(name))")
        try await pause()
        lock.lock(); defer { lock.unlock() }
        guard _branches[repo]?[name] != nil else {
            throw GitHubClientError.http(422, "Reference does not exist")
        }
        _branches[repo]?.removeValue(forKey: name)
        _branchContents.removeValue(forKey: "\(repo)|\(name)")
    }

    /// Deterministic fake SHA derived from inputs.
    private static func fakeSha(_ basis: String) -> String {
        let sha = basis.unicodeScalars.reduce(into: UInt64(5381)) { $0 = ($0 << 5) &+ $0 &+ UInt64($1.value) }
        return String(format: "%016llx%016llx", sha, ~sha)
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
        let api = RepoRef(fullName: "example-org/api-service")
        let web = RepoRef(fullName: "example-org/web-frontend")
        let pipeline = RepoRef(fullName: "example-org/data-pipeline", defaultBranch: "master")
        let legacy = RepoRef(fullName: "example-org/legacy-batch", archived: true)
        let infra = RepoRef(fullName: "example-org/infra-tools")
        let flaky = RepoRef(fullName: "example-org/flaky-service")
        let docs = RepoRef(fullName: "example-org/docs-site", isPrivate: false)

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

        // The deploy-key worked example (plan v2): the string to find — and
        // delete line-wise — appears once in YAML and once in JSON with the
        // key-value pair LAST in its object, so the deletion must also strip
        // the trailing comma on the line above.
        let deployKeyYAML = """
        region: eu-west-1
        deployKey: legacy-deploy-key-2019
        instanceType: m5.large
        """

        let deployKeyJSON = """
        {
          "stack": "web-frontend",
          "region": "eu-west-1",
          "deployKey": "legacy-deploy-key-2019"
        }
        """

        // The README/license worked example (the golden recipe pair): one
        // README already carries the section (skip), several lack it
        // (matches — including the master-default repo), one repo has no
        // README at all (skip), and the flaky repo's fetch fails.
        let licensedREADME = """
        # api-service

        Internal service.

        # License

        MIT
        """

        // The project.json key/value scenario (Find YAML key/value recipe):
        // two rails projects (matches), one react (value differs), the rest
        // have no project.json.
        let railsProject = """
        {
          "name": "service",
          "type": "rails"
        }
        """
        let reactProject = """
        {
          "name": "web-frontend",
          "type": "react"
        }
        """

        // The glob key/value scenario (Find YAML key/value under path glob):
        // RetentionInDays matches in api (top-level) and pipeline (nested in
        // a CloudFormation .template with custom tags — the real-world
        // shape), differs in web, absent elsewhere.
        let retention14 = """
        logGroup: app
        RetentionInDays: 14
        """
        let retention30 = """
        logGroup: web
        RetentionInDays: 30
        """
        let cloudFormationTemplate = """
        AWSTemplateFormatVersion: '2010-09-09'
        Resources:
          LogGroup:
            Type: AWS::Logs::LogGroup
            Properties:
              RetentionInDays: 14
              LogGroupName: "/example-org/data-pipeline"
            DeletionPolicy: RetainExceptOnCreate
          # >>> PG14 TO BE DELETED
          OldParameterGroup:
            Type: AWS::RDS::DBClusterParameterGroup
            Properties:
              Description: Optimised postgres14 parameter group
              Family: aurora-postgresql14
          # <<< PG14 TO BE DELETED
          PipelineDomain:
            Type: AWS::Route53::RecordSet
            Properties:
              Name: data-pipeline.example.com
              ResourceRecords:
              - !GetAtt
                - PipelineCluster
                - Endpoint.Address
              Type: CNAME
              TTL: 300
        """

        // The marker-block scenario (Delete lines between marker text): the
        // recipe's default glob is deploy/*.template, hitting the annotated
        // PG14 block in pipeline's CloudFormation template. The yml marker
        // blocks in api and web sit outside that glob — they're there for
        // widening the glob param to deploy/** and catching more.
        let markedCron = """
        jobs:
          # >>>
          - legacy_export
          # <<<
          - daily_report
        """
        let markedMaintenance = """
        window: nightly
        # >>>
        drainQueues: true
        # <<<
        notify: ops
        """

        return FixtureGitHubClient(
            repos: [api, web, pipeline, legacy, infra, flaky, docs],
            contents: [
                api.fullName: ["deploy/prod.yml": matchingYAML,
                               ".github/dependabot.yml": "version: 2\nupdates: []\n",
                               "README.md": licensedREADME,
                               "project.json": railsProject,
                               "deploy/logging.yml": retention14,
                               "deploy/cron.yml": markedCron],
                web.fullName: ["deploy/prod.yml": differingYAML,
                               "deploy/infra.json": deployKeyJSON,
                               "README.md": "# web-frontend\n\nCustomer-facing frontend.\n",
                               "project.json": reactProject,
                               "deploy/logging.yml": retention30,
                               "deploy/maintenance.yml": markedMaintenance],
                pipeline.fullName: ["deploy/prod.yml": matchingYAML,
                                    "deploy/keys.yml": deployKeyYAML,
                                    "deploy/prod_permanent.template": cloudFormationTemplate,
                                    "README.md": "# data-pipeline\n",
                                    "project.json": railsProject],
                legacy.fullName: ["deploy/prod.yml": matchingYAML,
                                  "README.md": "# legacy-batch\n"],
                infra.fullName: [:],  // stale search hit: repo exists, file absent
                flaky.fullName: ["deploy/prod.yml": matchingYAML,
                                 "README.md": "# flaky-service\n"], // unreachable: error injected
                docs.fullName: ["README.md": "# Docs\n"],
            ],
            searchResults: [api, web, pipeline, legacy, infra, flaky],
            errorInjections: [flaky.fullName: "connection reset by peer"]
        )
    }
}
