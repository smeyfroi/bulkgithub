import Foundation
import Testing
@testable import BulkGitHubKit

/// Repository custom properties: the authoritative bulk-read query backbone,
/// the values-only write under the dry-run → arm pipeline, and the guardrails
/// (allowed-values, property-defined, idempotent resume, drift). Exercised
/// entirely against fixtures.
@Suite("Custom properties — client and codec")
struct PropertyClientTests {

    @Test("value codec decodes string, list, and null/absent")
    func valueDecoding() {
        #expect(LiveGitHubClient.propertyValue(from: "rails") == .string("rails"))
        #expect(LiveGitHubClient.propertyValue(from: ["a", "b"]) == .list(["a", "b"]))
        #expect(LiveGitHubClient.propertyValue(from: NSNull()) == .null)
        #expect(LiveGitHubClient.propertyValue(from: nil) == .null)
    }

    @Test("value codec round-trips to the PATCH JSON shape")
    func valueEncoding() {
        #expect(LiveGitHubClient.propertyJSON(.string("rails")) as? String == "rails")
        #expect(LiveGitHubClient.propertyJSON(.list(["a"])) as? [String] == ["a"])
        #expect(LiveGitHubClient.propertyJSON(.null) is NSNull)
    }

    @Test("fixture setProperties writes, getProperties reads, null clears")
    func fixtureRoundTrip() async throws {
        let client = FixtureGitHubClient.demo()
        let repo = "example-org/api-service"
        try await client.setProperties(repo: repo, values: ["Tier": .string("gold")])
        var props = try await client.getProperties(repo: repo)
        #expect(props["Tier"] == .string("gold"))
        #expect(props["ProjectType"] == .string("rails"))   // untouched

        try await client.setProperties(repo: repo, values: ["Tier": .null])
        props = try await client.getProperties(repo: repo)
        #expect(props["Tier"] == nil)                        // cleared
    }

    @Test("listOrgProperties returns every repo with its values")
    func bulkRead() async throws {
        let all = try await FixtureGitHubClient.demo().listOrgProperties(org: "example-org")
        let byRepo = Dictionary(uniqueKeysWithValues: all.map { ($0.repo.fullName, $0.properties) })
        #expect(byRepo["example-org/api-service"]?["ProjectType"] == .string("rails"))
        #expect(byRepo["example-org/data-pipeline"]?["ProjectType"] == .string("rails"))
        #expect(byRepo["example-org/web-frontend"]?["ProjectType"] == nil)   // unset
    }
}

@Suite("Custom properties — query (check phase)")
struct PropertyQueryTests {

    @Test("find-by-property matches via the authoritative bulk read, no code search")
    func findByProperty() async throws {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let recipe = try #require(ResourceLocator.recipe(named: "find_repos_by_property"))
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.meta.phase == .check)

        let client = FixtureGitHubClient.demo()
        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: .check,
                                               params: validated.meta.params,
                                               github: client,
                                               organisation: "example-org",
                                               onEvent: { _ in })
        #expect(outcome.status == .completed)

        let matched = Set(outcome.results.filter { $0.status == .verifiedMatch }.map(\.id))
        #expect(matched == ["example-org/api-service", "example-org/data-pipeline"])

        let web = outcome.results.first { $0.id == "example-org/web-frontend" }
        #expect(web?.status == .skipped)
        #expect(web?.reason?.contains("unset") == true)   // ProjectType not set on web

        // Authoritative read only — no search index, no per-file fetch.
        #expect(client.callLog.contains { $0.hasPrefix("listOrgProperties") })
        #expect(!client.callLog.contains { $0.hasPrefix("searchCode") })
        #expect(!client.callLog.contains { $0.hasPrefix("getContent") })
    }

    @Test("reportMatch accepts a property-based match (property receipt, no file fetch)")
    func propertyReceiptAllowsMatch() async throws {
        let outcome = await ScriptEngine().run(javaScript: """
        async function main() {
          const all = await gh.listOrgProperties();
          const hit = all.find(e => e.properties.ProjectType === "rails");
          job.reportMatch(hit.repo, { path: "custom property: ProjectType", excerpt: "ProjectType = rails" });
        }
        """, phase: .check, params: [:], github: FixtureGitHubClient.demo(),
             organisation: "example-org", onEvent: { _ in })
        #expect(outcome.status == .completed)
        #expect(outcome.results.contains { $0.status == .verifiedMatch })
    }

    @Test("reportMatch still refuses a match with no authoritative read behind it")
    func noReceiptRefusesMatch() async throws {
        let outcome = await ScriptEngine().run(javaScript: """
        async function main() {
          const repos = await gh.listOrgRepos();
          try {
            job.reportMatch(repos[0], { path: "x", excerpt: "y" });
            job.log("no-throw");
          } catch (e) {
            job.log("threw: " + String(e));
          }
        }
        """, phase: .check, params: [:], github: FixtureGitHubClient.demo(),
             organisation: "example-org", onEvent: { _ in })
        #expect(outcome.status == .completed)
        #expect(outcome.logs.contains { $0.hasPrefix("threw:") && $0.contains("authoritative read") })
        #expect(!outcome.results.contains { $0.status == .verifiedMatch })
    }
}

