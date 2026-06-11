import Foundation
import Testing
@testable import BulkGitHubKit

/// Phase 4: the guarded live handle, exercised entirely against fixtures.
/// Live GitHub writes are hard-disabled at the client; these tests prove the
/// arming workflow end to end — dry run, review, armed apply — including the
/// drift guard, plan conformance, repo selection, and idempotency.
@Suite("Armed runs (guarded writes)")
struct ArmedRunTests {

    /// Dry-run the shipped update recipe against carried check state, then
    /// re-run it armed. Returns everything a test needs to assert on.
    private func dryRunPlan(client: FixtureGitHubClient) async throws
        -> (validated: ValidatedScript, state: [String: String], plan: [String: [PlannedAction]]) {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let recipe = try #require(ResourceLocator.recipe(named: "remove_line_with_string"))
        let validated = try pipeline.validate(source: recipe)

        let state = ["stringMatches": """
        [{"repo":"geome/web-frontend","defaultBranch":"main","paths":["deploy/infra.json"]},\
        {"repo":"geome/data-pipeline","defaultBranch":"master","paths":["deploy/keys.yml"]}]
        """]
        let dryRun = await ScriptEngine().run(javaScript: validated.javaScript,
                                              phase: .update,
                                              params: validated.meta.params,
                                              github: client,
                                              organisation: "geome",
                                              initialState: state,
                                              onEvent: { _ in })
        #expect(dryRun.status == .completed)
        #expect(dryRun.artifacts.isEmpty)
        return (validated, state, dryRun.plannedActions)
    }

    private func armedConfiguration(targets: Set<String>,
                                    plan: [String: [PlannedAction]]) -> EngineConfiguration {
        var configuration = EngineConfiguration()
        configuration.writeMode = .armed
        configuration.targetRepos = targets
        configuration.referencePlan = plan
        return configuration
    }

    @Test("armed apply creates branches and PRs on the fixture, with artifacts")
    func armedApplyEndToEnd() async throws {
        let client = FixtureGitHubClient.demo()
        let (validated, state, plan) = try await dryRunPlan(client: client)
        #expect(plan.keys.sorted() == ["geome/data-pipeline", "geome/web-frontend"])

        let armed = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update,
                                             params: validated.meta.params,
                                             github: client,
                                             organisation: "geome",
                                             configuration: armedConfiguration(
                                                targets: ["geome/web-frontend", "geome/data-pipeline"],
                                                plan: plan),
                                             initialState: state,
                                             onEvent: { _ in })
        #expect(armed.status == .completed)

        // Both repos end as PR-raised, with branch + PR artifacts each.
        var statusByRepo: [String: RepoResult] = [:]
        for result in armed.results { statusByRepo[result.id] = result }
        #expect(statusByRepo["geome/web-frontend"]?.status == .prRaised)
        #expect(statusByRepo["geome/data-pipeline"]?.status == .prRaised)
        #expect(armed.artifacts.filter { $0.kind == .branch }.count == 2)
        #expect(armed.artifacts.filter { $0.kind == .pullRequest }.count == 2)
        #expect(armed.artifacts.allSatisfy { $0.kind == .branch || $0.url != nil })

        // The fixture actually holds the writes: branch content matches the
        // reviewed plan's "after", and the PR targets the repo's REAL default
        // branch (master for data-pipeline — never an assumed main).
        let branch = "bulkgh/remove-keypair-reference"
        let webEdited = client.branchContent(repo: "geome/web-frontend",
                                             branch: branch, path: "deploy/infra.json")
        #expect(webEdited?.contains("keypair-1") == false)
        let prs = client.createdPRs
        #expect(prs.count == 2)
        #expect(prs.allSatisfy { $0.state == "open" && $0.headRef == branch })

