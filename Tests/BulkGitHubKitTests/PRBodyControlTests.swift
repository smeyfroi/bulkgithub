import Foundation
import Testing
@testable import BulkGitHubKit

/// #7: the user's PR title/body (EngineConfiguration.prTitleOverride/prBodyOverride)
/// are host-authoritative — they drive every created PR regardless of what the
/// generated script passes to gh.createPR, in both the dry-run plan and the
/// armed run (so the recorded plan and armed conformance agree).
@Suite("PR body control — host-authoritative createPR")
struct PRBodyControlTests {
    private let state = ["stringMatches": """
    [{"repo":"example-org/web-frontend","defaultBranch":"main","paths":["deploy/infra.json"]},\
    {"repo":"example-org/data-pipeline","defaultBranch":"master","paths":["deploy/keys.yml"]}]
    """]

    @Test("the override drives the recorded plan and the created PR, over the script's values")
    func overrideWins() async throws {
        let client = FixtureGitHubClient.demo()
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let recipe = try #require(ResourceLocator.recipe(named: "remove_line_with_string"))
        let validated = try pipeline.validate(source: recipe)

        var config = EngineConfiguration()
        config.prTitleOverride = "HOST TITLE"
        config.prBodyOverride = "HOST BODY"

        // Dry run: the recorded createPR carries the override, not the recipe's.
        let dry = await ScriptEngine().run(javaScript: validated.javaScript, phase: .update,
                                           params: validated.meta.params, github: client,
                                           organisation: "example-org", configuration: config,
                                           initialState: state, onEvent: { _ in })
        #expect(dry.status == .completed)
        let createPRs = dry.plannedActions.values.flatMap { $0 }.compactMap { action -> (String, String)? in
            if case .createPR(_, let title, let body) = action { return (title, body) }
            return nil
        }
        #expect(!createPRs.isEmpty)
        #expect(createPRs.allSatisfy { $0.0 == "HOST TITLE" && $0.1 == "HOST BODY" })

        // Armed: conformance holds (plan built with the same override) and the
        // created PR's body is the host value.
        var armed = config
        armed.writeMode = .armed
        armed.targetRepos = ["example-org/web-frontend", "example-org/data-pipeline"]
        armed.referencePlan = dry.plannedActions
        let applied = await ScriptEngine().run(javaScript: validated.javaScript, phase: .update,
                                               params: validated.meta.params, github: client,
                                               organisation: "example-org", configuration: armed,
                                               initialState: state, onEvent: { _ in })
        #expect(applied.status == .completed)
        #expect(!client.createdPRs.isEmpty)
        #expect(client.createdPRs.allSatisfy { $0.body == "HOST BODY" })
    }
}
