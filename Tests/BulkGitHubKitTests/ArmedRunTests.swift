import Foundation
import Testing
@testable import BulkGitHubKit

/// The guarded live handle, exercised entirely against fixtures. These tests
/// prove the arming workflow end to end — dry run, review, armed apply —
/// including the drift guard, plan conformance, repo selection, and
/// idempotency.
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
        [{"repo":"example-org/web-frontend","defaultBranch":"main","paths":["deploy/infra.json"]},\
        {"repo":"example-org/data-pipeline","defaultBranch":"master","paths":["deploy/keys.yml"]}]
        """]
        let dryRun = await ScriptEngine().run(javaScript: validated.javaScript,
                                              phase: .update,
                                              params: validated.meta.params,
                                              github: client,
                                              organisation: "example-org",
                                              initialState: state,
                                              onEvent: { _ in })
        #expect(dryRun.status == .completed)
        #expect(dryRun.artifacts.isEmpty)
        return (validated, state, dryRun.plannedActions)
    }

    private func armedConfiguration(targets: Set<String>,
                                    plan: [String: [PlannedAction]],
                                    registry: [Artifact] = []) -> EngineConfiguration {
        var configuration = EngineConfiguration()
        configuration.writeMode = .armed
        configuration.targetRepos = targets
        configuration.referencePlan = plan
        configuration.artifactRegistry = registry
        return configuration
    }

    @Test("armed apply creates branches and PRs on the fixture, with artifacts")
    func armedApplyEndToEnd() async throws {
        let client = FixtureGitHubClient.demo()
        let (validated, state, plan) = try await dryRunPlan(client: client)
        #expect(plan.keys.sorted() == ["example-org/data-pipeline", "example-org/web-frontend"])

        let armed = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update,
                                             params: validated.meta.params,
                                             github: client,
                                             organisation: "example-org",
                                             configuration: armedConfiguration(
                                                targets: ["example-org/web-frontend", "example-org/data-pipeline"],
                                                plan: plan),
                                             initialState: state,
                                             onEvent: { _ in })
        #expect(armed.status == .completed)

        // Both repos end as PR-raised, with branch + PR artifacts each.
        var statusByRepo: [String: RepoResult] = [:]
        for result in armed.results { statusByRepo[result.id] = result }
        #expect(statusByRepo["example-org/web-frontend"]?.status == .prRaised)
        #expect(statusByRepo["example-org/data-pipeline"]?.status == .prRaised)
        #expect(armed.artifacts.filter { $0.kind == .branch }.count == 2)
        #expect(armed.artifacts.filter { $0.kind == .pullRequest }.count == 2)
        #expect(armed.artifacts.allSatisfy { $0.kind == .branch || $0.url != nil })

        // The fixture actually holds the writes: branch content matches the
        // reviewed plan's "after", and the PR targets the repo's REAL default
        // branch (master for data-pipeline — never an assumed main).
        let branch = "bulkgh/remove-legacy-deploy-key"
        let webEdited = client.branchContent(repo: "example-org/web-frontend",
                                             branch: branch, path: "deploy/infra.json")
        #expect(webEdited?.contains("deploy-key-2019") == false)
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
        client.contents["example-org/web-frontend"]?["deploy/infra.json"] = """
        {
          "stack": "web-frontend",
          "region": "eu-west-1",
          "deployKey": "legacy-deploy-key-2019",
          "addedSinceReview": true
        }
        """

        let armed = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update,
                                             params: validated.meta.params,
                                             github: client,
                                             organisation: "example-org",
                                             configuration: armedConfiguration(
                                                targets: ["example-org/web-frontend", "example-org/data-pipeline"],
                                                plan: plan),
                                             initialState: state,
                                             onEvent: { _ in })
        #expect(armed.status == .completed)

        let web = armed.results.first { $0.id == "example-org/web-frontend" }
        #expect(web?.status == .conflicted)
        #expect(web?.reason?.contains("changed on the remote") == true)
        // Nothing written for the drifted repo beyond its branch; no PR.
        #expect(client.createdPRs.allSatisfy { $0.repo != "example-org/web-frontend" })
        #expect(client.branchContent(repo: "example-org/web-frontend",
                                     branch: "bulkgh/remove-legacy-deploy-key",
                                     path: "deploy/infra.json")?
            .contains("deploy-key-2019") == true)  // branch still holds the untouched copy

        // The clean repo is unaffected by its neighbour's drift.
        let pipeline = armed.results.first { $0.id == "example-org/data-pipeline" }
        #expect(pipeline?.status == .prRaised)
    }

    @Test("plan conformance: a doctored reference plan halts the repo as conflicted")
    func planConformance() async throws {
        let client = FixtureGitHubClient.demo()
        let (validated, state, plan) = try await dryRunPlan(client: client)

        // Tamper with the reviewed "after" for one repo: the script will
        // produce content that no longer matches the review.
        var doctored = plan
        doctored["example-org/web-frontend"] = doctored["example-org/web-frontend"]?.map { action in
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
                                             organisation: "example-org",
                                             configuration: armedConfiguration(
                                                targets: ["example-org/web-frontend"],
                                                plan: doctored),
                                             initialState: state,
                                             onEvent: { _ in })
        #expect(armed.status == .completed)
        let web = armed.results.first { $0.id == "example-org/web-frontend" }
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
                                             organisation: "example-org",
                                             configuration: armedConfiguration(
                                                targets: ["example-org/data-pipeline"],
                                                plan: plan),
                                             initialState: state,
                                             onEvent: { _ in })
        #expect(armed.status == .completed)
        let web = armed.results.first { $0.id == "example-org/web-frontend" }
        #expect(web?.status == .skipped)
        #expect(client.createdBranches["example-org/web-frontend"] == nil)
        #expect(armed.artifacts.allSatisfy { $0.repo == "example-org/data-pipeline" })
    }

    @Test("resume: a second armed run continues through the job's own artifacts, no duplicates")
    func resumeRerun() async throws {
        let client = FixtureGitHubClient.demo()
        let (validated, state, plan) = try await dryRunPlan(client: client)
        let configuration = armedConfiguration(
            targets: ["example-org/web-frontend", "example-org/data-pipeline"], plan: plan)

        let first = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update, params: validated.meta.params,
                                             github: client, organisation: "example-org",
                                             configuration: configuration,
                                             initialState: state, onEvent: { _ in })
        #expect(first.artifacts.count == 4)

        // Second run carries the first run's receipts: everything resumes —
        // branch reused, contents already match, PR already open — ending
        // prRaised with nothing new created.
        let rerunConfig = armedConfiguration(
            targets: ["example-org/web-frontend", "example-org/data-pipeline"], plan: plan,
            registry: first.artifacts)
        let second = await ScriptEngine().run(javaScript: validated.javaScript,
                                              phase: .update, params: validated.meta.params,
                                              github: client, organisation: "example-org",
                                              configuration: rerunConfig,
                                              initialState: state, onEvent: { _ in })
        #expect(second.status == .completed)
        #expect(second.artifacts.isEmpty)
        for result in second.results where ["example-org/web-frontend", "example-org/data-pipeline"].contains(result.id) {
            #expect(result.status == .prRaised)
            #expect(result.reason?.contains("resumed") == true)
        }
        #expect(client.createdPRs.count == 2)  // still just the first run's

        let resumes = second.auditEvents.filter { $0.detail.contains("resum") }
        #expect(resumes.count == 6)  // 2 × (branch + put + PR)
    }

    @Test("resume completes a partially-applied repo (crash after branch creation)")
    func resumePartialApply() async throws {
        let client = FixtureGitHubClient.demo()
        let (validated, state, plan) = try await dryRunPlan(client: client)

        // Simulate a run that died right after creating web-frontend's
        // branch: the branch exists and the job holds its receipt; no
        // content was committed, no PR opened.
        let branch = "bulkgh/remove-legacy-deploy-key"
        _ = try await client.createBranch(repo: "example-org/web-frontend", name: branch,
                                          fromSha: "deadbeef")
        let registry = [Artifact(kind: .branch, repo: "example-org/web-frontend", name: branch)]

        let armed = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update, params: validated.meta.params,
                                             github: client, organisation: "example-org",
                                             configuration: armedConfiguration(
                                                targets: ["example-org/web-frontend", "example-org/data-pipeline"],
                                                plan: plan, registry: registry),
                                             initialState: state, onEvent: { _ in })
        #expect(armed.status == .completed)
        var byRepo: [String: RepoResult] = [:]
        for result in armed.results { byRepo[result.id] = result }
        #expect(byRepo["example-org/web-frontend"]?.status == .prRaised)
        #expect(byRepo["example-org/data-pipeline"]?.status == .prRaised)
        // The resumed repo got its missing content and PR for real.
        #expect(client.branchContent(repo: "example-org/web-frontend", branch: branch,
                                     path: "deploy/infra.json")?.contains("deploy-key-2019") == false)
        #expect(client.createdPRs.count == 2)
        // Branch reused, not re-created: only the PR artifact is new for it.
        #expect(armed.artifacts.filter { $0.repo == "example-org/web-frontend" }.map(\.kind) == [.pullRequest])
    }

    @Test("a same-named branch the job did NOT create halts the repo")
    func foreignBranchHalts() async throws {
        let client = FixtureGitHubClient.demo()
        let (validated, state, plan) = try await dryRunPlan(client: client)
        _ = try await client.createBranch(repo: "example-org/web-frontend",
                                          name: "bulkgh/remove-legacy-deploy-key",
                                          fromSha: "someoneelse")

        // No receipt for that branch in the registry → halt, touch nothing.
        let armed = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update, params: validated.meta.params,
                                             github: client, organisation: "example-org",
                                             configuration: armedConfiguration(
                                                targets: ["example-org/web-frontend", "example-org/data-pipeline"],
                                                plan: plan),
                                             initialState: state, onEvent: { _ in })
        let web = armed.results.first { $0.id == "example-org/web-frontend" }
        #expect(web?.status == .branchExists)
        #expect(web?.reason?.contains("not created by this job") == true)
        #expect(client.createdPRs.allSatisfy { $0.repo != "example-org/web-frontend" })
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
                                                github: client, organisation: "example-org",
                                                configuration: noTargets,
                                                initialState: state, onEvent: { _ in })
        guard case .failed(let message1) = outcome1.status else {
            Issue.record("expected failure without targets"); return
        }
        #expect(message1.contains("selection"))

        var noPlan = EngineConfiguration()
        noPlan.writeMode = .armed
        noPlan.targetRepos = ["example-org/web-frontend"]
        let outcome2 = await ScriptEngine().run(javaScript: validated.javaScript,
                                                phase: .update, params: validated.meta.params,
                                                github: client, organisation: "example-org",
                                                configuration: noPlan,
                                                initialState: state, onEvent: { _ in })
        guard case .failed(let message2) = outcome2.status else {
            Issue.record("expected failure without a plan"); return
        }
        #expect(message2.contains("plan"))
    }

    @Test("live writes fail closed without credentials — no request leaves the box")
    func liveWritesRequireCredentials() async {
        // The kill switch is now open (0.4.0) — writes are guarded by the
        // engine's armed bindings and the arming confirmation instead. With
        // no token, every write throws before any request is even built, so
        // this test exercises the live write paths without touching the
        // network.
        #expect(LiveGitHubClient.liveWritesEnabled)
        let client = LiveGitHubClient(apiHost: "https://api.github.com",
                                      tokenProvider: { nil })
        await #expect(throws: GitHubClientError.missingCredentials) {
            _ = try await client.createBranch(repo: "example-org/x", name: "bulkgh/t", fromSha: "abc")
        }
        await #expect(throws: GitHubClientError.missingCredentials) {
            _ = try await client.putContent(repo: "example-org/x", path: "f", content: "c",
                                            branch: "bulkgh/t", message: "m")
        }
        await #expect(throws: GitHubClientError.missingCredentials) {
            _ = try await client.createPR(repo: "example-org/x", head: "bulkgh/t", base: "main",
                                          title: "t", body: "b")
        }
        await #expect(throws: GitHubClientError.missingCredentials) {
            _ = try await client.mergePR(repo: "example-org/x", number: 1, expectedHeadSha: "abc")
        }
        await #expect(throws: GitHubClientError.missingCredentials) {
            try await client.deleteBranch(repo: "example-org/x", name: "bulkgh/t")
        }
    }
}
