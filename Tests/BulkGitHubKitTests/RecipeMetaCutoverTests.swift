import Foundation
import Testing
@testable import BulkGitHubKit

/// Cutover guard for recipe externalization (Phase 0 → Phase 1). Every bundled
/// recipe's in-file `meta` must be a faithful superset of its hardcoded
/// `RecipeCatalog` entry — same title, phase, prompt, and icon. Once this holds,
/// Phase 1 can build the catalog by reading the files and delete the Swift array
/// without changing any behavior. If a recipe's meta drifts from the catalog,
/// this fails loudly *before* the array is removed.
@Suite("Recipe meta cutover equivalence", .serialized)
struct RecipeMetaCutoverTests {

    static let service = TypeScriptService.loadDefault()

    @Test("every bundled recipe's meta matches its catalog entry")
    func metaMatchesCatalog() throws {
        let service = try #require(Self.service, "TypeScript resources missing from bundle")
        #expect(RecipeCatalog.all.count == 13)

        for recipe in RecipeCatalog.all {
            let source = try #require(recipe.source, "no source for \(recipe.id)")
            let js = try service.transpile(source: source)
            let meta = try ValidationPipeline.extractMeta(fromJavaScript: js)

            #expect(meta.title == recipe.title,
                    "title mismatch for \(recipe.id): meta=\"\(meta.title)\" catalog=\"\(recipe.title)\"")
            #expect(meta.phase == recipe.phase,
                    "phase mismatch for \(recipe.id): meta=\(meta.phase) catalog=\(recipe.phase)")
            #expect(meta.prompt == recipe.prompt,
                    "prompt mismatch for \(recipe.id): meta=\"\(meta.prompt ?? "nil")\" catalog=\"\(recipe.prompt)\"")
            #expect(meta.icon == recipe.systemImage,
                    "icon mismatch for \(recipe.id): meta=\"\(meta.icon ?? "nil")\" catalog=\"\(recipe.systemImage)\"")
        }
    }

    @Test("every bundled recipe declares a prompt and icon in its meta")
    func everyRecipeIsSelfDescribing() throws {
        let service = try #require(Self.service)
        for recipe in RecipeCatalog.all {
            let source = try #require(recipe.source)
            let meta = try ValidationPipeline.extractMeta(fromJavaScript: service.transpile(source: source))
            #expect(meta.prompt?.isEmpty == false, "\(recipe.id) has no meta.prompt")
            #expect(meta.icon?.isEmpty == false, "\(recipe.id) has no meta.icon")
        }
    }
}
