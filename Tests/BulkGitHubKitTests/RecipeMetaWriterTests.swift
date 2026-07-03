import Foundation
import Testing
@testable import BulkGitHubKit

/// Regression tests for the recipe meta rewriter (save/rename). These pin the
/// fixes for the fragile field-regex writer: a whole-object regenerate must
/// survive values containing "function main", single quotes, and a params key
/// named "prompt", and an invalid script must throw instead of silently
/// vanishing from the catalog.
@Suite("Recipe meta rewriting", .serialized)
struct RecipeMetaWriterTests {

    static let service = TypeScriptService.loadDefault()

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bulkgh-mw-\(UUID().uuidString)")
    }
    private func load(_ dir: URL) -> [Recipe] {
        RecipeCatalogLoader(service: Self.service, bundledDirectory: nil, userDirectory: dir).load()
    }

    private let base = """
    const meta: ScriptMeta = { title: "orig", phase: "check", apiVersion: 1, params: { path: "README.md" } };
    async function main(): Promise<void> {}
    """

    @Test("a prompt containing 'function main' round-trips (no duplicate/stale key)")
    func promptWithFunctionMain() throws {
        let service = try #require(Self.service)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = try UserRecipeStore(directory: dir)
            .save(title: "T", prompt: "explain how function main works", source: base, using: service)
        let recipe = try #require(load(dir).first { $0.id == id })
        #expect(recipe.title == "T")
        #expect(recipe.prompt == "explain how function main works")
    }

    @Test("single-quoted meta values are handled")
    func singleQuotedMeta() throws {
        let service = try #require(Self.service)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = "const meta = { title: 'orig', phase: 'check' };\nasync function main() {}"
        let id = try UserRecipeStore(directory: dir)
            .save(title: "Renamed", prompt: "p", source: source, using: service)
        let recipe = try #require(load(dir).first { $0.id == id })
        #expect(recipe.title == "Renamed")
        #expect(recipe.prompt == "p")
    }

    @Test("a params key named 'prompt' is not clobbered by the prompt rewrite")
    func paramsNotCorrupted() throws {
        let service = try #require(Self.service)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = "const meta = { title: 'x', phase: 'check', params: { prompt: 'PARAMVAL', path: 'p' } };\nasync function main() {}"
        let id = try UserRecipeStore(directory: dir)
            .save(title: "T", prompt: "NEWPROMPT", source: source, using: service)
        let ts = try String(contentsOf: dir.appendingPathComponent("\(id).ts"), encoding: .utf8)
        let meta = try ValidationPipeline.extractMeta(fromJavaScript: service.transpile(source: ts))
        #expect(meta.prompt == "NEWPROMPT")
        #expect(meta.params["prompt"] == "PARAMVAL")
        #expect(meta.params["path"] == "p")
    }

    @Test("saving non-recipe text throws instead of silently vanishing")
    func invalidRecipeThrows() throws {
        let service = try #require(Self.service)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) {
            _ = try UserRecipeStore(directory: dir)
                .save(title: "T", prompt: "p", source: "const x = 1;", using: service)
        }
        #expect(load(dir).isEmpty)
    }

    @Test("renaming a recipe whose title contains 'function main' works")
    func renameFunctionMainTitle() throws {
        let service = try #require(Self.service)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = UserRecipeStore(directory: dir)
        let source = "const meta = { title: 'document function main', phase: 'check' };\nasync function main() {}"
        let id = try store.save(title: "document function main", prompt: "p", source: source, using: service)
        try store.rename(id: id, to: "Renamed OK", using: service)
        let recipe = try #require(load(dir).first { $0.id == id })
        #expect(recipe.title == "Renamed OK")
        #expect(recipe.prompt == "p")   // prompt preserved through rename
    }

    @Test("a source whose meta declares no title still saves under the given name")
    func metaWithoutTitle() throws {
        let service = try #require(Self.service)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // The exact shape that previously vanished on migrate/save: meta present
        // (so it's a valid recipe) but with no `title:` field to anchor.
        let source = "const meta = { phase: 'check' };\nasync function main() {}"
        let id = try UserRecipeStore(directory: dir)
            .save(title: "Named", prompt: "p", source: source, using: service)
        let recipe = try #require(load(dir).first { $0.id == id })
        #expect(recipe.title == "Named")
        #expect(recipe.prompt == "p")
    }
}
