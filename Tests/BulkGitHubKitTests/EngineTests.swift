import Foundation
import Testing
@testable import BulkGitHubKit

@Suite("Script engine")
struct EngineTests {

    private func run(_ js: String,
                     params: [String: String] = [:],
                     client: FixtureGitHubClient = .demo(),
                     configuration: EngineConfiguration = EngineConfiguration()) async -> RunOutcome {
        await ScriptEngine().run(javaScript: js,
                                 phase: .check,
                                 params: params,
                                 github: client,
                                 organisation: "example-org",
                                 configuration: configuration,
                                 onEvent: { _ in })
    }

    @Test("listOrgRepos registers candidates; unreported ones finalize to no-match")
    func listRepos() async {
        let outcome = await run("""
        async function main() {
          const repos = await gh.listOrgRepos();
          job.log("count=" + repos.length);
        }
        """)
        #expect(outcome.status == .completed)
        #expect(outcome.logs.contains("count=7"))
        #expect(outcome.results.count == 7)
        // "candidate" is a mid-run state. A completed run resolves every
        // enumerated-but-unreported repo to "no match" so the final table
        // doesn't read as if all org repos matched.
        #expect(outcome.results.allSatisfy { $0.status == .noMatch })
        #expect(outcome.results.allSatisfy { $0.reason == "nothing reported" })
    }

    @Test("finalize leaves reported repos alone; reportMatch captures context")
    func finalizeAndEvidenceContext() async {
        let outcome = await run("""
        async function main() {
          await gh.listOrgRepos();
          await gh.getContent("example-org/web-frontend", "deploy/infra.json");
          job.reportMatch("example-org/web-frontend", {
            path: "deploy/infra.json",
            excerpt: "\\"deployKey\\": \\"legacy-deploy-key-2019\\"",
          });
          job.skip("example-org/api-service", "ruled out");
        }
        """)
        #expect(outcome.status == .completed)
        var byRepo: [String: RepoResult] = [:]
        for result in outcome.results { byRepo[result.id] = result }
        #expect(byRepo["example-org/web-frontend"]?.status == .verifiedMatch)
        #expect(byRepo["example-org/api-service"]?.status == .skipped)
        #expect(byRepo["example-org/data-pipeline"]?.status == .noMatch)

        // The host pulls surrounding lines from the receipt-cached content so
        // the review pane can show the match in situ.
        let evidence = byRepo["example-org/web-frontend"]?.evidence.first
        #expect(evidence?.context?.contains("\"region\": \"eu-west-1\",") == true)
        #expect(evidence?.contextStartLine == 1)
    }

    @Test("getRepo resolves authoritative metadata without creating a result row")
    func getRepoLookup() async {
        let outcome = await run("""
        async function main() {
          const repo = await gh.getRepo("example-org/data-pipeline");
          job.log("branch=" + repo.defaultBranch);
          try {
            await gh.getRepo("example-org/no-such-repo");
          } catch (e) {
            job.log("threw: " + String(e));
          }
        }
        """)
        #expect(outcome.status == .completed)
        // The fixture's data-pipeline defaults to master — the case that
        // breaks scripts which hardcode heads/main.
        #expect(outcome.logs.contains("branch=master"))
        #expect(outcome.logs.contains { $0.hasPrefix("threw:") && $0.contains("no-such-repo") })
        #expect(outcome.results.isEmpty)
        #expect(outcome.auditEvents.contains { $0.kind == "gh.getRepo" })
    }

    @Test("contextSnippet centres on the excerpt and reports its start line")
    func contextSnippetHelper() {
        let content = (1...10).map { "line\($0)" }.joined(separator: "\n")
        let snippet = HostBindings.contextSnippet(around: "line6", in: content, radius: 2)
        #expect(snippet?.startLine == 4)
        #expect(snippet?.text == "line4\nline5\nline6\nline7\nline8")
        #expect(HostBindings.contextSnippet(around: "absent", in: content) == nil)
    }

    @Test("write surface does not exist on the check-phase handle")
    func noWriteSurface() async {
        let outcome = await run("""
        async function main() {
          job.log("createBranch=" + typeof gh.createBranch);
          job.log("putContent=" + typeof gh.putContent);
          job.log("mergePR=" + typeof gh.mergePR);
        }
        """)
        #expect(outcome.status == .completed)
        #expect(outcome.logs.contains("createBranch=undefined"))
        #expect(outcome.logs.contains("putContent=undefined"))
        #expect(outcome.logs.contains("mergePR=undefined"))
    }

    @Test("reportMatch without a content-fetch receipt throws")
    func receiptEnforcement() async {
        let outcome = await run("""
        async function main() {
          try {
            job.reportMatch("example-org/api-service", { path: "deploy/prod.yml", excerpt: "x" });
            job.log("no-throw");
          } catch (e) {
            job.log("threw: " + String(e));
          }
        }
        """)
        #expect(outcome.status == .completed)
        #expect(outcome.logs.contains { $0.hasPrefix("threw:") && $0.contains("candidates, not proof") })
        #expect(!outcome.logs.contains("no-throw"))
        #expect(outcome.results.filter { $0.status == .verifiedMatch }.isEmpty)
    }

