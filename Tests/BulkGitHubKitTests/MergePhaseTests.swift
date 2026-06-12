import Foundation
import Testing
@testable import BulkGitHubKit

/// Against fixtures: the registry-scoped merge surface, the approval
/// requirement, the head-SHA precondition, and the cancel flow. Completes the
/// loop: check → update → apply → approve → merge/cancel, all offline.
@Suite("Merge phase (registry-scoped, approval-gated)")
struct MergePhaseTests {

    /// Stand up a job with real fixture artifacts: dry-run the update recipe,
    /// apply it armed, and return everything the merge phase needs.
    private func appliedJob(client: FixtureGitHubClient) async throws
        -> (artifacts: [Artifact], prs: [PullRequestRef]) {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let recipe = try #require(ResourceLocator.recipe(named: "remove_line_with_string"))
        let validated = try pipeline.validate(source: recipe)
        let state = ["stringMatches": """
        [{"repo":"example-org/web-frontend","defaultBranch":"main","paths":["deploy/infra.json"]},\
        {"repo":"example-org/data-pipeline","defaultBranch":"master","paths":["deploy/keys.yml"]}]
        """]

        let dryRun = await ScriptEngine().run(javaScript: validated.javaScript, phase: .update,
                                              params: validated.meta.params, github: client,
                                              organisation: "example-org", initialState: state,
                                              onEvent: { _ in })
        var configuration = EngineConfiguration()
        configuration.writeMode = .armed
        configuration.targetRepos = ["example-org/web-frontend", "example-org/data-pipeline"]
        configuration.referencePlan = dryRun.plannedActions
        let applied = await ScriptEngine().run(javaScript: validated.javaScript, phase: .update,
                                               params: validated.meta.params, github: client,
                                               organisation: "example-org", configuration: configuration,
                                               initialState: state, onEvent: { _ in })
        #expect(applied.artifacts.count == 4)
        return (applied.artifacts, client.createdPRs)
    }

