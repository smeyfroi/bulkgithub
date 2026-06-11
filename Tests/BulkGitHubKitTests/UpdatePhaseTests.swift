import Foundation
import Testing
@testable import BulkGitHubKit

@Suite("Dry-run update phase")
struct UpdatePhaseTests {

    @Test("keypair removal: plans both files with exact contents, incl. JSON comma repair")
    func keypairDryRun() async throws {
        let recipe = try #require(ResourceLocator.recipe(named: "remove_line_with_string"))
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.meta.phase == .update)

        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: validated.meta.phase,
                                               params: validated.meta.params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "geome",
                                               onEvent: { _ in })
        #expect(outcome.status == .completed)

        // JSON file: needle line removed AND the now-dangling comma on the
        // previous line repaired (the kv pair was last in its object).
        let webActions = try #require(outcome.plannedActions["geome/web-frontend"])
        #expect(webActions.count == 3)
        guard case .createBranch(let branch, let fromSha) = webActions[0] else {
            Issue.record("expected createBranch first"); return
        }
        #expect(branch == "bulkgh/remove-keypair-reference")
        #expect(!fromSha.isEmpty)
        guard case .putContent(let path, _, _, let before, let after) = webActions[1] else {
            Issue.record("expected putContent second"); return
        }
        #expect(path == "deploy/infra.json")
        #expect(before?.contains("keypair-1") == true)
        #expect(after == """
        {
          "stack": "web-frontend",
          "region": "eu-west-1"
        }
        """)
        guard case .createPR(let head, let title, _) = webActions[2] else {
            Issue.record("expected createPR third"); return
        }
        #expect(head == branch)
        #expect(title == "Remove retired keypair reference")

        // YAML file: needle line removed, everything else untouched.
        let pipelineActions = try #require(outcome.plannedActions["geome/data-pipeline"])
        let edits = pipelineActions.compactMap { action -> String? in
            guard case .putContent(_, _, _, _, let after) = action else { return nil }
            return after
        }
        #expect(edits == ["""
        region: eu-west-1
        instanceType: m5.large
        """])

        // Statuses across the org.
        var statusByRepo: [String: RepoStatus] = [:]
        for result in outcome.results { statusByRepo[result.id] = result.status }
        #expect(statusByRepo["geome/web-frontend"] == .planned)
        #expect(statusByRepo["geome/data-pipeline"] == .planned)
        #expect(statusByRepo["geome/api-service"] == .skipped)
        #expect(statusByRepo["geome/legacy-batch"] == .skipped)
        #expect(statusByRepo["geome/flaky-service"] == .failed)

        // Audit trail labels every recorded write as dry-run.
        let planEvents = outcome.auditEvents.filter { $0.kind.hasPrefix("plan.") }
        #expect(planEvents.count == 6)  // 2 × (branch + put + PR)
        #expect(planEvents.allSatisfy { $0.detail.contains("dry-run") })
    }

    @Test("branch names without the job prefix are refused, even in dry-run")
    func branchGuardrail() async {
        let outcome = await ScriptEngine().run(javaScript: """
        async function main() {
          try {
            await gh.createBranch("geome/api-service", "feature/sneaky", "abc123");
            job.log("no-throw");
          } catch (e) {
            job.log("threw: " + String(e));
          }
        }
        """, phase: .update, params: [:], github: FixtureGitHubClient.demo(),
             organisation: "geome", onEvent: { _ in })
        #expect(outcome.status == .completed)
        #expect(outcome.logs.contains { $0.hasPrefix("threw:") && $0.contains("bulkgh/") })
        #expect(outcome.plannedActions.isEmpty)
    }

    @Test("the write surface only type-checks for update-phase scripts")
    func phaseGatedDeclarations() throws {
        let service = try #require(TypeScriptService.loadDefault())
        let pipeline = ValidationPipeline(typescript: service)
        let body = """
        async function main(): Promise<void> {
          const ref = await gh.getRef("geome/x", "heads/main");
          if (ref) await gh.createBranch("geome/x", "bulkgh/test", ref.sha);
        }
        """

        let checkScript = "const meta = { title: \"t\", phase: \"check\" };\n" + body
        #expect(throws: ValidationError.self) {
            try pipeline.validate(source: checkScript)
        }

        let updateScript = "const meta = { title: \"t\", phase: \"update\" };\n" + body
        let validated = try pipeline.validate(source: updateScript)
        #expect(validated.meta.phase == .update)
        #expect(validated.diagnostics.filter { $0.severity == .error }.isEmpty)
    }

    @Test("write methods are absent at runtime in check phase regardless of types")
    func runtimeGating() async {
        let outcome = await ScriptEngine().run(
            javaScript: "async function main() { job.log(\"t=\" + typeof gh.putContent); }",
            phase: .check, params: [:], github: FixtureGitHubClient.demo(),
            organisation: "geome", onEvent: { _ in })
        #expect(outcome.logs.contains("t=undefined"))
    }

    @Test("mock routes line-deletion prompts to the update recipe")
    func mockRouting() async throws {
        let prompt = "delete the line containing `retired-token-xyz` from files in config/"
        let script = try await MockLLMClient().makeScript(
            prompt: prompt, context: ScriptGenerationContext(organisation: "geome"))
        #expect(script.contains("needle: \"retired-token-xyz\""))
        #expect(script.contains("glob: \"config/**\""))
        #expect(ValidationPipeline.sniffPhase(from: script) == .update)
    }
}

@Suite("Diff builder")
struct DiffBuilderTests {

    @Test("line removal with neighbour repair produces removed/added/context lines")
    func jsonRepairDiff() {
        let before = """
        {
          "region": "eu-west-1",
          "keyPair": "old"
        }
        """
        let after = """
        {
          "region": "eu-west-1"
        }
        """
        let lines = DiffBuilder.lines(before: before, after: after)
        #expect(lines.filter { $0.kind == .removed }.count == 2)   // old region+comma, keyPair
        #expect(lines.filter { $0.kind == .added }.count == 1)     // region without comma
        #expect(lines.filter { $0.kind == .context }.map(\.text) == ["{", "}"])
    }

    @Test("identical inputs are all context")
    func identical() {
        let lines = DiffBuilder.lines(before: "a\nb", after: "a\nb")
        #expect(lines.allSatisfy { $0.kind == .context })
        #expect(lines.count == 2)
    }
}