@Suite("Custom properties — write (dry run)")
struct PropertyDryRunTests {

    @Test("set-from-JSON plans the unset repo, skips those already at target")
    func setFromJsonDryRun() async throws {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let recipe = try #require(ResourceLocator.recipe(named: "set_property_from_json"))
        let validated = try pipeline.validate(source: recipe)
        #expect(validated.meta.phase == .update)

        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: .update,
                                               params: validated.meta.params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "example-org",
                                               onEvent: { _ in })
        #expect(outcome.status == .completed)

        // web-frontend's project.json is react and its ProjectType is unset →
        // exactly one planned property write, with a (unset) → react diff.
        #expect(Array(outcome.plannedActions.keys) == ["example-org/web-frontend"])
        let actions = try #require(outcome.plannedActions["example-org/web-frontend"])
        #expect(actions.count == 1)
        guard case .setProperties(let values, let before) = actions[0] else {
            Issue.record("expected a setProperties action"); return
        }
        #expect(values == ["ProjectType": .string("react")])
        #expect(before == ["ProjectType": .null])

        var statusByRepo: [String: RepoResult] = [:]
        for result in outcome.results { statusByRepo[result.id] = result }
        #expect(statusByRepo["example-org/web-frontend"]?.status == .planned)
        // Already-at-target repos are skipped by the recipe's idempotency check.
        #expect(statusByRepo["example-org/api-service"]?.status == .skipped)
        #expect(statusByRepo["example-org/api-service"]?.reason?.contains("already rails") == true)
        #expect(statusByRepo["example-org/data-pipeline"]?.status == .skipped)

        let plan = outcome.auditEvents.filter { $0.kind == "plan.setProperties" }
        #expect(plan.contains { $0.detail.contains("dry-run") })
    }

    @Test("dry run records the property write but never executes it — the remote is untouched")
    func dryRunWritesNothing() async throws {
        let client = FixtureGitHubClient.demo()
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let recipe = try #require(ResourceLocator.recipe(named: "set_property_from_json"))
        let validated = try pipeline.validate(source: recipe)
        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: .update,
                                               params: validated.meta.params,
                                               github: client,
                                               organisation: "example-org",
                                               onEvent: { _ in })
        #expect(outcome.status == .completed)
        // Reads are the SCRIPT's own (listOrgRepos, getContent, getProperties, and
        // its explicit listPropertyDefs); the recording handle makes none. The
        // write is only recorded: setProperties never reaches the client, so the
        // remote value stays unset.
        #expect(!client.callLog.contains { $0.hasPrefix("setProperties") })
        #expect(outcome.plannedActions["example-org/web-frontend"]?.isEmpty == false)
        #expect(try await client.getProperties(repo: "example-org/web-frontend")["ProjectType"] == nil)
    }

    @Test("allowed-values are validated at dry run when the script has read the schema")
    func allowedValuesRejected() async throws {
        let outcome = await ScriptEngine().run(javaScript: """
        async function main() {
          await gh.listPropertyDefs();   // caches the schema, so the dry run can validate
          await gh.setProperties("example-org/api-service", { ProjectType: "cobol" });
        }
        """, phase: .update, params: [:], github: FixtureGitHubClient.demo(),
             organisation: "example-org", onEvent: { _ in })
        #expect(outcome.status == .completed)
        #expect(outcome.plannedActions.isEmpty)            // nothing planned
        let api = outcome.results.first { $0.id == "example-org/api-service" }
        #expect(api?.status == .failed)
        #expect(api?.reason?.contains("not an allowed value") == true)
    }

    @Test("an undefined property is rejected (v1 sets values only)")
    func undefinedPropertyRejected() async throws {
        let outcome = await ScriptEngine().run(javaScript: """
        async function main() {
          await gh.listPropertyDefs();
          await gh.setProperties("example-org/api-service", { Nonexistent: "x" });
        }
        """, phase: .update, params: [:], github: FixtureGitHubClient.demo(),
             organisation: "example-org", onEvent: { _ in })
        #expect(outcome.plannedActions.isEmpty)
        let api = outcome.results.first { $0.id == "example-org/api-service" }
        #expect(api?.status == .failed)
        #expect(api?.reason?.contains("not defined") == true)
    }
}

