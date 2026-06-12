import Foundation
import Testing
@testable import BulkGitHubKit

/// The full product loop on fixtures: validate the YAML worked example (lint
/// + type-check + transpile + meta), run it through the engine with a
/// read-only handle, and assert the exact per-repo outcomes the demo dataset
/// encodes.
@Suite("YAML recipe end-to-end")
struct GoldenRecipeTests {

    @Test("check run produces the expected per-repo statuses")
    func endToEnd() async throws {
        let recipe = try #require(ResourceLocator.recipe(named: "find_yaml_key_value"))
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.diagnostics.filter { $0.severity == .error }.isEmpty)

        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: validated.meta.phase,
                                               params: validated.meta.params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "example-org",
                                               onEvent: { _ in })

        #expect(outcome.status == .completed)

        var statusByRepo: [String: RepoStatus] = [:]
        for result in outcome.results { statusByRepo[result.id] = result.status }

        #expect(statusByRepo["example-org/api-service"] == .verifiedMatch)
        #expect(statusByRepo["example-org/data-pipeline"] == .verifiedMatch)
        #expect(statusByRepo["example-org/web-frontend"] == .skipped)
        #expect(statusByRepo["example-org/legacy-batch"] == .skipped)   // archived
        #expect(statusByRepo["example-org/infra-tools"] == .skipped)    // stale search hit
        #expect(statusByRepo["example-org/flaky-service"] == .failed)
        #expect(statusByRepo["example-org/docs-site"] == nil)           // never a candidate

        let match = outcome.results.first { $0.id == "example-org/api-service" }
        #expect(match?.evidence.first?.path == "project.json")
        #expect(match?.evidence.first?.explanation?.contains("type") == true)

        let skipReason = outcome.results.first { $0.id == "example-org/web-frontend" }?.reason
        #expect(skipReason?.contains("differs") == true)

        // Audit trail covers the effectful host calls, including the failed
        // fetch against the flaky repo.
        #expect(outcome.auditEvents.contains { $0.kind == "gh.searchCode" })
        let fetches = outcome.auditEvents.filter { $0.kind == "gh.getContent" }
        #expect(fetches.count == 5)
        #expect(fetches.contains { $0.repo == "example-org/flaky-service" && $0.detail.contains("failed") })
        #expect(outcome.auditEvents.filter { $0.kind == "job.reportMatch" }.count == 2)
    }

    @Test("edited params change behaviour without regeneration")
    func paramOverride() async throws {
        let recipe = try #require(ResourceLocator.recipe(named: "find_yaml_key_value"))
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)

        var params = validated.meta.params
        params["value"] = "react"   // web-frontend's project type in the fixtures

        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: validated.meta.phase,
                                               params: params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "example-org",
                                               onEvent: { _ in })

        var statusByRepo: [String: RepoStatus] = [:]
        for result in outcome.results { statusByRepo[result.id] = result.status }
        #expect(statusByRepo["example-org/web-frontend"] == .verifiedMatch)
        #expect(statusByRepo["example-org/api-service"] == .skipped)
    }
}

/// The golden recipe pair (README/license): the check half finds READMEs
/// missing the section, the update half plans appending it. Both against
/// the demo fixtures.
@Suite("Golden README recipe end-to-end")
struct ReadmeLicenseRecipeTests {

    @Test("check finds READMEs missing the License section")
    func checkEndToEnd() async throws {
        let recipe = try #require(ResourceLocator.goldenRecipe)
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(validated.meta.phase == .check)
        #expect(validated.meta.params["path"] == "README.md")
        #expect(validated.meta.params["marker"] == "# License")

        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: validated.meta.phase,
                                               params: validated.meta.params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "example-org",
                                               onEvent: { _ in })
        #expect(outcome.status == .completed)

        var statusByRepo: [String: RepoStatus] = [:]
        for result in outcome.results { statusByRepo[result.id] = result.status }
        #expect(statusByRepo["example-org/web-frontend"] == .verifiedMatch)
        #expect(statusByRepo["example-org/data-pipeline"] == .verifiedMatch)
        #expect(statusByRepo["example-org/docs-site"] == .verifiedMatch)
        #expect(statusByRepo["example-org/api-service"] == .skipped)      // already has the section
        #expect(statusByRepo["example-org/legacy-batch"] == .skipped)     // archived
        #expect(statusByRepo["example-org/infra-tools"] == .skipped)      // no README
        #expect(statusByRepo["example-org/flaky-service"] == .failed)

