import Foundation
import Testing
@testable import BulkGitHubKit

/// The recipe catalog is built at runtime by reading each bundled recipe file's
/// `meta` (RecipeCatalogLoader), replacing the old hardcoded Swift array. These
/// guard that the loader produces a complete, well-formed catalog — the
/// invariant that lets recipes ship as files without a Swift edit — and that
/// scan-time meta extraction is bounded against a runaway file.
@Suite("Recipe catalog loader", .serialized)
struct RecipeCatalogLoaderTests {

    static let service = TypeScriptService.loadDefault()

    @Test("loads every bundled recipe with complete, self-describing metadata")
    func loadsBundledCatalog() throws {
        let service = try #require(Self.service, "TypeScript resources missing from bundle")
        let recipes = RecipeCatalogLoader(service: service).load()

        #expect(recipes.count == 13, "expected 13 bundled recipes, got \(recipes.count)")
        #expect(Set(recipes.map(\.id)).count == recipes.count, "recipe ids must be unique")

        for recipe in recipes {
            #expect(!recipe.title.isEmpty, "\(recipe.id): empty title")
            #expect(!recipe.prompt.isEmpty, "\(recipe.id): empty prompt")
            #expect(!recipe.systemImage.isEmpty, "\(recipe.id): empty icon")
            #expect(!recipe.source.isEmpty, "\(recipe.id): empty source")
            #expect(recipe.origin == .bundled, "\(recipe.id): wrong origin")
            #expect(ValidationPipeline.sniffPhase(from: recipe.source) == recipe.phase,
                    "\(recipe.id): meta.phase disagrees with the script")
        }

        // The golden first-launch example must always resolve.
        #expect(recipes.contains { $0.id == "find_file_missing_string" })
    }

    @Test("the mtime cache returns identical recipes on a second load")
    func cacheIsStable() throws {
        let service = try #require(Self.service)
        let loader = RecipeCatalogLoader(service: service)
        #expect(loader.load() == loader.load())
    }

    @Test("a recipe with a top-level runaway is terminated, not hung")
    func watchdogBoundsMetaExtraction() throws {
        let service = try #require(Self.service)
        // A top-level infinite loop after the meta declaration: extraction must
        // THROW (watchdog-terminated) rather than hang catalog construction.
        let javaScript = try service.transpile(source: """
        const meta = { title: "x", phase: "check" };
        while (true) {}
        async function main() {}
        """)
        #expect(throws: (any Error).self) {
            _ = try ValidationPipeline.extractMeta(fromJavaScript: javaScript)
        }
    }
}