    @Test("reportMatch succeeds after fetching the evidence path")
    func receiptSatisfied() async {
        let outcome = await run("""
        async function main() {
          const text = await gh.getContent("example-org/api-service", "deploy/prod.yml");
          job.reportMatch("example-org/api-service", { path: "deploy/prod.yml", excerpt: text, explanation: "ok" });
        }
        """)
        #expect(outcome.status == .completed)
        let matches = outcome.results.filter { $0.status == .verifiedMatch }
        #expect(matches.count == 1)
        #expect(matches.first?.evidence.first?.explanation == "ok")
    }

    @Test("per-repo failures isolate; the run completes")
    func errorIsolation() async {
        let outcome = await run("""
        async function main() {
          const repos = ["example-org/flaky-service", "example-org/api-service"];
          for (const repo of repos) {
            try {
              const text = await gh.getContent(repo, "deploy/prod.yml");
              job.log(repo + " ok " + (text !== null));
            } catch (e) {
              job.error(repo, String(e));
            }
          }
        }
        """)
        #expect(outcome.status == .completed)
        #expect(outcome.results.contains { $0.id == "example-org/flaky-service" && $0.status == .failed })
        #expect(outcome.logs.contains("example-org/api-service ok true"))
    }

    @Test("absent file resolves to null, not an error")
    func absentFile() async {
        let outcome = await run("""
        async function main() {
          const text = await gh.getContent("example-org/infra-tools", "deploy/prod.yml");
          job.log("isNull=" + (text === null));
        }
        """)
        #expect(outcome.status == .completed)
        #expect(outcome.logs.contains("isNull=true"))
    }

    @Test("params flow into job.params")
    func params() async {
        let outcome = await run("""
        async function main() {
          job.log("p=" + job.params.path + " v=" + job.params.value);
        }
        """, params: ["path": "a/b.yml", "value": "42"])
        #expect(outcome.logs.contains("p=a/b.yml v=42"))
    }

    @Test("parse.yaml and parse.json bridge to JS objects")
    func parsers() async {
        let outcome = await run("""
        async function main() {
          const y = parse.yaml("account_id: \\"123\\"\\nregion: eu-west-1\\n");
          job.log("yaml=" + y.account_id + "/" + y.region);
          const j = parse.json('{"a": [1, 2, 3]}');
          job.log("json=" + j.a.length);
          try { parse.yaml("a: [unclosed"); } catch (e) { job.log("yamlerr"); }
        }
        """)
        #expect(outcome.status == .completed)
        #expect(outcome.logs.contains("yaml=123/eu-west-1"))
        #expect(outcome.logs.contains("json=3"))
        #expect(outcome.logs.contains("yamlerr"))
    }

    @Test("state survives within a run via writeState/readState")
    func state() async {
        let outcome = await run("""
        async function main() {
          job.writeState("found", { repos: ["a", "b"] });
          const back = job.readState("found");
          job.log("n=" + back.repos.length);
          job.log("missing=" + String(job.readState("nope")));
        }
        """)
        #expect(outcome.logs.contains("n=2"))
        #expect(outcome.logs.contains("missing=null"))
    }

    @Test("Promise.all fan-out works under the concurrency limiter")
    func fanOut() async {
        let outcome = await run("""
        async function main() {
          const repos = await gh.listOrgRepos();
          const texts = await Promise.all(
            repos.map(r => gh.getContent(r, "deploy/prod.yml").catch(() => null))
          );
          job.log("fetched=" + texts.filter(t => t !== null).length);
        }
        """)
        #expect(outcome.status == .completed)
        #expect(outcome.logs.contains("fetched=4"))
    }

    @Test("script load failure is reported, not crashed")
    func syntaxError() async {
        let outcome = await run("this is not javascript {{{")
        guard case .failed = outcome.status else {
            Issue.record("expected failure, got \(outcome.status)")
            return
        }
    }

    @Test("missing main() is reported")
    func missingMain() async {
        let outcome = await run("const meta = { title: \"x\", phase: \"check\" };")
        guard case .failed(let message) = outcome.status else {
            Issue.record("expected failure, got \(outcome.status)")
            return
        }
        #expect(message.contains("main"))
    }

    @Test("watchdog terminates a runaway synchronous loop", .timeLimit(.minutes(1)))
    func watchdog() async {
        var config = EngineConfiguration()
        config.maxSyncSliceSeconds = 0.2
        config.maxSyncBudgetSeconds = 0.6
        config.maxRunSeconds = 10
        let start = Date()
        let outcome = await run("async function main() { while (true) {} }",
                                configuration: config)
        #expect(outcome.status != .completed)
        #expect(Date().timeIntervalSince(start) < 9)
    }

    @Test("cancellation rejects pending host calls and settles", .timeLimit(.minutes(1)))
    func cancellation() async throws {
        let client = FixtureGitHubClient.demo()
        client.delay = .milliseconds(250)
        let task = Task {
            await run("""
            async function main() {
              const repos = await gh.listOrgRepos();
              for (const r of repos) {
                await gh.getContent(r, "deploy/prod.yml").catch(e => { throw e; });
              }
            }
            """, client: client)
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let outcome = await task.value
        #expect(outcome.status == .cancelled)
    }
}