    private func validatedMerge(named name: String) throws -> ValidatedScript {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let recipe = try #require(ResourceLocator.recipe(named: name))
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.meta.phase == .merge)
        return validated
    }

    private func approvals(for prs: [PullRequestRef]) -> [Approval] {
        prs.map { Approval(repo: $0.repo, prNumber: $0.number, headSha: $0.headSha) }
    }

    @Test("approve → dry-run plan → armed merge: PRs merged, branches deleted")
    func mergeEndToEnd() async throws {
        let client = FixtureGitHubClient.demo()
        let (artifacts, prs) = try await appliedJob(client: client)
        let merge = try validatedMerge(named: "merge_approved_prs")
        let approved = approvals(for: prs)

        // Dry run records the plan: merge + delete per repo.
        var dryConfig = EngineConfiguration()
        dryConfig.artifactRegistry = artifacts
        dryConfig.approvals = approved
        let plan = await ScriptEngine().run(javaScript: merge.javaScript, phase: .merge,
                                            params: merge.meta.params, github: client,
                                            organisation: "example-org", configuration: dryConfig,
                                            onEvent: { _ in })
        #expect(plan.status == .completed)
        #expect(plan.plannedActions.keys.sorted() == ["example-org/data-pipeline", "example-org/web-frontend"])
        for actions in plan.plannedActions.values {
            #expect(actions.count == 2)  // mergePR + deleteBranch
        }
        #expect(client.createdPRs.allSatisfy { $0.state == "open" })  // nothing executed

        // Armed: conforms to the plan and executes.
        var armedConfig = dryConfig
        armedConfig.writeMode = .armed
        armedConfig.targetRepos = ["example-org/web-frontend", "example-org/data-pipeline"]
        armedConfig.referencePlan = plan.plannedActions
        let armed = await ScriptEngine().run(javaScript: merge.javaScript, phase: .merge,
                                             params: merge.meta.params, github: client,
                                             organisation: "example-org", configuration: armedConfig,
                                             onEvent: { _ in })
        #expect(armed.status == .completed)
        #expect(client.createdPRs.allSatisfy { $0.state == "merged" })
        #expect(client.createdBranches["example-org/web-frontend"]?.isEmpty != false)
        #expect(client.createdBranches["example-org/data-pipeline"]?.isEmpty != false)
        for result in armed.results { #expect(result.status == .merged) }
        let writes = armed.auditEvents.filter { $0.kind.hasPrefix("write.") }
        #expect(writes.count == 4)  // 2 × (merge + delete)
    }

    @Test("an unapproved PR is refused — blocked, nothing merged")
    func approvalRequired() async throws {
        let client = FixtureGitHubClient.demo()
        let (artifacts, prs) = try await appliedJob(client: client)
        let merge = try validatedMerge(named: "merge_approved_prs")

        // Approve only one of the two.
        let webOnly = approvals(for: prs.filter { $0.repo == "example-org/web-frontend" })
        var config = EngineConfiguration()
        config.artifactRegistry = artifacts
        config.approvals = webOnly
        let plan = await ScriptEngine().run(javaScript: merge.javaScript, phase: .merge,
                                            params: merge.meta.params, github: client,
                                            organisation: "example-org", configuration: config,
                                            onEvent: { _ in })
        #expect(plan.status == .completed)
        let pipeline = plan.results.first { $0.id == "example-org/data-pipeline" }
        #expect(pipeline?.status == .blocked)
        #expect(pipeline?.reason?.contains("not approved") == true)
        #expect(plan.plannedActions.keys.sorted() == ["example-org/web-frontend"])
    }

    @Test("a head that moved since approval halts the repo as conflicted")
    func approvalDriftGuard() async throws {
        let client = FixtureGitHubClient.demo()
        let (artifacts, prs) = try await appliedJob(client: client)
        let merge = try validatedMerge(named: "merge_approved_prs")
        let approved = approvals(for: prs)

        // The branch moves after approval (another commit lands on it).
        _ = try await client.putContent(repo: "example-org/web-frontend", path: "deploy/infra.json",
                                        content: "moved after approval",
                                        branch: "bulkgh/remove-legacy-deploy-key",
                                        message: "drift")

        var config = EngineConfiguration()
        config.artifactRegistry = artifacts
        config.approvals = approved
        let plan = await ScriptEngine().run(javaScript: merge.javaScript, phase: .merge,
                                            params: merge.meta.params, github: client,
                                            organisation: "example-org", configuration: config,
                                            onEvent: { _ in })
        let web = plan.results.first { $0.id == "example-org/web-frontend" }
        #expect(web?.status == .conflicted)
        #expect(web?.reason?.contains("moved since approval") == true)
        // The untouched repo still plans normally.
        #expect(plan.plannedActions.keys.sorted() == ["example-org/data-pipeline"])
        #expect(client.createdPRs.allSatisfy { $0.state == "open" })
    }

    @Test("merge scripts cannot touch PRs outside the job's registry")
    func registryScoping() async throws {
        let client = FixtureGitHubClient.demo()
        let (artifacts, prs) = try await appliedJob(client: client)
        // A PR exists on the remote that this job did NOT create.
        let foreign = try await client.createBranch(repo: "example-org/api-service",
                                                    name: "bulkgh/other-job", fromSha: "abc")
        _ = foreign
        let foreignPR = try await client.createPR(repo: "example-org/api-service",
                                                  head: "bulkgh/other-job", base: "main",
                                                  title: "other job", body: "")

        var config = EngineConfiguration()
        config.artifactRegistry = artifacts
        config.approvals = approvals(for: prs) + [
            Approval(repo: foreignPR.repo, prNumber: foreignPR.number, headSha: foreignPR.headSha),
        ]
        let script = """
        const meta = { title: "rogue merge", phase: "merge" as const, apiVersion: 1, params: {} };
        async function main(): Promise<void> {
          try {
            await gh.mergePR("example-org/api-service", \(foreignPR.number), { expectedHeadSha: "\(foreignPR.headSha)" });
            job.log("no-throw");
          } catch (e) {
            job.log("threw: " + String(e));
          }
        }
        """
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: script)
        let outcome = await ScriptEngine().run(javaScript: validated.javaScript, phase: .merge,
                                               params: [:], github: client,
                                               organisation: "example-org", configuration: config,
                                               onEvent: { _ in })
        #expect(outcome.logs.contains { $0.hasPrefix("threw:") && $0.contains("registry") })
        let pr = try await client.getPR(repo: foreignPR.repo, number: foreignPR.number)
        #expect(pr.state == "open")
    }

    @Test("cancel recipe closes job PRs and deletes job branches")
    func cancelFlow() async throws {
        let client = FixtureGitHubClient.demo()
        let (artifacts, _) = try await appliedJob(client: client)
        let cancel = try validatedMerge(named: "cancel_job")

        var dryConfig = EngineConfiguration()
        dryConfig.artifactRegistry = artifacts
        let plan = await ScriptEngine().run(javaScript: cancel.javaScript, phase: .merge,
                                            params: cancel.meta.params, github: client,
                                            organisation: "example-org", configuration: dryConfig,
                                            onEvent: { _ in })
        #expect(plan.status == .completed)
        #expect(plan.plannedActions.count == 2)  // close + delete per repo

        var armedConfig = dryConfig
        armedConfig.writeMode = .armed
        armedConfig.targetRepos = ["example-org/web-frontend", "example-org/data-pipeline"]
        armedConfig.referencePlan = plan.plannedActions
        let armed = await ScriptEngine().run(javaScript: cancel.javaScript, phase: .merge,
                                             params: cancel.meta.params, github: client,
                                             organisation: "example-org", configuration: armedConfig,
                                             onEvent: { _ in })
        #expect(armed.status == .completed)
        #expect(client.createdPRs.allSatisfy { $0.state == "closed" })
        #expect(client.createdBranches["example-org/web-frontend"]?.isEmpty != false)
        for result in armed.results { #expect(result.status == .cancelled) }
        // Cancel needs no approvals — closing is winding back, not shipping.
    }

    @Test("the merge surface only type-checks for merge-phase scripts")
    func phaseGatedDeclarations() throws {
        let service = try #require(TypeScriptService.loadDefault())
        let pipeline = ValidationPipeline(typescript: service)
        let body = """
        async function main(): Promise<void> {
          const prs = await gh.listJobPRs();
          if (prs.length > 0) await gh.mergePR(prs[0].repo, prs[0].number, { expectedHeadSha: prs[0].headSha });
        }
        """
        let updateScript = "const meta = { title: \"t\", phase: \"update\" };\n" + body
        #expect(throws: ValidationError.self) {
            try pipeline.validate(source: updateScript)
        }
        let mergeScript = "const meta = { title: \"t\", phase: \"merge\" };\n" + body
        let validated = try pipeline.validate(source: mergeScript)
        #expect(validated.meta.phase == .merge)
    }
}
