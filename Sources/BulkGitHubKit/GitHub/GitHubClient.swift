import Foundation

public enum GitHubClientError: Error, LocalizedError, Equatable {
    case notFound(String)
    case http(Int, String)
    case rateLimited(retryAfter: Double?)
    case network(String)
    case missingCredentials
    case invalidResponse(String)
    /// Live GitHub writes are compiled out for now: the armed workflow is
    /// exercised against fixture data until it has been shaken down.
    case writesDisabled

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): return "Not found: \(what)"
        case .http(let code, let message): return "HTTP \(code): \(message)"
        case .rateLimited(let after):
            return "Rate limited" + (after.map { ", retry after \(Int($0))s" } ?? "")
        case .network(let message): return "Network error: \(message)"
        case .missingCredentials: return "No GitHub token configured"
        case .invalidResponse(let message): return "Invalid response: \(message)"
        case .writesDisabled:
            return "Live GitHub writes are disabled in this build — armed runs work against fixture data only"
        }
    }
}

/// The read surface used by check-phase scripts. Write operations arrive with
/// the update/merge phases (plan v2, phases 3-5) and will extend this protocol.
public protocol GitHubClient: Sendable {
    func listOrgRepos(org: String) async throws -> [RepoRef]
    /// One repository's metadata — the authoritative source for defaultBranch.
    /// (Code-search results don't carry default_branch, so repos surfaced via
    /// searchCode may claim "main" on a master-default repo.)
    func getRepo(fullName: String) async throws -> RepoRef
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

    // MARK: Writes (phase 4) — reached only through the engine's armed
    // bindings, which enforce repo selection, plan conformance, the drift
    // guard, and the bulkgh/ branch prefix before any of these is called.

    /// Create a branch; returns the new ref's SHA.
    func createBranch(repo: String, name: String, fromSha: String) async throws -> String
    /// Create or update a file on a branch; returns the commit SHA.
    func putContent(repo: String, path: String, content: String,
                    branch: String, message: String) async throws -> String
    /// Open a pull request from head into base.
    func createPR(repo: String, head: String, base: String,
                  title: String, body: String) async throws -> PullRequestRef
}