        // Matches carry forward for the update recipe (JSON-encoded, with
        // escaped slashes — assert on the repo names).
        #expect(outcome.state["missingMarker"]?.contains("web-frontend") == true)
        #expect(outcome.state["missingMarker"]?.contains("data-pipeline") == true)
    }

    @Test("update dry run plans branch + README edit + PR per matching repo")
    func updateDryRun() async throws {
        let recipe = try #require(ResourceLocator.recipe(named: "add_section_to_file"))
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

        var statusByRepo: [String: RepoStatus] = [:]
        for result in outcome.results { statusByRepo[result.id] = result.status }
        #expect(statusByRepo["example-org/web-frontend"] == .planned)
        #expect(statusByRepo["example-org/data-pipeline"] == .planned)
        #expect(statusByRepo["example-org/docs-site"] == .planned)
        #expect(statusByRepo["example-org/api-service"] == .skipped)
        #expect(statusByRepo["example-org/legacy-batch"] == .skipped)
        #expect(statusByRepo["example-org/flaky-service"] == .failed)

        let docsActions = try #require(outcome.plannedActions["example-org/docs-site"])
        #expect(docsActions.count == 3)
        guard case .createBranch(let branch, _) = docsActions[0] else {
            Issue.record("expected createBranch first"); return
        }
        #expect(branch == "bulkgh/add-license-section")
        guard case .putContent(let path, _, _, let before, let after) = docsActions[1] else {
            Issue.record("expected putContent second"); return
        }
        #expect(path == "README.md")
        #expect(before == "# Docs\n")
        #expect(after == "# Docs\n\n# License\n\nTBD\n")
        guard case .createPR(let head, let title, _) = docsActions[2] else {
            Issue.record("expected createPR third"); return
        }
        #expect(head == branch)
        #expect(title == "Add License section")
    }

    @Test("prompts route through the mock LLM to both recipes, params patched")
    func mockRouting() async throws {
        let check = try await MockLLMClient().makeScript(
            prompt: "find repos where the file README.md does not contain \"# License\"",
            context: ScriptGenerationContext(organisation: "example-org"))
        #expect(check.contains("path: \"README.md\""))
        #expect(check.contains("marker: \"# License\""))
        #expect(ValidationPipeline.sniffPhase(from: check) == .check)

        let update = try await MockLLMClient().makeScript(
            prompt: "add a '# License' section with 'TBD' to README.md",
            context: ScriptGenerationContext(organisation: "example-org", phase: .update))
        #expect(update.contains("heading: \"# License\""))
        #expect(update.contains("body: \"TBD\""))
        #expect(update.contains("path: \"README.md\""))
        #expect(ValidationPipeline.sniffPhase(from: update) == .update)
    }
}

/// The deploy-key worked example (plan v2 → update phases): the check half,
/// driven from the user's natural-language prompt through the mock LLM, the
/// validation pipeline, and the engine.
@Suite("Deploy-key recipe end-to-end")
struct DeployKeyRecipeTests {

    static let prompt = "repos where a file in deploy/ contains the string `legacy-deploy-key-2019`"

    @Test("prompt routes through the mock to a validated string-scan script")
    func promptToScript() async throws {
        let script = try await MockLLMClient().makeScript(
            prompt: Self.prompt,
            context: ScriptGenerationContext(organisation: "example-org"))
        #expect(script.contains("needle: \"legacy-deploy-key-2019\""))
        #expect(script.contains("glob: \"deploy/**\""))

        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: script)
        #expect(validated.meta.params["needle"] == "legacy-deploy-key-2019")
        #expect(validated.meta.params["glob"] == "deploy/**")
    }

    @Test("check run finds the YAML and JSON occurrences")
    func endToEnd() async throws {
        let recipe = try #require(ResourceLocator.recipe(named: "find_string_in_path"))
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.diagnostics.filter { $0.severity == .error }.isEmpty)

        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: validated.meta.phase,
                                               params: validated.meta.params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "example-org",
                                               onEvent: { _ in })

        #expect(outcome.status == .completed)

        var byRepo: [String: RepoResult] = [:]
        for result in outcome.results { byRepo[result.id] = result }

        // YAML occurrence
        #expect(byRepo["example-org/data-pipeline"]?.status == .verifiedMatch)
        #expect(byRepo["example-org/data-pipeline"]?.evidence.first?.path == "deploy/keys.yml")
        // JSON occurrence, key-value pair last in its object (the future
        // trailing-comma deletion case)
        #expect(byRepo["example-org/web-frontend"]?.status == .verifiedMatch)
        #expect(byRepo["example-org/web-frontend"]?.evidence.first?.path == "deploy/infra.json")
        #expect(byRepo["example-org/web-frontend"]?.evidence.first?.explanation?.contains("deployKey") == true)

        #expect(byRepo["example-org/api-service"]?.status == .skipped)       // deploy files, no needle
        #expect(byRepo["example-org/legacy-batch"]?.status == .skipped)      // archived
        #expect(byRepo["example-org/infra-tools"]?.status == .skipped)       // nothing matches the glob
        #expect(byRepo["example-org/docs-site"]?.status == .skipped)         // nothing matches the glob
        #expect(byRepo["example-org/flaky-service"]?.status == .failed)

        // All seven repos enumerated; every one reached a terminal status.
        #expect(outcome.results.count == 7)
        #expect(outcome.results.allSatisfy { $0.status != .candidate })
    }
}

