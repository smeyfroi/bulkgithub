import Foundation

public enum GitHubClientError: Error, LocalizedError, Equatable {
    case notFound(String)
    case http(Int, String)
    case rateLimited(retryAfter: Double?)
    case network(String)
    case missingCredentials
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): return "Not found: \(what)"
        case .http(let code, let message): return "HTTP \(code): \(message)"
        case .rateLimited(let after):
            return "Rate limited" + (after.map { ", retry after \(Int($0))s" } ?? "")
        case .network(let message): return "Network error: \(message)"
        case .missingCredentials: return "No GitHub token configured"
        case .invalidResponse(let message): return "Invalid response: \(message)"
        }
    }
}

/// The read surface used by check-phase scripts. Write operations arrive with
/// the update/merge phases (plan v2, phases 3-5) and will extend this protocol.
public protocol GitHubClient: Sendable {
    func listOrgRepos(org: String) async throws -> [RepoRef]
    /// Code search scoped to the organisation. Results are candidate evidence only.
    func searchCode(org: String, query: String) async throws -> [RepoRef]
    /// Returns nil when the file does not exist at that path/ref.
    func getContent(repo: String, path: String, ref: String?) async throws -> String?
    /// All blob paths in the repository tree at ref (default branch HEAD when
    /// nil). Glob filtering happens host-side — GitHub has no glob endpoint.
    func listFiles(repo: String, ref: String?) async throws -> [String]
    /// Returns the SHA for a ref (e.g. "heads/main"), or nil if the ref does not exist.
    func getRef(repo: String, ref: String) async throws -> String?
    func listPRs(repo: String, head: String?, state: String) async throws -> [PullRequestRef]
    func searchPRs(org: String, query: String) async throws -> [PullRequestRef]
}
