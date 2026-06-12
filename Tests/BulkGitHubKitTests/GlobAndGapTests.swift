import Foundation
import Testing
@testable import BulkGitHubKit

@Suite("Glob matching")
struct GlobMatcherTests {

    @Test("segment-local star does not cross slashes")
    func segmentStar() {
        #expect(GlobMatcher.matches("deploy/prod.yml", glob: "deploy/*.yml"))
        #expect(!GlobMatcher.matches("deploy/prod.yml", glob: "*.yml"))
        #expect(GlobMatcher.matches("a.yml", glob: "*.yml"))
        #expect(!GlobMatcher.matches("deploy/sub/prod.yml", glob: "deploy/*.yml"))
    }

    @Test("double star spans segments, including zero")
    func doubleStar() {
        #expect(GlobMatcher.matches("a.yml", glob: "**/*.yml"))
        #expect(GlobMatcher.matches("deploy/prod.yml", glob: "**/*.yml"))
        #expect(GlobMatcher.matches("a/b/c/d.yml", glob: "**/*.yml"))
        #expect(GlobMatcher.matches("src/x/y.swift", glob: "src/**"))
        #expect(!GlobMatcher.matches("src", glob: "src/**"))
        #expect(GlobMatcher.matches("a/b", glob: "a/**/b"))
        #expect(GlobMatcher.matches("a/x/y/b", glob: "a/**/b"))
        #expect(!GlobMatcher.matches("a/xb", glob: "a/**/b"))
    }

    @Test("question mark and character classes")
    func classesAndSingles() {
        #expect(GlobMatcher.matches("file.txt", glob: "file.?xt"))
        #expect(!GlobMatcher.matches("file/txt", glob: "file.?xt"))
        #expect(GlobMatcher.matches("file.txt", glob: "[fg]ile.txt"))
        #expect(GlobMatcher.matches("zile.txt", glob: "[!fg]ile.txt"))
        #expect(!GlobMatcher.matches("file.txt", glob: "[!fg]ile.txt"))
    }

    @Test("regex metacharacters in paths are literal")
    func escaping() {
        #expect(GlobMatcher.matches("a+b (1).txt", glob: "a+b (1).txt"))
        #expect(!GlobMatcher.matches("aab", glob: "a+b"))
    }
}

@Suite("listFiles host call")
struct ListFilesTests {

    @Test("lists, filters by glob, and audits")
    func listAndFilter() async {
        let outcome = await ScriptEngine().run(javaScript: """
        async function main() {
          const all = await gh.listFiles("geome/api-service");
          job.log("all=" + all.join(","));
          const yml = await gh.listFiles("geome/api-service", "**/*.yml");
          job.log("yml=" + yml.length);
          const deploy = await gh.listFiles("geome/api-service", "deploy/*.yml");
          job.log("deploy=" + deploy.join(","));
          const top = await gh.listFiles("geome/api-service", "*.yml");
          job.log("top=" + top.length);
        }
        """, phase: .check, params: [:], github: FixtureGitHubClient.demo(),
             organisation: "geome", onEvent: { _ in })

        #expect(outcome.status == .completed)
        #expect(outcome.logs.contains("all=.github/dependabot.yml,README.md,deploy/cron.yml,deploy/logging.yml,deploy/prod.yml,project.json"))
        #expect(outcome.logs.contains("yml=4"))
        #expect(outcome.logs.contains("deploy=deploy/cron.yml,deploy/logging.yml,deploy/prod.yml"))
        #expect(outcome.logs.contains("top=0"))
        #expect(outcome.auditEvents.contains {
            $0.kind == "gh.listFiles" && $0.detail.contains("3 of 6 files")
        })
    }

    @Test("listFiles type-checks against the declaration")
    func typeChecks() throws {
        let service = try #require(TypeScriptService.loadDefault())
        let source = """
        const meta = { title: "globs", phase: "check" };
        async function main(): Promise<void> {
          const paths: string[] = await gh.listFiles("geome/x", "**/*.yml");
          job.log(String(paths.length));
        }
        """
        let errors = try service.check(source: source).filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors.map(\.message))")
    }
}

@Suite("Capability gap reporting")
struct CapabilityGapTests {

    @Test("gap fence is recognised")
    func gapParsed() {
        let response = """
        ```capability-gap
        The request needs commit history (gh has no listCommits).
        Closest achievable: check current file contents only.
        ```
        """
        guard case .capabilityGap(let report) = PromptLibrary.parseGeneration(from: response) else {
            Issue.record("expected capabilityGap")
            return
        }
        #expect(report.contains("listCommits"))
    }

    @Test("script fence still parses as a script")
    func scriptParsed() {
        let response = """
        ```typescript
        const meta = { title: "x", phase: "check" };
        ```
        """
        guard case .script(let script) = PromptLibrary.parseGeneration(from: response) else {
            Issue.record("expected script")
            return
        }
        #expect(script.hasPrefix("const meta"))
    }

    @Test("house rules instruct gap reporting, and the prompt carries the format")
    func promptMentionsGap() {
        #expect(PromptLibrary.houseRules.contains("capability"))
        let system = PromptLibrary.systemPrompt(apiDeclaration: "declare const gh: unknown;",
                                                organisation: "geome")
        #expect(system.contains("```capability-gap"))
    }
}