@Suite("Support")
struct SupportTests {

    @Test("app state snapshot round-trips")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulkgh-test-\(UUID().uuidString)")
        let store = AppStateStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = AppSettings()
        settings.organisation = "example-org"
        settings.maxConcurrentOps = 3
        var job = Job(prompt: "find things")
        job.scriptSource = "async function main() {}"
        job.params = ["path": "x.yml"]
        job.results = [RepoResult(repo: RepoRef(fullName: "example-org/a"), status: .verifiedMatch,
                                  reason: "ok", evidence: [Evidence(path: "x.yml", excerpt: "k: v")])]
        job.auditEvents = [AuditEvent(kind: "gh.getContent", repo: "example-org/a", detail: "x.yml")]

        try store.save(AppStateSnapshot(settings: settings, job: job))
        let loaded = try #require(store.load())
        #expect(loaded.settings == settings)
        #expect(loaded.job?.prompt == "find things")
        #expect(loaded.job?.results.first?.evidence.first?.path == "x.yml")
        #expect(loaded.job?.auditEvents.count == 1)
    }

    @Test("user recipes save, rename, and delete through the store")
    func userRecipes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulkgh-recipes-\(UUID().uuidString)")
        let store = UserRecipeStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recipe = UserRecipe(title: "Find stale configs",
                                prompt: "find configs that are stale",
                                phase: .check,
                                source: "async function main() {}")
        try store.save(recipe)
        var loaded = store.load()
        #expect(loaded.map(\.id) == [recipe.id])
        #expect(loaded.first?.asRecipe.source == "async function main() {}")
        #expect(loaded.first?.asRecipe.phase == .check)

        var renamed = recipe
        renamed.title = "Audit configs"
        try store.save(renamed)
        loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Audit configs")

        try store.delete(id: recipe.id)
        #expect(store.load().isEmpty)
        // Deleting a missing recipe is a no-op, not an error.
        try store.delete(id: recipe.id)
    }

    @Test("mock LLM patches recipe params from the prompt")
    func mockGeneration() async throws {
        let client = MockLLMClient()
        let prompt = """
        find repos that include a file at config/settings.yaml where the key region \
        has a value of "us-east-1"
        """
        let script = try await client.makeScript(
            prompt: prompt,
            context: ScriptGenerationContext(organisation: "example-org"))
        #expect(script.contains("path: \"config/settings.yaml\""))
        #expect(script.contains("key: \"region\""))
        #expect(script.contains("value: \"us-east-1\""))

        // The patched script must still validate and carry the params in meta.
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: script)
        #expect(validated.meta.params["path"] == "config/settings.yaml")
    }

    @Test("in-memory credential store basics")
    func credentials() throws {
        let store = InMemoryCredentialStore()
        #expect(store.read(.githubToken) == nil)
        try store.write(.githubToken, value: "tok")
        #expect(store.read(.githubToken) == "tok")
        try store.delete(.githubToken)
        #expect(store.read(.githubToken) == nil)
    }

    @Test("code extraction from fenced LLM responses")
    func codeExtraction() {
        let fenced = """
        Here is the script:
        ```typescript
        const meta = { title: "x" };
        ```
        """
        #expect(PromptLibrary.extractCode(from: fenced) == "const meta = { title: \"x\" };")
        #expect(PromptLibrary.extractCode(from: "plain code") == "plain code")
    }
}

/// The two catalog scenarios introduced with the generic recipe set: the
/// glob-scanning YAML key/value check and the marker-block deletion update,
/// both against the demo fixtures, plus their mock-LLM prompt routing.
@Suite("Glob key/value and marker deletion recipes")
struct CatalogRecipeTests {

