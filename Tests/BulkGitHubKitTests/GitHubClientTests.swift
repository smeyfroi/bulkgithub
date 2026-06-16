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
}
