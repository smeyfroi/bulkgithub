import Foundation
import Testing
@testable import BulkGitHubKit

@Suite("Dry-run update phase")
struct UpdatePhaseTests {

    @Test("deploy-key removal: plans both files with exact contents, incl. JSON comma repair")
    func deployKeyDryRun() async throws {
        let recipe = try #require(ResourceLocator.recipe(named: "remove_line_with_string"))
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.meta.phase == .update)

        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: validated.meta.phase,
                                               params: validated.meta.params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "example-org",
                                               onEvent: { _ in })
        #expect(outcome.status == .completed)

        // JSON file: needle line removed AND the now-dangling comma on the
        // previous line repaired (the kv pair was last in its object).
        let webActions = try #require(outcome.plannedActions["example-org/web-frontend"])
        #expect(webActions.count == 3)
        guard case .createBranch(let branch, let fromSha) = webActions[0] else {
            Issue.record("expected createBranch first"); return
        }
        #expect(branch == "bulkgh/remove-legacy-deploy-key")
        #expect(!fromSha.isEmpty)
        guard case .putContent(let path, _, _, let before, let after) = webActions[1] else {
            Issue.record("expected putContent second"); return
        }
        #expect(path == "deploy/infra.json")
        #expect(before?.contains("deploy-key-2019") == true)
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
        #expect(title == "Remove retired deploy key reference")

        // YAML file: needle line removed, everything else untouched.
        let pipelineActions = try #require(outcome.plannedActions["example-org/data-pipeline"])
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
        #expect(statusByRepo["example-org/web-frontend"] == .planned)
        #expect(statusByRepo["example-org/data-pipeline"] == .planned)
        #expect(statusByRepo["example-org/api-service"] == .skipped)
        #expect(statusByRepo["example-org/legacy-batch"] == .skipped)
        #expect(statusByRepo["example-org/flaky-service"] == .failed)

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
            await gh.createBranch("example-org/api-service", "feature/sneaky", "abc123");
            job.log("no-throw");
          } catch (e) {
            job.log("threw: " + String(e));
          }
        }
        """, phase: .update, params: [:], github: FixtureGitHubClient.demo(),
             organisation: "example-org", onEvent: { _ in })
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
          const ref = await gh.getRef("example-org/x", "heads/main");
          if (ref) await gh.createBranch("example-org/x", "bulkgh/test", ref.sha);
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
            organisation: "example-org", onEvent: { _ in })
        #expect(outcome.logs.contains("t=undefined"))
    }

    @Test("the selected phase drives mock generation, like the real system prompt")
    func mockRouting() async throws {
        let prompt = "delete the line containing `retired-token-xyz` from files in config/"
        let updateScript = try await MockLLMClient().makeScript(
            prompt: prompt,
            context: ScriptGenerationContext(organisation: "example-org", phase: .update))
        #expect(updateScript.contains("needle: \"retired-token-xyz\""))
        #expect(updateScript.contains("glob: \"config/**\""))
        #expect(ValidationPipeline.sniffPhase(from: updateScript) == .update)

        // The same prompt in check phase yields a check script — generation
        // follows the selected phase, not prompt keywords.
        let checkScript = try await MockLLMClient().makeScript(
            prompt: prompt,
            context: ScriptGenerationContext(organisation: "example-org", phase: .check))
        #expect(ValidationPipeline.sniffPhase(from: checkScript) == .check)
    }
}

@Suite("Cross-phase state and canary")
struct StateAndCanaryTests {

    @Test("check results carry into update via job state — the search never repeats")
    func stateCarryOver() async throws {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())

        let checkRecipe = try #require(ResourceLocator.recipe(named: "find_string_in_path"))
        let check = try pipeline.validate(source: checkRecipe)
        let checkOutcome = await ScriptEngine().run(javaScript: check.javaScript,
                                                    phase: .check,
                                                    params: check.meta.params,
                                                    github: FixtureGitHubClient.demo(),
                                                    organisation: "example-org",
                                                    onEvent: { _ in })
        #expect(checkOutcome.state["stringMatches"]?.contains("web-frontend") == true)

        let updateRecipe = try #require(ResourceLocator.recipe(named: "remove_line_with_string"))
        let update = try pipeline.validate(source: updateRecipe)
        let client = FixtureGitHubClient.demo()
        let updateOutcome = await ScriptEngine().run(javaScript: update.javaScript,
                                                     phase: .update,
                                                     params: update.meta.params,
                                                     github: client,
                                                     organisation: "example-org",
                                                     initialState: checkOutcome.state,
                                                     onEvent: { _ in })
        #expect(updateOutcome.status == .completed)
        #expect(updateOutcome.plannedActions.keys.sorted()
                == ["example-org/data-pipeline", "example-org/web-frontend"])

        // No org enumeration, no tree listings — and only the two matched
        // files re-fetched for fresh diffs.
        #expect(!client.callLog.contains { $0.hasPrefix("listOrgRepos") })
        #expect(!client.callLog.contains { $0.hasPrefix("listFiles") })
        #expect(client.callLog.filter { $0.hasPrefix("getContent") }.count == 2)
    }

    @Test("canary confines a full-scan update to one repo")
    func canaryFullScan() async throws {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let recipe = try #require(ResourceLocator.recipe(named: "remove_line_with_string"))
        let validated = try pipeline.validate(source: recipe)

        var configuration = EngineConfiguration()
        configuration.targetRepos = ["example-org/data-pipeline"]
        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: .update,
                                               params: validated.meta.params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "example-org",
                                               configuration: configuration,
                                               onEvent: { _ in })
        #expect(Array(outcome.plannedActions.keys) == ["example-org/data-pipeline"])
        #expect(outcome.results.map(\.id) == ["example-org/data-pipeline"])
    }

    @Test("canary drops carried-over actions for non-target repos")
    func canaryWithState() async throws {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let recipe = try #require(ResourceLocator.recipe(named: "remove_line_with_string"))
        let validated = try pipeline.validate(source: recipe)

        let state = ["stringMatches": """
        [{"repo":"example-org/web-frontend","defaultBranch":"main","paths":["deploy/infra.json"]},\
        {"repo":"example-org/data-pipeline","defaultBranch":"master","paths":["deploy/keys.yml"]}]
        """]
        var configuration = EngineConfiguration()
        configuration.targetRepos = ["example-org/data-pipeline"]
        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: .update,
                                               params: validated.meta.params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "example-org",
                                               configuration: configuration,
                                               initialState: state,
                                               onEvent: { _ in })
        #expect(Array(outcome.plannedActions.keys) == ["example-org/data-pipeline"])
        let web = outcome.results.first { $0.id == "example-org/web-frontend" }
        #expect(web?.status == .skipped)
        #expect(web?.reason?.contains("canary") == true)
    }
}

@Suite("Rate limit and recipe catalog")
struct SupportingFeatureTests {

    @Test("rate limit monitor parses GitHub quota headers")
    func rateLimitParsing() throws {
        let monitor = RateLimitMonitor()
        #expect(monitor.display == nil)
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/x/y")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["X-RateLimit-Remaining": "4321",
                           "X-RateLimit-Limit": "5000",
                           "X-RateLimit-Reset": "1765400000"]))
        monitor.update(from: response)
        #expect(monitor.display == "API 4321/5000")
        #expect(!monitor.isLow)
        #expect(monitor.snapshot.resetAt != nil)
    }

    @Test("every catalog recipe resolves and declares its advertised phase")
    func catalogConsistency() throws {
        #expect(RecipeCatalog.all.count == 9)
        for recipe in RecipeCatalog.all {
            let source = try #require(recipe.source, "missing source for \(recipe.id)")
            #expect(ValidationPipeline.sniffPhase(from: source) == recipe.phase,
                    "\(recipe.id) phase mismatch")
            #expect(!recipe.prompt.isEmpty)
        }
    }
}

@Suite("Diff builder")
struct DiffBuilderTests {

    @Test("line removal with neighbour repair produces removed/added/context lines")
    func jsonRepairDiff() {
        let before = """
        {
          "region": "eu-west-1",
          "deployKey": "old"
        }
        """
        let after = """
        {
          "region": "eu-west-1"
        }
        """
        let lines = DiffBuilder.lines(before: before, after: after)
        #expect(lines.filter { $0.kind == .removed }.count == 2)   // old region+comma, deployKey
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
