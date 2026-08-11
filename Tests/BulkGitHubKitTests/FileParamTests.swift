import Foundation
import Testing
@testable import BulkGitHubKit

/// File parameters (*File keys): the convention, the fail-closed resolver,
/// the validation rule, the job.file binding, and the armed replay path.
@Suite("File params (attached local files)")
struct FileParamTests {

    // MARK: Convention

    @Test("only case-sensitive *File keys (and not the bare suffix) are file params")
    func convention() {
        #expect(FileParams.isFileParam(key: "workflowFile"))
        #expect(FileParams.isFileParam(key: "contentFile"))
        #expect(!FileParams.isFileParam(key: "File"))          // bare suffix
        #expect(!FileParams.isFileParam(key: "file"))          // lowercase
        #expect(!FileParams.isFileParam(key: "profile"))       // lowercase suffix
        #expect(!FileParams.isFileParam(key: "path"))
        #expect(!FileParams.isFileParam(key: "Filename"))      // not a suffix
        #expect(FileParams.fileParamKeys(in: ["bFile": "", "aFile": "", "path": "x"])
                == ["aFile", "bFile"])
    }

    // MARK: Resolver

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-param-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("resolve returns exact content, sha256, size, and the display name")
    func resolveHappyPath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ci.yml")
        let body = "name: CI\non: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n"
        try body.write(to: file, atomically: true, encoding: .utf8)

        let resolved = try FileParams.resolve(path: file.path)
        #expect(resolved.content == body)
        #expect(resolved.displayName == "ci.yml")
        #expect(resolved.byteSize == body.utf8.count)
        #expect(resolved.sha256 == FileParams.sha256(of: body))
    }

    @Test("resolve fails closed: missing file, directory, non-UTF-8, oversize")
    func resolveFailures() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: FileParams.ResolveError.self) {
            try FileParams.resolve(path: dir.appendingPathComponent("absent.yml").path)
        }
        #expect(throws: FileParams.ResolveError.self) {
            try FileParams.resolve(path: dir.path)   // a directory, not a file
        }

        let binary = dir.appendingPathComponent("binary.bin")
        try Data([0xFF, 0xFE, 0x00, 0xC3, 0x28]).write(to: binary)
        #expect(throws: FileParams.ResolveError.notUTF8(binary.path)) {
            try FileParams.resolve(path: binary.path)
        }

        let huge = dir.appendingPathComponent("huge.txt")
        try Data(repeating: UInt8(ascii: "a"), count: FileParams.maxByteSize + 1).write(to: huge)
        #expect(throws: FileParams.ResolveError.self) {
            try FileParams.resolve(path: huge.path)
        }
    }

    @Test("sensitive locations under home are denied on the symlink-resolved path")
    func denylist() throws {
        let home = URL(fileURLWithPath: "/Users/someone")
        func denied(_ path: String) -> Bool {
            FileParams.deniedReason(forResolvedPath: URL(fileURLWithPath: path), home: home) != nil
        }
        #expect(denied("/Users/someone/.ssh/id_rsa"))
        #expect(denied("/Users/someone/.aws/credentials"))
        #expect(denied("/Users/someone/.netrc"))
        #expect(denied("/Users/someone/.config/gh/hosts.yml"))
        // The ENTIRE ~/Library subtree: non-dot credential stores live there.
        #expect(denied("/Users/someone/Library/Keychains/login.keychain-db"))
        #expect(denied("/Users/someone/Library/Application Support/notes.txt"))
        #expect(denied("/Users/someone/Library/Cookies/HSTS.plist"))
        #expect(!denied("/Users/someone/Documents/ci.yml"))
        #expect(!denied("/Users/someone/Development/repo/ci.yml"))
        #expect(!denied("/tmp/ci.yml"))                       // outside home
        #expect(!denied("/Users/someoneelse/.ssh/id_rsa"))    // different home
    }

    @Test("resolve refuses a file inside a hidden home location end to end")
    func resolveDenylist() throws {
        let fakeHome = try tempDir()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let ssh = fakeHome.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let key = ssh.appendingPathComponent("id_rsa")
        try "SECRET".write(to: key, atomically: true, encoding: .utf8)

        #expect(throws: FileParams.ResolveError.self) {
            try FileParams.resolve(path: key.path, home: fakeHome)
        }
        // A symlink from an innocent location into the hidden one is caught
        // on the resolved path.
        let link = fakeHome.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
        #expect(throws: FileParams.ResolveError.self) {
            try FileParams.resolve(path: link.path, home: fakeHome)
        }
    }

    // MARK: Validation rule

    @Test("meta validation rejects a *File param with a non-empty default")
    func validationRejectsNonEmptyDefault() throws {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let script = """
        const meta = { title: "t", phase: "check", apiVersion: 1,
                       params: { contentFile: "sneaky/default.txt" } };
        async function main(): Promise<void> {}
        """
        #expect(throws: ValidationError.self) {
            try pipeline.validate(source: script)
        }
    }

    @Test("meta validation accepts a *File param with an empty default")
    func validationAcceptsEmptyDefault() throws {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let script = """
        const meta = { title: "t", phase: "check", apiVersion: 1,
                       params: { contentFile: "" } };
        async function main(): Promise<void> {}
        """
        let validated = try pipeline.validate(source: script)
        #expect(validated.meta.params["contentFile"] == "")
    }

    // MARK: job.file binding, dry run → armed replay

    /// An update script in the canonical rule-19 shape: content from
    /// job.file, name-only in job.params, one branch/put/PR per repo.
    private static let addFileScript = """
    const meta = { title: "Add attached file", phase: "update", apiVersion: 1,
                   params: { path: "NEW_FILE.md", contentFile: "",
                             branch: "bulkgh/add-file", message: "Add file",
                             prTitle: "Add file", prBody: "Adds an attached file." } };
    async function main(): Promise<void> {
      const { path, branch, message, prTitle, prBody } = job.params;
      const content = job.file("contentFile");
      const repos = await gh.listOrgRepos();
      for (const repo of repos) {
        if (repo.archived) { job.skip(repo, "archived"); continue; }
        try {
          const existing = await gh.getContent(repo.fullName, path);
          if (existing !== null) { job.skip(repo, "exists"); continue; }
          const ref = await gh.getRef(repo.fullName, `heads/${repo.defaultBranch}`);
          if (ref === null) { job.error(repo, "no ref"); continue; }
          await gh.createBranch(repo.fullName, branch, ref.sha);
          await gh.putContent(repo.fullName, path, content, { branch, message });
          await gh.createPR(repo.fullName, { head: branch, title: prTitle, body: prBody });
        } catch (e) { job.error(repo, String(e)); }
      }
    }
    """

    /// The attached content (the script above never transforms it).
    private var body: String { "# New file\n\nExact bytes, straight from disk.\n" }

    private func validated() throws -> ValidatedScript {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        return try pipeline.validate(source: Self.addFileScript)
    }

    private func params(from validated: ValidatedScript) -> [String: String] {
        // What the app does: the file param carries the display NAME only.
        var params = validated.meta.params
        params["contentFile"] = "ci.yml"
        return params
    }

    @Test("dry run: job.file content lands verbatim in the plan as a created file")
    func dryRunRecordsAttachedContent() async throws {
        let client = FixtureGitHubClient.demo()
        let validated = try validated()
        var configuration = EngineConfiguration()
        configuration.resolvedFiles = ["contentFile": body]

        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: .update,
                                               params: params(from: validated),
                                               github: client,
                                               organisation: "example-org",
                                               configuration: configuration,
                                               onEvent: { _ in })
        #expect(outcome.status == .completed)
        #expect(!outcome.plannedActions.isEmpty)
        for (_, actions) in outcome.plannedActions {
            let put = actions.compactMap { action -> (before: String?, after: String)? in
                if case .putContent(_, _, _, let before, let after) = action {
                    return (before, after)
                }
                return nil
            }
            #expect(put.count == 1)
            #expect(put.first?.after == body)          // byte-exact, no LLM in the loop
            #expect(put.first?.before == nil)          // a created file: all-added diff
        }
        // The plan summary reads as a creation.
        let summaries = outcome.plannedActions.values.flatMap { $0 }.map(\.summary)
        #expect(summaries.contains { $0.hasPrefix("Create NEW_FILE.md") })
    }

    @Test("job.file with no attached file throws with a pointed message")
    func unknownKeyThrows() async throws {
        let client = FixtureGitHubClient.demo()
        let validated = try validated()

        // No resolvedFiles configured — the very first job.file call rejects.
        let outcome = await ScriptEngine().run(javaScript: validated.javaScript,
                                               phase: .update,
                                               params: params(from: validated),
                                               github: client,
                                               organisation: "example-org",
                                               onEvent: { _ in })
        guard case .failed(let message) = outcome.status else {
            Issue.record("expected the run to fail, got \(outcome.status)")
            return
        }
        #expect(message.contains("no attached file"))
        #expect(outcome.plannedActions.isEmpty)
    }

    @Test("armed replay: snapshot content applies even though no disk file exists")
    func armedAppliesSnapshot() async throws {
        let client = FixtureGitHubClient.demo()
        let validated = try validated()
        var dryConfiguration = EngineConfiguration()
        dryConfiguration.resolvedFiles = ["contentFile": body]

        let dryRun = await ScriptEngine().run(javaScript: validated.javaScript,
                                              phase: .update,
                                              params: params(from: validated),
                                              github: client,
                                              organisation: "example-org",
                                              configuration: dryConfiguration,
                                              onEvent: { _ in })
        #expect(dryRun.status == .completed)
        let targets = Set(dryRun.plannedActions.keys)
        #expect(!targets.isEmpty)

        // The armed run feeds the SNAPSHOT (same bytes) — the app never
        // re-reads disk here, so this is exactly the replay path.
        var armedConfiguration = EngineConfiguration()
        armedConfiguration.writeMode = .armed
        armedConfiguration.targetRepos = targets
        armedConfiguration.referencePlan = dryRun.plannedActions
        armedConfiguration.resolvedFiles = ["contentFile": body]

        let armed = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update,
                                             params: params(from: validated),
                                             github: client,
                                             organisation: "example-org",
                                             configuration: armedConfiguration,
                                             onEvent: { _ in })
        #expect(armed.status == .completed)
        for repo in targets {
            #expect(client.branchContent(repo: repo, branch: "bulkgh/add-file",
                                         path: "NEW_FILE.md") == body)
        }
    }

    @Test("armed conformance: different attached bytes than reviewed halt the repo")
    func armedRejectsDivergentBytes() async throws {
        let client = FixtureGitHubClient.demo()
        let validated = try validated()
        var dryConfiguration = EngineConfiguration()
        dryConfiguration.resolvedFiles = ["contentFile": body]

        let dryRun = await ScriptEngine().run(javaScript: validated.javaScript,
                                              phase: .update,
                                              params: params(from: validated),
                                              github: client,
                                              organisation: "example-org",
                                              configuration: dryConfiguration,
                                              onEvent: { _ in })
        let targets = Set(dryRun.plannedActions.keys)
        #expect(!targets.isEmpty)

        // Simulate the bug the snapshot design prevents: bytes at apply time
        // differ from the reviewed plan. Guard 5 must halt, write nothing.
        var armedConfiguration = EngineConfiguration()
        armedConfiguration.writeMode = .armed
        armedConfiguration.targetRepos = targets
        armedConfiguration.referencePlan = dryRun.plannedActions
        armedConfiguration.resolvedFiles = ["contentFile": body + "tampered\n"]

        let armed = await ScriptEngine().run(javaScript: validated.javaScript,
                                             phase: .update,
                                             params: params(from: validated),
                                             github: client,
                                             organisation: "example-org",
                                             configuration: armedConfiguration,
                                             onEvent: { _ in })
        for result in armed.results where targets.contains(result.id) {
            #expect(result.status == .conflicted)
        }
        for repo in targets {
            #expect(client.branchContent(repo: repo, branch: "bulkgh/add-file",
                                         path: "NEW_FILE.md") == nil)
        }
    }

    // MARK: Bundled recipe

    @Test("the add_file recipe validates and declares its file param empty")
    func bundledRecipeValidates() throws {
        let pipeline = ValidationPipeline(typescript: TypeScriptService.loadDefault())
        let source = try #require(ResourceLocator.recipe(named: "add_file"))
        let validated = try pipeline.validate(source: source)
        #expect(validated.meta.phase == .update)
        #expect(validated.meta.params["contentFile"] == "")
        #expect(FileParams.fileParamKeys(in: validated.meta.params) == ["contentFile"])
    }
}
