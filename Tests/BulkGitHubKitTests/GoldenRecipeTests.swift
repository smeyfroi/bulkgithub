import Foundation
import Testing
@testable import BulkGitHubKit

/// The full product loop on fixtures: validate the golden recipe (lint +
/// type-check + transpile + meta), run it through the engine with a read-only
/// handle, and assert the exact per-repo outcomes the demo dataset encodes.
@Suite("Golden recipe end-to-end")
struct GoldenRecipeTests {

    @Test("check run produces the expected per-repo statuses")
    func endToEnd() async throws {
        let recipe = try #require(ResourceLocator.goldenRecipe)
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.diagnostics.filter { $0.severity == .error }.isEmpty)

        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: validated.meta.phase,
                                               params: validated.meta.params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "geome",
                                               onEvent: { _ in })

        #expect(outcome.status == .completed)

        var statusByRepo: [String: RepoStatus] = [:]
        for result in outcome.results { statusByRepo[result.id] = result.status }

        #expect(statusByRepo["geome/api-service"] == .verifiedMatch)
        #expect(statusByRepo["geome/data-pipeline"] == .verifiedMatch)
        #expect(statusByRepo["geome/web-frontend"] == .skipped)
        #expect(statusByRepo["geome/legacy-batch"] == .skipped)   // archived
        #expect(statusByRepo["geome/infra-tools"] == .skipped)    // stale search hit
        #expect(statusByRepo["geome/flaky-service"] == .failed)
        #expect(statusByRepo["geome/docs-site"] == nil)           // never a candidate

        let match = outcome.results.first { $0.id == "geome/api-service" }
        #expect(match?.evidence.first?.path == "deploy/prod.yml")
        #expect(match?.evidence.first?.explanation?.contains("account_id") == true)

        let skipReason = outcome.results.first { $0.id == "geome/web-frontend" }?.reason
        #expect(skipReason?.contains("differs") == true)

        // Audit trail covers the effectful host calls, including the failed
        // fetch against the flaky repo.
        #expect(outcome.auditEvents.contains { $0.kind == "gh.searchCode" })
        let fetches = outcome.auditEvents.filter { $0.kind == "gh.getContent" }
        #expect(fetches.count == 5)
        #expect(fetches.contains { $0.repo == "geome/flaky-service" && $0.detail.contains("failed") })
        #expect(outcome.auditEvents.filter { $0.kind == "job.reportMatch" }.count == 2)
    }

    @Test("edited params change behaviour without regeneration")
    func paramOverride() async throws {
        let recipe = try #require(ResourceLocator.goldenRecipe)
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: recipe)

        var params = validated.meta.params
        params["value"] = "999911112222"   // web-frontend's value in the fixtures

        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: validated.meta.phase,
                                               params: params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "geome",
                                               onEvent: { _ in })

        var statusByRepo: [String: RepoStatus] = [:]
        for result in outcome.results { statusByRepo[result.id] = result.status }
        #expect(statusByRepo["geome/web-frontend"] == .verifiedMatch)
        #expect(statusByRepo["geome/api-service"] == .skipped)
    }
}

/// The keypair worked example (plan v2 → update phases): the check half,
/// driven from the user's natural-language prompt through the mock LLM, the
/// validation pipeline, and the engine.
@Suite("Keypair recipe end-to-end")
struct KeypairRecipeTests {

    static let prompt = "repos where a file in deploy/ contains the string `ec2-shell-prod-eu-west-1-keypair-1`"

    @Test("prompt routes through the mock to a validated string-scan script")
    func promptToScript() async throws {
        let script = try await MockLLMClient().makeScript(
            prompt: Self.prompt,
            context: ScriptGenerationContext(organisation: "geome"))
        #expect(script.contains("needle: \"ec2-shell-prod-eu-west-1-keypair-1\""))
        #expect(script.contains("glob: \"deploy/**\""))

        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let validated = try pipeline.validate(source: script)
        #expect(validated.meta.params["needle"] == "ec2-shell-prod-eu-west-1-keypair-1")
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
                                               organisation: "geome",
                                               onEvent: { _ in })

        #expect(outcome.status == .completed)

        var byRepo: [String: RepoResult] = [:]
        for result in outcome.results { byRepo[result.id] = result }

        // YAML occurrence
        #expect(byRepo["geome/data-pipeline"]?.status == .verifiedMatch)
        #expect(byRepo["geome/data-pipeline"]?.evidence.first?.path == "deploy/keys.yml")
        // JSON occurrence, key-value pair last in its object (the future
        // trailing-comma deletion case)
        #expect(byRepo["geome/web-frontend"]?.status == .verifiedMatch)
        #expect(byRepo["geome/web-frontend"]?.evidence.first?.path == "deploy/infra.json")
        #expect(byRepo["geome/web-frontend"]?.evidence.first?.explanation?.contains("keyPair") == true)

        #expect(byRepo["geome/api-service"]?.status == .skipped)       // deploy files, no needle
        #expect(byRepo["geome/legacy-batch"]?.status == .skipped)      // archived
        #expect(byRepo["geome/infra-tools"]?.status == .skipped)       // nothing matches the glob
        #expect(byRepo["geome/docs-site"]?.status == .skipped)         // nothing matches the glob
        #expect(byRepo["geome/flaky-service"]?.status == .failed)

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
        settings.organisation = "geome"
        settings.maxConcurrentOps = 3
        var job = Job(prompt: "find things")
        job.scriptSource = "async function main() {}"
        job.params = ["path": "x.yml"]
        job.results = [RepoResult(repo: RepoRef(fullName: "geome/a"), status: .verifiedMatch,
                                  reason: "ok", evidence: [Evidence(path: "x.yml", excerpt: "k: v")])]
        job.auditEvents = [AuditEvent(kind: "gh.getContent", repo: "geome/a", detail: "x.yml")]

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
            context: ScriptGenerationContext(organisation: "geome"))
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
