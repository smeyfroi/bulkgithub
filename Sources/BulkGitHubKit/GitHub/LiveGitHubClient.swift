import Foundation

/// URLSession-backed GitHub REST client.
///
/// Written for phase 1 completeness but not yet exercised: the app defaults to
/// fixture mode, and no automated test performs live calls (plan v2: no live
/// GitHub integration until the user confirms). The token is supplied by a
/// provider closure so it stays in Keychain and never enters script space.
public final class LiveGitHubClient: GitHubClient, @unchecked Sendable {
    public typealias TokenProvider = @Sendable () -> String?

    private let apiHost: URL
    private let tokenProvider: TokenProvider
    private let session: URLSession
    private let rateLimit: RateLimitMonitor?

    public init(apiHost: String, tokenProvider: @escaping TokenProvider,
                session: URLSession = .shared, rateLimit: RateLimitMonitor? = nil) {
        self.apiHost = URL(string: apiHost) ?? URL(string: "https://api.github.com")!
        self.tokenProvider = tokenProvider
        self.session = session
        self.rateLimit = rateLimit
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

    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
                throw GitHubClientError.rateLimited(retryAfter: retry)
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
        if let head { query.append(URLQueryItem(name: "head", value: head)) }
        let items = try await fetchPaginatedArray(path: "repos/\(repo)/pulls", query: query, maxPages: 10)
        return items.compactMap { Self.pullRequest(from: $0, repo: repo) }
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
                              url: json["html_url"] as? String ?? "")
    }
}