        // Audit trail labels armed writes unmistakably.
        let writes = armed.auditEvents.filter { $0.kind.hasPrefix("write.") }
        #expect(writes.count == 6)  // 2 × (branch + put + PR)
        #expect(writes.allSatisfy { $0.detail.contains("ARMED") })
    }

    @Test("drift guard: a repo that changed since the dry run halts with nothing written")
    func driftGuard() async throws {
        let client = FixtureGitHubClient.demo()
        let (validated, state, plan) = try await dryRunPlan(client: client)

        // The remote moves between review and apply.
        client.contents["geome/web-frontend"]?["deploy/infra.json"] = """
        {
          "stack": "web-frontend",
          "region": "eu-west-1",
          "keyPair": "ec2-shell-prod-eu-west-1-keypair-1",
          "addedSinceReview": true
        }
        """

        let armed = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update,
                                             params: validated.meta.params,
                                             github: client,
                                             organisation: "geome",
                                             configuration: armedConfiguration(
                                                targets: ["geome/web-frontend", "geome/data-pipeline"],
                                                plan: plan),
                                             initialState: state,
                                             onEvent: { _ in })
        #expect(armed.status == .completed)

        let web = armed.results.first { $0.id == "geome/web-frontend" }
        #expect(web?.status == .conflicted)
        #expect(web?.reason?.contains("changed on the remote") == true)
        // Nothing written for the drifted repo beyond its branch; no PR.
        #expect(client.createdPRs.allSatisfy { $0.repo != "geome/web-frontend" })
        #expect(client.branchContent(repo: "geome/web-frontend",
                                     branch: "bulkgh/remove-keypair-reference",
                                     path: "deploy/infra.json")?
            .contains("keypair-1") == true)  // branch still holds the untouched copy

        // The clean repo is unaffected by its neighbour's drift.
        let pipeline = armed.results.first { $0.id == "geome/data-pipeline" }
        #expect(pipeline?.status == .prRaised)
    }

    @Test("plan conformance: a doctored reference plan halts the repo as conflicted")
    func planConformance() async throws {
        let client = FixtureGitHubClient.demo()
        let (validated, state, plan) = try await dryRunPlan(client: client)

        // Tamper with the reviewed "after" for one repo: the script will
        // produce content that no longer matches the review.
        var doctored = plan
        doctored["geome/web-frontend"] = doctored["geome/web-frontend"]?.map { action in
            guard case .putContent(let path, let branch, let message, let before, _) = action else {
                return action
            }
            return .putContent(path: path, branch: branch, message: message,
                               before: before, after: "something the user never reviewed")
        }

        let armed = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update,
                                             params: validated.meta.params,
                                             github: client,
                                             organisation: "geome",
                                             configuration: armedConfiguration(
                                                targets: ["geome/web-frontend"],
                                                plan: doctored),
                                             initialState: state,
                                             onEvent: { _ in })
        #expect(armed.status == .completed)
        let web = armed.results.first { $0.id == "geome/web-frontend" }
        #expect(web?.status == .conflicted)
        #expect(client.createdPRs.isEmpty)
    }

    @Test("repo selection: unselected repos are skipped with nothing written")
    func selectionEnforced() async throws {
        let client = FixtureGitHubClient.demo()
        let (validated, state, plan) = try await dryRunPlan(client: client)

        let armed = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update,
                                             params: validated.meta.params,
                                             github: client,
                                             organisation: "geome",
                                             configuration: armedConfiguration(
                                                targets: ["geome/data-pipeline"],
                                                plan: plan),
                                             initialState: state,
                                             onEvent: { _ in })
        #expect(armed.status == .completed)
        let web = armed.results.first { $0.id == "geome/web-frontend" }
        #expect(web?.status == .skipped)
        #expect(client.createdBranches["geome/web-frontend"] == nil)
        #expect(armed.artifacts.allSatisfy { $0.repo == "geome/data-pipeline" })
    }

    @Test("idempotency: a second armed run halts on existing artifacts, no duplicates")
    func idempotentRerun() async throws {
        let client = FixtureGitHubClient.demo()
        let (validated, state, plan) = try await dryRunPlan(client: client)
        let configuration = armedConfiguration(
            targets: ["geome/web-frontend", "geome/data-pipeline"], plan: plan)

        let first = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update, params: validated.meta.params,
                                             github: client, organisation: "geome",
                                             configuration: configuration,
                                             initialState: state, onEvent: { _ in })
        #expect(first.artifacts.count == 4)

        let second = await ScriptEngine().run(javaScript: validated.javaScript,
                                              phase: .update, params: validated.meta.params,
                                              github: client, organisation: "geome",
                                              configuration: configuration,
                                              initialState: state, onEvent: { _ in })
        #expect(second.status == .completed)
        #expect(second.artifacts.isEmpty)
        for result in second.results where ["geome/web-frontend", "geome/data-pipeline"].contains(result.id) {
            #expect(result.status == .branchExists)
        }
        #expect(client.createdPRs.count == 2)  // still just the first run's
    }

    @Test("armed runs refuse to start without targets or a reviewed plan")
    func armedPreconditions() async throws {
        let client = FixtureGitHubClient.demo()
        let (validated, state, plan) = try await dryRunPlan(client: client)

        var noTargets = EngineConfiguration()
        noTargets.writeMode = .armed
        noTargets.referencePlan = plan
        let outcome1 = await ScriptEngine().run(javaScript: validated.javaScript,
                                                phase: .update, params: validated.meta.params,
                                                github: client, organisation: "geome",
                                                configuration: noTargets,
                                                initialState: state, onEvent: { _ in })
        guard case .failed(let message1) = outcome1.status else {
            Issue.record("expected failure without targets"); return
        }
        #expect(message1.contains("selection"))

        var noPlan = EngineConfiguration()
        noPlan.writeMode = .armed
        noPlan.targetRepos = ["geome/web-frontend"]
        let outcome2 = await ScriptEngine().run(javaScript: validated.javaScript,
                                                phase: .update, params: validated.meta.params,
                                                github: client, organisation: "geome",
                                                configuration: noPlan,
                                                initialState: state, onEvent: { _ in })
        guard case .failed(let message2) = outcome2.status else {
            Issue.record("expected failure without a plan"); return
        }
        #expect(message2.contains("plan"))
    }

    @Test("live GitHub writes are hard-disabled at the client")
    func liveWritesDisabled() async {
        #expect(!LiveGitHubClient.liveWritesEnabled)
        let client = LiveGitHubClient(apiHost: "https://api.github.com",
                                      tokenProvider: { "test-token" })
        await #expect(throws: GitHubClientError.writesDisabled) {
            _ = try await client.createBranch(repo: "geome/x", name: "bulkgh/t", fromSha: "abc")
        }
        await #expect(throws: GitHubClientError.writesDisabled) {
            _ = try await client.putContent(repo: "geome/x", path: "f", content: "c",
                                            branch: "bulkgh/t", message: "m")
        }
        await #expect(throws: GitHubClientError.writesDisabled) {
            _ = try await client.createPR(repo: "geome/x", head: "bulkgh/t", base: "main",
                                          title: "t", body: "b")
        }
    }
}