@Suite("Custom properties — phase gating")
struct PropertyGatingTests {

    @Test("setProperties type-checks only for update scripts; reads type-check anywhere")
    func phaseGatedTypes() throws {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())

        let write = "async function main(): Promise<void> { await gh.setProperties(\"o/n\", { X: \"y\" }); }"
        #expect(throws: ValidationError.self) {
            try pipeline.validate(source: "const meta = { title: \"t\", phase: \"check\" };\n" + write)
        }
        let updateOK = try pipeline.validate(source: "const meta = { title: \"t\", phase: \"update\" };\n" + write)
        #expect(updateOK.diagnostics.filter { $0.severity == .error }.isEmpty)

        // The read surface is available to check scripts.
        let read = """
        const meta = { title: "t", phase: "check" };
        async function main(): Promise<void> {
          const all = await gh.listOrgProperties();
          const one = await gh.getProperties(all[0].repo);
          const defs = await gh.listPropertyDefs();
          job.log(String(one) + defs.length);
        }
        """
        let readOK = try pipeline.validate(source: read)
        #expect(readOK.diagnostics.filter { $0.severity == .error }.isEmpty)
    }

    @Test("the property write is absent at runtime in check phase; reads are present")
    func runtimeGating() async {
        let outcome = await ScriptEngine().run(javaScript: """
        async function main() {
          job.log("set=" + typeof gh.setProperties
                + " get=" + typeof gh.getProperties
                + " list=" + typeof gh.listOrgProperties);
        }
        """, phase: .check, params: [:], github: FixtureGitHubClient.demo(),
             organisation: "example-org", onEvent: { _ in })
        #expect(outcome.logs.contains("set=undefined get=function list=function"))
    }
}

@Suite("Custom properties — offline mock generation")
struct PropertyMockTests {

    @Test("the query prompt generates the find-by-property recipe with params patched")
    func mockQueryRouting() async throws {
        let script = try await MockLLMClient().makeScript(
            prompt: "find repos where the custom property \"Tier\" is set to \"gold\"",
            context: ScriptGenerationContext(organisation: "example-org", phase: .check))
        #expect(ValidationPipeline.sniffPhase(from: script) == .check)
        #expect(script.contains("listOrgProperties"))     // unique to this recipe
        #expect(script.contains("property: \"Tier\""))     // patched from the prompt
        #expect(script.contains("value: \"gold\""))
    }

    @Test("the set prompt generates the set-from-JSON recipe with params patched")
    func mockSetRouting() async throws {
        let script = try await MockLLMClient().makeScript(
            prompt: "for all repos that contain package.json, set the custom property \"Stack\" to the value of the \"kind\" key",
            context: ScriptGenerationContext(organisation: "example-org", phase: .update))
        #expect(ValidationPipeline.sniffPhase(from: script) == .update)
        #expect(script.contains("setProperties"))          // unique to this recipe
        #expect(script.contains("file: \"package.json\""))
        #expect(script.contains("property: \"Stack\""))
        #expect(script.contains("jsonKey: \"kind\""))
    }
}

@Suite("Custom properties — armed writes")
struct PropertyArmedTests {

    private func armed(targets: Set<String>, plan: [String: [PlannedAction]]) -> EngineConfiguration {
        var configuration = EngineConfiguration()
        configuration.writeMode = .armed
        configuration.targetRepos = targets
        configuration.referencePlan = plan
        return configuration
    }

    @Test("armed apply sets the property on the remote — terminal, no branch/PR")
    func armedApply() async throws {
        let client = FixtureGitHubClient.demo()
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let recipe = try #require(ResourceLocator.recipe(named: "set_property_from_json"))
        let validated = try pipeline.validate(source: recipe)

        let dryRun = await ScriptEngine().run(javaScript: validated.javaScript, phase: .update,
                                              params: validated.meta.params, github: client,
                                              organisation: "example-org", onEvent: { _ in })
        let plan = dryRun.plannedActions
        #expect(Array(plan.keys) == ["example-org/web-frontend"])

        let run = await ScriptEngine().run(javaScript: validated.javaScript, phase: .update,
                                           params: validated.meta.params, github: client,
                                           organisation: "example-org",
                                           configuration: armed(targets: ["example-org/web-frontend"], plan: plan),
                                           onEvent: { _ in })
        #expect(run.status == .completed)
        #expect(run.artifacts.isEmpty)   // metadata write — nothing to merge or cancel

        let web = run.results.first { $0.id == "example-org/web-frontend" }
        #expect(web?.status == .updated)
        #expect(try await client.getProperties(repo: "example-org/web-frontend")["ProjectType"] == .string("react"))
        let writes = run.auditEvents.filter { $0.kind == "write.setProperties" }
        #expect(writes.contains { $0.detail.contains("ARMED") })
    }