    @Test("glob key/value check finds RetentionInDays = 14")
    func globKeyValueEndToEnd() async throws {
        let recipe = try #require(ResourceLocator.recipe(named: "find_yaml_key_value_glob"))
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(validated.meta.phase == .check)

        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: validated.meta.phase,
                                               params: validated.meta.params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "example-org",
                                               onEvent: { _ in })
        #expect(outcome.status == .completed)

        var byRepo: [String: RepoResult] = [:]
        for result in outcome.results { byRepo[result.id] = result }

        #expect(byRepo["example-org/api-service"]?.status == .verifiedMatch)
        #expect(byRepo["example-org/api-service"]?.evidence.first?.path == "deploy/logging.yml")
        #expect(byRepo["example-org/web-frontend"]?.status == .skipped)        // 30, differs
        #expect(byRepo["example-org/web-frontend"]?.reason?.contains("differs") == true)
        #expect(byRepo["example-org/data-pipeline"]?.status == .skipped)       // key absent
        #expect(byRepo["example-org/legacy-batch"]?.status == .skipped)        // archived
        #expect(byRepo["example-org/infra-tools"]?.status == .skipped)         // no files
        #expect(byRepo["example-org/docs-site"]?.status == .skipped)           // no deploy/
        #expect(byRepo["example-org/flaky-service"]?.status == .failed)
    }

    @Test("marker deletion dry run plans the marked blocks, inclusive")
    func markerDeletionDryRun() async throws {
        let recipe = try #require(ResourceLocator.recipe(named: "delete_lines_between_markers"))
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

        var statusByRepo: [String: RepoStatus] = [:]
        for result in outcome.results { statusByRepo[result.id] = result.status }
        #expect(statusByRepo["example-org/api-service"] == .planned)
        #expect(statusByRepo["example-org/web-frontend"] == .planned)
        #expect(statusByRepo["example-org/data-pipeline"] == .skipped)   // no marked blocks
        #expect(statusByRepo["example-org/legacy-batch"] == .skipped)    // archived
        #expect(statusByRepo["example-org/flaky-service"] == .failed)

        let apiActions = try #require(outcome.plannedActions["example-org/api-service"])
        #expect(apiActions.count == 3)
        guard case .createBranch(let branch, _) = apiActions[0] else {
            Issue.record("expected createBranch first"); return
        }
        #expect(branch == "bulkgh/delete-marked-block")
        guard case .putContent(let path, _, _, _, let after) = apiActions[1] else {
            Issue.record("expected putContent second"); return
        }
        #expect(path == "deploy/cron.yml")
        #expect(after == """
        jobs:
          - daily_report
        """)
        guard case .createPR(_, let title, _) = apiActions[2] else {
            Issue.record("expected createPR third"); return
        }
        #expect(title == "Delete marked block")

        let webEdits = try #require(outcome.plannedActions["example-org/web-frontend"])
            .compactMap { action -> String? in
                guard case .putContent(_, _, _, _, let after) = action else { return nil }
                return after
            }
        #expect(webEdits == ["window: nightly\nnotify: ops"])
    }

    @Test("catalog prompts route through the mock LLM with params patched")
    func mockRouting() async throws {
        let yaml = try await MockLLMClient().makeScript(
            prompt: "find repos that contain \"project.json\" where the \"type\" value is \"rails\"",
            context: ScriptGenerationContext(organisation: "example-org"))
        #expect(yaml.contains("path: \"project.json\""))
        #expect(yaml.contains("key: \"type\""))
        #expect(yaml.contains("value: \"rails\""))

        let glob = try await MockLLMClient().makeScript(
            prompt: "repos where a yaml file in deploy/** has a key \"RetentionInDays\" with a value \"14\"",
            context: ScriptGenerationContext(organisation: "example-org"))
        #expect(glob.contains("glob: \"deploy/**\""))
        #expect(glob.contains("key: \"RetentionInDays\""))
        #expect(glob.contains("value: \"14\""))
        #expect(ValidationPipeline.sniffPhase(from: glob) == .check)

        let marker = try await MockLLMClient().makeScript(
            prompt: "delete the lines from a marker \"# >>>\" to the next marker \"# <<<\"",
            context: ScriptGenerationContext(organisation: "example-org", phase: .update))
        #expect(marker.contains("startMarker: \"# >>>\""))
        #expect(marker.contains("endMarker: \"# <<<\""))
        #expect(ValidationPipeline.sniffPhase(from: marker) == .update)
    }
}
