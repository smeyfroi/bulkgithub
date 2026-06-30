import Foundation

/// URLSession-backed GitHub REST client.
///
/// The app defaults to fixture mode and no automated test performs live
/// calls. The token is supplied by a provider closure so it stays in
/// Keychain and never enters script space.
public final class LiveGitHubClient: GitHubClient, @unchecked Sendable {
    public typealias TokenProvider = @Sendable () -> String?

    /// Kill switch for live writes. Flipped to true (2026-06-11, for 0.4.0)
    /// after the full check → update → apply → approve → merge/cancel loop
    /// was rehearsed against fixtures with every guard exercised. Writes
    /// remain reachable ONLY through the engine's armed bindings (repo
    /// selection, plan conformance, drift guard, idempotency) behind the
    /// explicit arming confirmation in the app. Set back to false to make a
    /// provably-inert build.
    public static let liveWritesEnabled = true

    private let apiHost: URL
    private let tokenProvider: TokenProvider
    private let session: URLSession
    private let rateLimit: RateLimitMonitor?
    private let retry: RetryMonitor?
    /// Backoff jitter source (returns 0...1), injectable so the retry schedule
    /// is deterministic in tests.
    private let jitter: @Sendable () -> Double

    /// Dedicated session config for GitHub REST — built fresh (not `.shared`) so
    /// a wedged connection (#14) can be torn down by minting a new session, and
    /// ephemeral/no-cache so a stale cached GET never replays old x-ratelimit-*
    /// headers into the quota monitor.
    public static func makeConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 180
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return cfg
    }

    public static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    public init(apiHost: String, tokenProvider: @escaping TokenProvider,
                session: URLSession = LiveGitHubClient.makeSession(), rateLimit: RateLimitMonitor? = nil,
                retry: RetryMonitor? = nil,
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.apiHost = URL(string: apiHost) ?? URL(string: "https://api.github.com")!
        self.tokenProvider = tokenProvider
        self.session = session
        self.rateLimit = rateLimit
        self.retry = retry
        self.jitter = jitter
    }

    // MARK: Requests

    private func request(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: apiHost.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else {
            throw GitHubClientError.invalidResponse("bad URL for \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw GitHubClientError.invalidResponse("bad URL for \(path)")
        }
        var request = URLRequest(url: url)
        guard let token = tokenProvider(), !token.isEmpty else {
            throw GitHubClientError.missingCredentials
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    // MARK: Transient-failure retry (idempotent reads)

    private static let maxReadAttempts = 4
    private static let readRetryDeadline: TimeInterval = 30   // per-call ceiling
    private static let rateLimitWaitCap: TimeInterval = 60    // beyond this, fail fast

    /// A returned status worth retrying for a read — a server-side 5xx.
    static func isRetryableStatus(_ code: Int) -> Bool { (500...599).contains(code) }

    /// A short label for the retry footer, derived from the request path:
    /// "owner/repo" for repo calls, "search", else "GitHub".
    static func retryLabel(_ request: URLRequest) -> String {
        let parts = (request.url?.path ?? "").split(separator: "/").map(String.init)
        if parts.count >= 3, parts[0] == "repos" { return "\(parts[1])/\(parts[2])" }
        if parts.first == "search" { return "search" }
        return "GitHub"
    }

    /// Seconds to wait before retrying a thrown read error, or nil if it is not
    /// retryable (or a rate-limit wait would exceed the cap → surface instead).
    func retryDelay(for error: GitHubClientError, attempt: Int) -> TimeInterval? {
        switch error {
        case .network:
            return backoffDelay(attempt: attempt)
        case .rateLimited(let retryAfter, _):
            if let retryAfter { return retryAfter <= Self.rateLimitWaitCap ? retryAfter : nil }
            return min(backoffDelay(attempt: attempt), Self.rateLimitWaitCap)
        default:
            return nil
        }
    }

    /// Exponential backoff with full jitter: base 0.5s, ×2 per attempt, cap 8s.
    func backoffDelay(attempt: Int) -> TimeInterval {
        let raw = min(8.0, 0.5 * pow(2.0, Double(attempt - 1)))
        return jitter() * raw
    }

    private static func nanos(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    // MARK: Guarded write retry

    /// Retries a value-returning WRITE on a transient (5xx/network) error, but
    /// only after `verify` confirms it did NOT already land — a transient error
    /// can mask a write that actually succeeded, so a blind re-issue could act
    /// twice. `verify` returns the result if the write already happened, else nil.
    private func withWriteRetry<T>(label: String = "a write",
                                   verify: () async throws -> T?,
                                   perform: () async throws -> T) async throws -> T {
        let id = UUID()
        defer { retry?.clear(id: id) }
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await perform()
            } catch let error as GitHubClientError {
                if let landed = try? await verify() { return landed }
                guard Self.isTransientMergeError(error), attempt < 3 else { throw error }
                retry?.begin(id: id, .init(label: label, attempt: attempt + 1, maxAttempts: 3))
                try await Task.sleep(nanoseconds: Self.nanos(backoffDelay(attempt: attempt)))
            }
        }
    }

    /// As `withWriteRetry`, for void-returning writes. `landed` returns true when
    /// a re-check shows the write already took effect.
    private func withVoidWriteRetry(label: String = "a write",
                                    landed: () async throws -> Bool,
                                    perform: () async throws -> Void) async throws {
        let id = UUID()
        defer { retry?.clear(id: id) }
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await perform(); return
            } catch let error as GitHubClientError {
                if (try? await landed()) == true { return }
                guard Self.isTransientMergeError(error), attempt < 3 else { throw error }
                retry?.begin(id: id, .init(label: label, attempt: attempt + 1, maxAttempts: 3))
                try await Task.sleep(nanoseconds: Self.nanos(backoffDelay(attempt: attempt)))
            }
        }
    }

    /// Retry driver: idempotent reads (GET) retry transient 5xx / network /
    /// rate-limit errors with bounded backoff; writes (non-GET) pass straight to
    /// performFetch — they are guarded with per-endpoint re-checks instead,
    /// because a blind re-issue could act twice. Backoff sleeps are
    /// cancellation-aware (Task.sleep), so the run watchdog can pre-empt them.
    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isRead = (request.httpMethod ?? "GET").uppercased() == "GET"
        guard isRead else { return try await performFetch(request) }

        let id = UUID()
        let label = Self.retryLabel(request)
        defer { retry?.clear(id: id) }
        let deadline = Date().addingTimeInterval(Self.readRetryDeadline)
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, http) = try await performFetch(request)
                // 5xx is surfaced as a returned status here (fetchJSON turns it
                // into .http later) — retry while attempts and time remain.
                if Self.isRetryableStatus(http.statusCode), attempt < Self.maxReadAttempts {
                    let delay = backoffDelay(attempt: attempt)
                    guard Date().addingTimeInterval(delay) < deadline else { return (data, http) }
                    retry?.begin(id: id, .init(label: label, attempt: attempt + 1, maxAttempts: Self.maxReadAttempts))
                    try await Task.sleep(nanoseconds: Self.nanos(delay))
                    continue
                }
                return (data, http)
            } catch let error as GitHubClientError {
                guard let delay = retryDelay(for: error, attempt: attempt),
                      attempt < Self.maxReadAttempts,
                      Date().addingTimeInterval(delay) < deadline else { throw error }
                retry?.begin(id: id, .init(label: label, attempt: attempt + 1, maxAttempts: Self.maxReadAttempts))
                try await Task.sleep(nanoseconds: Self.nanos(delay))
            }
        }
    }

    /// One HTTP round-trip: rate-limit accounting plus the 403/429 rate-limit
    /// classification. Every read and write funnels through here.
    private func performFetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubClientError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubClientError.invalidResponse("non-HTTP response")
        }
        rateLimit?.update(from: http)
        if http.statusCode == 403 || http.statusCode == 429 {
            let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
            if remaining == "0" || http.statusCode == 429 {
                let retry = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                let resetAt = http.value(forHTTPHeaderField: "x-ratelimit-reset")
                    .flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
                throw GitHubClientError.rateLimited(retryAfter: retry, resetAt: resetAt)
            }
        }
        return (data, http)
    }

    private func fetchJSON(_ request: URLRequest, allow404: Bool = false) async throws -> Any? {
        let (data, http) = try await fetch(request)
        if http.statusCode == 404 {
            if allow404 { return nil }
            throw GitHubClientError.notFound(request.url?.path ?? "")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw GitHubClientError.http(http.statusCode, body)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Follows RFC 5988 Link headers until exhausted.
    private func fetchPaginatedArray(path: String, query: [URLQueryItem],
                                     itemsKey: String? = nil, maxPages: Int = 50) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var nextRequest: URLRequest? = try request(path: path, query: query + [URLQueryItem(name: "per_page", value: "100")])
        var pages = 0
        while let req = nextRequest, pages < maxPages {
            pages += 1
            let (data, http) = try await fetch(req)
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                throw GitHubClientError.http(http.statusCode, body)
            }
            let decoded = try JSONSerialization.jsonObject(with: data)
            if let key = itemsKey, let dict = decoded as? [String: Any],
               let page = dict[key] as? [[String: Any]] {
                items.append(contentsOf: page)
            } else if let page = decoded as? [[String: Any]] {
                items.append(contentsOf: page)
            }
            nextRequest = nil
            if let link = http.value(forHTTPHeaderField: "Link"),
               let next = Self.nextLink(from: link) {
                var req = URLRequest(url: next)
                req.allHTTPHeaderFields = req.allHTTPHeaderFields
                if let token = tokenProvider() {
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                }
                nextRequest = req
            }
        }
        return items
    }

    static func nextLink(from header: String) -> URL? {
        for part in header.split(separator: ",") {
            let segments = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.count >= 2, segments.contains("rel=\"next\"") else { continue }
            let urlPart = segments[0]
            guard urlPart.hasPrefix("<"), urlPart.hasSuffix(">") else { continue }
            return URL(string: String(urlPart.dropFirst().dropLast()))
        }
        return nil
    }

    private static func repoRef(from json: [String: Any]) -> RepoRef? {
        guard let fullName = json["full_name"] as? String else { return nil }
        return RepoRef(fullName: fullName,
                       name: json["name"] as? String,
                       defaultBranch: json["default_branch"] as? String ?? "main",
                       archived: json["archived"] as? Bool ?? false,
                       isPrivate: json["private"] as? Bool ?? true)
    }

    // MARK: GitHubClient

    public func listOrgRepos(org: String) async throws -> [RepoRef] {
        let items = try await fetchPaginatedArray(path: "orgs/\(org)/repos", query: [])
        return items.compactMap(Self.repoRef(from:))
    }

    public func getRepo(fullName: String) async throws -> RepoRef {
        let json = try await fetchJSON(try request(path: "repos/\(fullName)"))
        guard let dict = json as? [String: Any], let repo = Self.repoRef(from: dict) else {
            throw GitHubClientError.invalidResponse("repos API returned unexpected shape for \(fullName)")
        }
        return repo
    }

    public func searchCode(org: String, query: String) async throws -> [RepoRef] {
        let q = query.contains("org:") ? query : "org:\(org) \(query)"
        let items = try await fetchPaginatedArray(path: "search/code",
                                                  query: [URLQueryItem(name: "q", value: q)],
                                                  itemsKey: "items", maxPages: 10)
        var seen = Set<String>()
        var repos: [RepoRef] = []
        for item in items {
            guard let repoJSON = item["repository"] as? [String: Any],
                  let ref = Self.repoRef(from: repoJSON),
                  seen.insert(ref.fullName).inserted else { continue }
            repos.append(ref)
        }
        return repos
    }

    public func getContent(repo: String, path: String, ref: String?) async throws -> String? {
        var query: [URLQueryItem] = []
        if let ref { query.append(URLQueryItem(name: "ref", value: ref)) }
        let json = try await fetchJSON(try request(path: "repos/\(repo)/contents/\(path)", query: query),
                                       allow404: true)
        guard let json else { return nil }
        guard let dict = json as? [String: Any],
              let encoded = dict["content"] as? String else {
            throw GitHubClientError.invalidResponse("contents API returned unexpected shape for \(path)")
        }
        let cleaned = encoded.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned),
              let text = String(data: data, encoding: .utf8) else {
            throw GitHubClientError.invalidResponse("could not decode \(path) as UTF-8")
        }
        return text
    }

    public func listFiles(repo: String, ref: String?) async throws -> [String] {
        // Git Trees API with recursive=1: one call for the whole tree. GitHub
        // truncates beyond ~100k entries / 7MB; acceptable for organisation
        // repos, revisit with per-directory walking if it ever bites.
        let treeRef = ref ?? "HEAD"
        let json = try await fetchJSON(try request(path: "repos/\(repo)/git/trees/\(treeRef)",
                                                   query: [URLQueryItem(name: "recursive", value: "1")]))
        guard let dict = json as? [String: Any],
              let tree = dict["tree"] as? [[String: Any]] else {
            throw GitHubClientError.invalidResponse("tree API returned unexpected shape")
        }
        return tree.compactMap { node in
            (node["type"] as? String) == "blob" ? node["path"] as? String : nil
        }
    }

    public func getRef(repo: String, ref: String) async throws -> String? {
        let json = try await fetchJSON(try request(path: "repos/\(repo)/git/ref/\(ref)"), allow404: true)
        guard let json else { return nil }
        guard let dict = json as? [String: Any],
              let object = dict["object"] as? [String: Any],
              let sha = object["sha"] as? String else {
            throw GitHubClientError.invalidResponse("ref API returned unexpected shape")
        }
        return sha
    }

    public func listPRs(repo: String, head: String?, state: String) async throws -> [PullRequestRef] {
        var query = [URLQueryItem(name: "state", value: state)]
        if let head {
            // GitHub's pulls API expects head as "owner:branch". A bare branch
            // is silently ignored and the API returns ALL open PRs — which made
            // createPR's "does a PR already exist for this head?" preflight
            // match unrelated PRs and halt with a false "PR exists".
            query.append(URLQueryItem(name: "head", value: Self.headQueryValue(repo: repo, head: head)))
        }
        let items = try await fetchPaginatedArray(path: "repos/\(repo)/pulls", query: query, maxPages: 10)
        let prs = items.compactMap { Self.pullRequest(from: $0, repo: repo) }
        // Defend against the server filter regardless: only return PRs whose
        // head ref actually matches. This is the contract the fixture client
        // honors and the host's createPR preflight depends on.
        guard let head else { return prs }
        return prs.filter { $0.headRef == head }
    }

    /// The `head` filter value for GitHub's pulls API: "owner:branch", derived
    /// from the "owner/name" repo. A bare branch is silently ignored by GitHub.
    static func headQueryValue(repo: String, head: String) -> String {
        guard let slash = repo.firstIndex(of: "/") else { return head }
        return "\(repo[..<slash]):\(head)"
    }

    public func searchPRs(org: String, query: String) async throws -> [PullRequestRef] {
        let q = query.contains("org:") ? query : "org:\(org) is:pr \(query)"
        let items = try await fetchPaginatedArray(path: "search/issues",
                                                  query: [URLQueryItem(name: "q", value: q)],
                                                  itemsKey: "items", maxPages: 10)
        return items.compactMap { item in
            guard let number = item["number"] as? Int,
                  let htmlURL = item["html_url"] as? String else { return nil }
            // Search results don't carry head details; repo is derived from the URL.
            let repo = htmlURL.replacingOccurrences(of: "https://github.com/", with: "")
                .split(separator: "/").prefix(2).joined(separator: "/")
            let state = (item["state"] as? String) ?? "open"
            return PullRequestRef(repo: repo, number: number, headRef: "", headSha: "",
                                  state: state, url: htmlURL)
        }
    }

    // MARK: Custom properties

    /// Decodes a GitHub custom-property `value` (string, array of strings, or
    /// null/absent) into a PropertyValue.
    static func propertyValue(from raw: Any?) -> PropertyValue {
        switch raw {
        case let s as String: return .string(s)
        case let a as [Any]: return .list(a.map { String(describing: $0) })
        case is NSNull, .none: return .null
        default: return .string(String(describing: raw!))
        }
    }

    /// Encodes a PropertyValue for a PATCH body (string, array, or NSNull).
    static func propertyJSON(_ value: PropertyValue) -> Any {
        switch value {
        case .string(let s): return s
        case .list(let a): return a
        case .null: return NSNull()
        }
    }

    private static func properties(from items: [[String: Any]]) -> [String: PropertyValue] {
        var out: [String: PropertyValue] = [:]
        for item in items {
            guard let name = item["property_name"] as? String else { continue }
            out[name] = propertyValue(from: item["value"])
        }
        return out
    }

    /// Custom-property permissions are fine-grained-token only (no classic-PAT
    /// scope), split by operation, and require the org as the token's resource
    /// owner. Turn the opaque 403 into one legible, actionable message naming
    /// the exact permission to grant.
    private static func clarifyPropertyPermission(_ error: Error, writing: Bool) -> Error {
        guard case GitHubClientError.http(403, _) = error else { return error }
        let needed = writing
            ? "\"Repository → Custom properties: write\""
            : "\"Organization → Custom properties: read\""
        return GitHubClientError.http(403,
            "the token lacks the required custom-properties permission (\(needed)). "
            + "Use a fine-grained token whose resource owner is the organisation — classic PATs "
            + "and personal-account tokens do not expose this permission.")
    }

    public func listOrgProperties(org: String) async throws -> [RepoProperties] {
        do {
            let items = try await fetchPaginatedArray(path: "orgs/\(org)/properties/values", query: [])
            return items.compactMap { item in
                guard let fullName = item["repository_full_name"] as? String else { return nil }
                let repo = RepoRef(fullName: fullName, name: item["repository_name"] as? String)
                let props = Self.properties(from: item["properties"] as? [[String: Any]] ?? [])
                return RepoProperties(repo: repo, properties: props)
            }
        } catch {
            throw Self.clarifyPropertyPermission(error, writing: false)
        }
    }

    public func getProperties(repo: String) async throws -> [String: PropertyValue] {
        do {
            let json = try await fetchJSON(try request(path: "repos/\(repo)/properties/values"))
            guard let items = json as? [[String: Any]] else {
                throw GitHubClientError.invalidResponse("properties API returned unexpected shape for \(repo)")
            }
            return Self.properties(from: items)
        } catch {
            throw Self.clarifyPropertyPermission(error, writing: false)
        }
    }

    public func listPropertyDefs(org: String) async throws -> [PropertyDef] {
        do {
            let json = try await fetchJSON(try request(path: "orgs/\(org)/properties/schema"))
            guard let items = json as? [[String: Any]] else {
                throw GitHubClientError.invalidResponse("properties schema API returned unexpected shape")
            }
            return items.compactMap { item in
                guard let name = item["property_name"] as? String else { return nil }
                return PropertyDef(name: name,
                                   valueType: item["value_type"] as? String ?? "string",
                                   allowedValues: item["allowed_values"] as? [String])
            }
        } catch {
            throw Self.clarifyPropertyPermission(error, writing: false)
        }
    }

    public func setProperties(repo: String, values: [String: PropertyValue]) async throws {
        guard Self.liveWritesEnabled else { throw GitHubClientError.writesDisabled }
        let body: [String: Any] = ["properties": values.map { name, value in
            ["property_name": name, "value": Self.propertyJSON(value)]
        }]
        do {
            try await withVoidWriteRetry(
                label: "set properties on \(repo)",
                landed: {
                    // Already at target? Then the PATCH landed (it is idempotent
                    // anyway; this just avoids a redundant write on retry).
                    let current = try await self.getProperties(repo: repo)
                    return values.allSatisfy { (current[$0.key] ?? .null) == $0.value }
                },
                perform: {
                    // The values endpoint returns 204 No Content — bypass the
                    // JSON decode (an empty body would fail JSONSerialization).
                    let (data, http) = try await self.fetch(try self.mutatingRequest(
                        method: "PATCH", path: "repos/\(repo)/properties/values", body: body))
                    guard (200..<300).contains(http.statusCode) else {
                        let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
                        throw GitHubClientError.http(http.statusCode, detail)
                    }
                })
        } catch {
            throw Self.clarifyPropertyPermission(error, writing: true)
        }
    }

    // MARK: Writes (hard-disabled via liveWritesEnabled)

    /// Mutating request with a JSON body. Every caller checks the kill
    /// switch before building one.
    private func mutatingRequest(method: String, path: String,
                                 body: [String: Any]) throws -> URLRequest {
        var request = try request(path: path)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func createBranch(repo: String, name: String, fromSha: String) async throws -> String {
        guard Self.liveWritesEnabled else { throw GitHubClientError.writesDisabled }
        return try await withWriteRetry(
            verify: {
                // Did the ref get created at the expected sha despite the error?
                let existing = try await self.getRef(repo: repo, ref: "heads/\(name)")
                return existing == fromSha ? fromSha : nil
            },
            perform: {
                let json = try await self.fetchJSON(try self.mutatingRequest(
                    method: "POST", path: "repos/\(repo)/git/refs",
                    body: ["ref": "refs/heads/\(name)", "sha": fromSha]))
                guard let dict = json as? [String: Any],
                      let object = dict["object"] as? [String: Any],
                      let sha = object["sha"] as? String else {
                    throw GitHubClientError.invalidResponse("create-ref API returned unexpected shape")
                }
                return sha
            })
    }

    public func putContent(repo: String, path: String, content: String,
                           branch: String, message: String) async throws -> String {
        guard Self.liveWritesEnabled else { throw GitHubClientError.writesDisabled }
        return try await withWriteRetry(
            verify: {
                // If the branch already holds exactly this content, the PUT
                // landed — re-PUTting would make a duplicate commit. The commit
                // sha is only used for audit detail, so a marker suffices.
                let current = try await self.getContent(repo: repo, path: path, ref: branch)
                return current == content ? "(already-applied)" : nil
            },
            perform: {
                // The contents API needs the existing blob sha when updating.
                var body: [String: Any] = [
                    "message": message,
                    "content": Data(content.utf8).base64EncodedString(),
                    "branch": branch,
                ]
                let existing = try await self.fetchJSON(
                    try self.request(path: "repos/\(repo)/contents/\(path)",
                                     query: [URLQueryItem(name: "ref", value: branch)]),
                    allow404: true)
                if let dict = existing as? [String: Any], let sha = dict["sha"] as? String {
                    body["sha"] = sha
                }
                let json = try await self.fetchJSON(try self.mutatingRequest(
                    method: "PUT", path: "repos/\(repo)/contents/\(path)", body: body))
                guard let dict = json as? [String: Any],
                      let commit = dict["commit"] as? [String: Any],
                      let sha = commit["sha"] as? String else {
                    throw GitHubClientError.invalidResponse("contents API returned unexpected shape for \(path)")
                }
                return sha
            })
    }

    public func deleteContent(repo: String, path: String,
                              branch: String, message: String) async throws -> String {
        guard Self.liveWritesEnabled else { throw GitHubClientError.writesDisabled }
        return try await withWriteRetry(
            verify: {
                // If the file is already gone from the branch the DELETE landed
                // (or a prior armed run already removed it). The commit sha is
                // only used for audit detail, so a marker suffices.
                let current = try await self.getContent(repo: repo, path: path, ref: branch)
                return current == nil ? "(already-deleted)" : nil
            },
            perform: {
                // The contents API needs the existing blob sha to delete. If the
                // file isn't there, treat the delete as already satisfied — the
                // verify marker above also covers the in-flight retry case.
                let existing = try await self.fetchJSON(
                    try self.request(path: "repos/\(repo)/contents/\(path)",
                                     query: [URLQueryItem(name: "ref", value: branch)]),
                    allow404: true)
                guard let dict = existing as? [String: Any], let sha = dict["sha"] as? String else {
                    return "(already-deleted)"
                }
                let body: [String: Any] = [
                    "message": message,
                    "sha": sha,
                    "branch": branch,
                ]
                let json = try await self.fetchJSON(try self.mutatingRequest(
                    method: "DELETE", path: "repos/\(repo)/contents/\(path)", body: body))
                guard let dict = json as? [String: Any],
                      let commit = dict["commit"] as? [String: Any],
                      let commitSha = commit["sha"] as? String else {
                    throw GitHubClientError.invalidResponse("contents API returned unexpected shape deleting \(path)")
                }
                return commitSha
            })
    }

    public func createPR(repo: String, head: String, base: String,
                         title: String, body: String) async throws -> PullRequestRef {
        guard Self.liveWritesEnabled else { throw GitHubClientError.writesDisabled }
        return try await withWriteRetry(
            verify: {
                // Did an open PR for this head already get created?
                try await self.listPRs(repo: repo, head: head, state: "open").first
            },
            perform: {
                let json = try await self.fetchJSON(try self.mutatingRequest(
                    method: "POST", path: "repos/\(repo)/pulls",
                    body: ["title": title, "head": head, "base": base, "body": body]))
                guard let dict = json as? [String: Any],
                      let pr = Self.pullRequest(from: dict, repo: repo) else {
                    throw GitHubClientError.invalidResponse("pulls API returned unexpected shape")
                }
                return pr
            })
    }

    public func getPR(repo: String, number: Int) async throws -> PullRequestRef {
        let json = try await fetchJSON(try request(path: "repos/\(repo)/pulls/\(number)"))
        guard let dict = json as? [String: Any],
              let pr = Self.pullRequest(from: dict, repo: repo) else {
            throw GitHubClientError.invalidResponse("pulls API returned unexpected shape for #\(number)")
        }
        return pr
    }

    public func mergePR(repo: String, number: Int, expectedHeadSha: String) async throws -> String {
        guard Self.liveWritesEnabled else { throw GitHubClientError.writesDisabled }
        // `sha` is GitHub's own precondition: the merge is rejected with 409
        // if the head moved since the value was captured.
        //
        // A 5xx (or network blip) on this endpoint is transient AND ambiguous —
        // GitHub sometimes 502s while the squash actually proceeds async. So on
        // a transient error: re-check the PR; if it merged, we're done (never
        // re-PUT — that would risk acting twice); otherwise back off and retry,
        // bounded. Non-transient errors (e.g. 409 head moved) surface at once.
        let maxAttempts = 3
        let id = UUID()
        defer { retry?.clear(id: id) }
        var attempt = 0
        while true {
            attempt += 1
            do {
                let json = try await fetchJSON(try mutatingRequest(
                    method: "PUT", path: "repos/\(repo)/pulls/\(number)/merge",
                    body: ["merge_method": "squash", "sha": expectedHeadSha]))
                guard let dict = json as? [String: Any], let sha = dict["sha"] as? String else {
                    throw GitHubClientError.invalidResponse("merge API returned unexpected shape")
                }
                return sha
            } catch let error as GitHubClientError {
                // On ANY failure, re-check first: the merge may have proceeded
                // async (5xx with the squash still running), or a retry PUT may
                // 405 because it already merged. If it's merged, report the real
                // merge commit and never re-PUT. Only a still-not-merged
                // transient error with attempts left retries; everything else
                // (e.g. 409 head moved) surfaces.
                if let mergedSha = try? await mergedCommitSha(repo: repo, number: number) {
                    return mergedSha
                }
                guard Self.isTransientMergeError(error), attempt < maxAttempts else { throw error }
                retry?.begin(id: id, .init(label: "merge PR #\(number)", attempt: attempt + 1, maxAttempts: maxAttempts))
                try await Task.sleep(nanoseconds: Self.nanos(backoffDelay(attempt: attempt)))
            }
        }
    }

    /// The squash-merge commit SHA if the PR is now merged, else nil — used to
    /// confirm (and correctly report) a merge whose PUT response was lost to a
    /// transient error, without ever re-PUTting a merged PR.
    private func mergedCommitSha(repo: String, number: Int) async throws -> String? {
        let pr = try await getPR(repo: repo, number: number)
        guard pr.state == "merged" else { return nil }
        return pr.mergeCommitSha ?? pr.headSha
    }

    /// A merge error worth re-checking + retrying: a server-side 5xx or a
    /// network blip (both can mask a merge that proceeded async). A 4xx like
    /// 409 (head moved) or 405 (not mergeable) is a definitive failure.
    static func isTransientMergeError(_ error: GitHubClientError) -> Bool {
        switch error {
        case .http(let code, _): return (500...599).contains(code)
        case .network: return true
        default: return false
        }
    }

    public func closePR(repo: String, number: Int) async throws {
        guard Self.liveWritesEnabled else { throw GitHubClientError.writesDisabled }
        try await withVoidWriteRetry(
            landed: {
                // Already closed/merged? Then the PATCH landed.
                try await self.getPR(repo: repo, number: number).state != "open"
            },
            perform: {
                _ = try await self.fetchJSON(try self.mutatingRequest(
                    method: "PATCH", path: "repos/\(repo)/pulls/\(number)",
                    body: ["state": "closed"]))
            })
    }

    public func editPR(repo: String, number: Int, body: String) async throws {
        guard Self.liveWritesEnabled else { throw GitHubClientError.writesDisabled }
        try await withVoidWriteRetry(
            landed: {
                // Body already matches? Then the PATCH landed (re-PATCH is also
                // idempotent, so this just avoids a redundant write).
                try await self.getPR(repo: repo, number: number).body == body
            },
            perform: {
                _ = try await self.fetchJSON(try self.mutatingRequest(
                    method: "PATCH", path: "repos/\(repo)/pulls/\(number)",
                    body: ["body": body]))
            })
    }

    public func deleteBranch(repo: String, name: String) async throws {
        guard Self.liveWritesEnabled else { throw GitHubClientError.writesDisabled }
        try await withVoidWriteRetry(
            landed: {
                // Gone already? Then the DELETE landed.
                try await self.getRef(repo: repo, ref: "heads/\(name)") == nil
            },
            perform: {
                // DELETE returns 204 with an empty body — bypass the JSON decode.
                var request = try self.request(path: "repos/\(repo)/git/refs/heads/\(name)")
                request.httpMethod = "DELETE"
                let (_, http) = try await self.fetch(request)
                // fetch() doesn't throw on a 5xx for a non-GET (only on
                // network/rate-limit), so surface a transient gateway error here
                // — otherwise the write-retry could never see it.
                if Self.isRetryableStatus(http.statusCode) {
                    throw GitHubClientError.http(http.statusCode, "delete-ref transient failure")
                }
            })
    }

    private static func pullRequest(from json: [String: Any], repo: String) -> PullRequestRef? {
        guard let number = json["number"] as? Int else { return nil }
        let head = json["head"] as? [String: Any]
        let merged = json["merged_at"] != nil && !(json["merged_at"] is NSNull)
        let rawState = (json["state"] as? String) ?? "open"
        return PullRequestRef(repo: repo,
                              number: number,
                              headRef: head?["ref"] as? String ?? "",
                              headSha: head?["sha"] as? String ?? "",
                              state: merged ? "merged" : rawState,
                              url: json["html_url"] as? String ?? "",
                              mergeCommitSha: json["merge_commit_sha"] as? String,
                              body: json["body"] as? String)
    }
}