    @Test("idempotent resume: already at target writes nothing")
    func idempotentResume() async throws {
        let client = FixtureGitHubClient.demo()   // api-service already ProjectType=rails
        let plan = ["example-org/api-service":
            [PlannedAction.setProperties(values: ["ProjectType": .string("rails")],
                                         before: ["ProjectType": .string("rails")])]]
        let run = await ScriptEngine().run(javaScript: """
        async function main() { await gh.setProperties("example-org/api-service", { ProjectType: "rails" }); }
        """, phase: .update, params: [:], github: client, organisation: "example-org",
             configuration: armed(targets: ["example-org/api-service"], plan: plan), onEvent: { _ in })
        #expect(run.status == .completed)
        let api = run.results.first { $0.id == "example-org/api-service" }
        #expect(api?.status == .alreadyUpToDate)
        #expect(run.auditEvents.contains { $0.kind == "write.setProperties" && $0.detail.contains("already at target") })
    }

    @Test("drift guard: a value changed since the dry run halts with nothing written")
    func driftGuard() async throws {
        let client = FixtureGitHubClient.demo()
        // Reviewed plan: api-service rails → react (before captured as rails).
        let plan = ["example-org/api-service":
            [PlannedAction.setProperties(values: ["ProjectType": .string("react")],
                                         before: ["ProjectType": .string("rails")])]]
        // The remote moves between review and apply.
        try await client.setProperties(repo: "example-org/api-service", values: ["ProjectType": .string("go")])

        let run = await ScriptEngine().run(javaScript: """
        async function main() {
          try { await gh.setProperties("example-org/api-service", { ProjectType: "react" }); }
          catch (e) { job.log(String(e)); }   // per-repo isolation, as real recipes do
        }
        """, phase: .update, params: [:], github: client, organisation: "example-org",
             configuration: armed(targets: ["example-org/api-service"], plan: plan), onEvent: { _ in })
        #expect(run.status == .completed)
        let api = run.results.first { $0.id == "example-org/api-service" }
        #expect(api?.status == .conflicted)
        #expect(api?.reason?.contains("changed on the remote") == true)
        // Untouched: the drifted value stands, the review's target was not forced.
        #expect(try await client.getProperties(repo: "example-org/api-service")["ProjectType"] == .string("go"))
    }

    @Test("armed run enforces allowed-values even if the script never read the schema")
    func armedAllowedValues() async throws {
        let client = FixtureGitHubClient.demo()
        // A reviewed plan that slipped through with a disallowed value; the armed
        // run fetches the schema itself (a write-path read) and refuses it.
        let plan = ["example-org/web-frontend":
            [PlannedAction.setProperties(values: ["ProjectType": .string("cobol")],
                                         before: ["ProjectType": .null])]]
        let run = await ScriptEngine().run(javaScript: """
        async function main() {
          try { await gh.setProperties("example-org/web-frontend", { ProjectType: "cobol" }); }
          catch (e) { job.log(String(e)); }
        }
        """, phase: .update, params: [:], github: client, organisation: "example-org",
             configuration: armed(targets: ["example-org/web-frontend"], plan: plan), onEvent: { _ in })
        #expect(run.status == .completed)
        let web = run.results.first { $0.id == "example-org/web-frontend" }
        #expect(web?.status == .failed)
        #expect(web?.reason?.contains("not an allowed value") == true)
        #expect(try await client.getProperties(repo: "example-org/web-frontend")["ProjectType"] == nil)
    }

    @Test("plan conformance: a target the script didn't review halts as conflicted")
    func planConformance() async throws {
        let client = FixtureGitHubClient.demo()
        // Reviewed plan says set react; the script tries to set python.
        let plan = ["example-org/web-frontend":
            [PlannedAction.setProperties(values: ["ProjectType": .string("react")],
                                         before: ["ProjectType": .null])]]
        let run = await ScriptEngine().run(javaScript: """
        async function main() {
          try { await gh.setProperties("example-org/web-frontend", { ProjectType: "python" }); }
          catch (e) { job.log(String(e)); }   // per-repo isolation, as real recipes do
        }
        """, phase: .update, params: [:], github: client, organisation: "example-org",
             configuration: armed(targets: ["example-org/web-frontend"], plan: plan), onEvent: { _ in })
        #expect(run.status == .completed)
        let web = run.results.first { $0.id == "example-org/web-frontend" }
        #expect(web?.status == .conflicted)
        #expect(try await client.getProperties(repo: "example-org/web-frontend")["ProjectType"] == nil)
    }
}
