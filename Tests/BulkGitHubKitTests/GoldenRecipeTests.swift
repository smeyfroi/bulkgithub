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
