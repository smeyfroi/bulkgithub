import Foundation
import Testing
@testable import BulkGitHubKit

@Suite("Validation pipeline and tsc-in-JSC spike", .serialized)
struct ValidationTests {

    static let service = TypeScriptService.loadDefault()

    @Test("TypeScript compiler loads inside JavaScriptCore")
    func compilerLoads() throws {
        let service = try #require(Self.service, "TypeScript resources missing from bundle")
        // Force a first check to boot the compiler context and report timing.
        let clock = ContinuousClock()
        let boot = clock.measure {
            _ = try? service.check(source: "const x: number = 1;")
        }
        print("tsc-in-JSC first check (incl. compiler boot): \(boot)")
        let warm = clock.measure {
            _ = try? service.check(source: "const y: string = \"hi\";")
        }
        print("tsc-in-JSC warm check: \(warm)")
        #expect(service.compilerVersion?.hasPrefix("6.") == true
                || service.compilerVersion?.hasPrefix("5.") == true)
    }

    @Test("golden recipe type-checks clean against bulkgh.d.ts")
    func goldenRecipeChecks() throws {
        let service = try #require(Self.service)
        let recipe = try #require(ResourceLocator.goldenRecipe)
        let diagnostics = try service.check(source: recipe)
        let errors = diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty, "unexpected type errors: \(errors.map(\.message))")
    }

    @Test("hallucinated host API calls are caught before execution")
    func hallucinatedCall() throws {
        let service = try #require(Self.service)
        let source = """
        const meta = { title: "x", phase: "check" };
        async function main(): Promise<void> {
          const repos = await gh.searchRepositories("query");
          job.markMatched(repos[0]);
        }
        """
        let diagnostics = try service.check(source: source)
        let errors = diagnostics.filter { $0.severity == .error }
        #expect(errors.count >= 2)
        #expect(errors.contains { $0.message.contains("searchRepositories") })
        #expect(errors.contains { $0.message.contains("markMatched") })
    }

    @Test("browser/node globals do not exist in the script world")
    func noAmbientGlobals() throws {
        let service = try #require(Self.service)
        for forbidden in ["fetch(\"https://x\")", "process.exit(1)", "require(\"fs\")"] {
            let source = """
            const meta = { title: "x", phase: "check" };
            async function main(): Promise<void> { \(forbidden); }
            """
            let diagnostics = try service.check(source: source)
            #expect(diagnostics.contains { $0.severity == .error },
                    "expected a type error for: \(forbidden)")
        }
    }

    @Test("transpiled recipe runs against fixtures end to end")
    func transpileAndRun() async throws {
        let service = try #require(Self.service)
        let recipe = try #require(ResourceLocator.recipe(named: "find_yaml_key_value"))
        let js = try service.transpile(source: recipe)
        #expect(!js.contains(": Promise<void>"), "types should be stripped")

        let meta = try ValidationPipeline.extractMeta(fromJavaScript: js)
        #expect(meta.title.contains("YAML"))
        #expect(meta.phase == .check)
        #expect(meta.params["path"] == "deploy/prod.yml")

        let outcome = await ScriptEngine().run(javaScript: js,
                                               phase: meta.phase,
                                               params: meta.params,
                                               github: FixtureGitHubClient.demo(),
                                               organisation: "geome",
                                               onEvent: { _ in })
        #expect(outcome.status == .completed)
    }

    @Test("pipeline rejects lint violations before type-checking")
    func lintGate() throws {
        let pipeline = ValidationPipeline(typescript: Self.service)
        let source = """
        const meta = { title: "x", phase: "check" };
        async function main(): Promise<void> { eval("1+1"); }
        """
        #expect(throws: ValidationError.self) {
            try pipeline.validate(source: source)
        }
    }

    @Test("meta extraction validates the script contract")
    func metaContract() throws {
        #expect(throws: ValidationError.self) {
            _ = try ValidationPipeline.extractMeta(fromJavaScript: "const meta = { title: \"x\" };")
        }
        #expect(throws: ValidationError.self) {
            _ = try ValidationPipeline.extractMeta(
                fromJavaScript: "const meta = { phase: \"deploy\" }; function main() {}")
        }
        let meta = try ValidationPipeline.extractMeta(fromJavaScript: """
        const meta = { title: "t", phase: "check", params: { n: 42, flag: true, s: "x" } };
        async function main() {}
        """)
        #expect(meta.params == ["n": "42", "flag": "true", "s": "x"])
    }
}

@Suite("Script linter")
struct LinterTests {

    @Test("forbidden constructs are flagged with line numbers")
    func forbidden() {
        let source = """
        const meta = { title: "x", phase: "check" };
        import fs from "fs";
        async function main() {
          eval("danger");
          const f = new Function("return 1");
          const m = require("module");
        }
        """
        let diagnostics = ScriptLinter.lint(source)
        #expect(diagnostics.count == 4)
        #expect(diagnostics.contains { $0.message.contains("modules") && $0.line == 2 })
        #expect(diagnostics.contains { $0.message.contains("eval") && $0.line == 4 })
        #expect(diagnostics.contains { $0.message.contains("Function constructor") && $0.line == 5 })
        #expect(diagnostics.contains { $0.message.contains("require") && $0.line == 6 })
    }

    @Test("clean scripts pass")
    func clean() throws {
        let recipe = try #require(ResourceLocator.goldenRecipe)
        #expect(ScriptLinter.lint(recipe).isEmpty)
    }
}
