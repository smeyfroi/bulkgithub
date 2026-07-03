import Foundation

/// Legacy per-recipe JSON (pre-`.ts` user recipes). Retained only so existing
/// saves can be migrated to the unified `.ts` format on first launch.
private struct LegacyUserRecipe: Codable {
    var id: String
    var title: String
    var prompt: String
    var phase: JobPhase
    var source: String
    var createdAt: Date
}

public enum RecipeStoreError: LocalizedError {
    case compilerUnavailable
    case invalidRecipe
    case roundTripFailed

    public var errorDescription: String? {
        switch self {
        case .compilerUnavailable:
            return "The recipe compiler is unavailable."
        case .invalidRecipe:
            return "This isn't a valid recipe — it needs a meta block and an async function main()."
        case .roundTripFailed:
            return "Could not write a self-describing recipe file."
        }
    }
}

/// Writes user recipes as self-describing `.ts` files in
/// Application Support/BulkGitHub/recipes — the SAME format as bundled recipes,
/// so they load through the one `RecipeCatalogLoader` and interchange as plain
/// files. This type is the writer (save / rename / delete / import) plus the
/// one-time JSON→`.ts` migration; reading is the loader's job over `directory`.
///
/// Save/rename regenerate the file's `meta` from its parsed values (title/prompt
/// overridden) and VERIFY the result round-trips before returning — so an
/// invalid script throws instead of writing a file that silently vanishes from
/// the catalog. Filenames (and recipe ids) are unique `user-<uuid>` stems, so a
/// saved or imported recipe never shadows a bundled recipe of the same name.
public final class UserRecipeStore: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BulkGitHub", isDirectory: true)
            .appendingPathComponent("recipes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
    }

    /// Persist `source` as a user recipe under the given display name + prompt.
    /// Throws (RecipeStoreError / validation error) if `source` isn't a valid
    /// recipe or the rewritten file doesn't round-trip. Returns the new id.
    @discardableResult
    public func save(title: String, prompt: String, source: String,
                     using service: TypeScriptService?) throws -> String {
        guard let service else { throw RecipeStoreError.compilerUnavailable }
        let ts = try Self.rewrite(source: source, title: title, prompt: prompt, using: service)
        let id = Self.freshId()
        try write(ts, id: id)
        return id
    }

    /// Rewrite an existing user recipe's display name (keeping its prompt).
    public func rename(id: String, to newTitle: String, using service: TypeScriptService?) throws {
        guard let service else { throw RecipeStoreError.compilerUnavailable }
        let source = try String(contentsOf: fileURL(id), encoding: .utf8)
        let ts = try Self.rewrite(source: source, title: newTitle, prompt: nil, using: service)
        try write(ts, id: id)
    }

    public func delete(id: String) throws {
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Copy an external `.ts` into the user directory under a fresh unique id.
    /// Returns the new id. (Validation is the caller's job before adopting.)
    @discardableResult
    public func importRecipe(from url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        let id = Self.freshId()
        try write(source, id: id)
        return id
    }

    /// Regenerate `source`'s meta with the given title (and prompt, or the
    /// source's existing prompt when `prompt` is nil), verify the result loads
    /// back with the intended values, and return the new `.ts`. Throws on any
    /// failure so callers never persist a silently-broken recipe.
    private static func rewrite(source: String, title: String, prompt: String?,
                                using service: TypeScriptService) throws -> String {
        let meta: ScriptMeta
        do { meta = try metaOf(source, using: service) } catch { throw RecipeStoreError.invalidRecipe }
        let finalPrompt = prompt ?? meta.prompt
        guard let ts = RecipeMetaWriter.replacingMeta(
            in: source, title: title, phase: meta.phase, apiVersion: meta.apiVersion,
            prompt: finalPrompt, icon: meta.icon, params: meta.params) else {
            throw RecipeStoreError.invalidRecipe
        }
        let check: ScriptMeta
        do { check = try metaOf(ts, using: service) } catch { throw RecipeStoreError.roundTripFailed }
        guard check.title == title, (check.prompt ?? "") == (finalPrompt ?? "") else {
            throw RecipeStoreError.roundTripFailed
        }
        return ts
    }

    private static func metaOf(_ source: String, using service: TypeScriptService) throws -> ScriptMeta {
        try ValidationPipeline.extractMeta(fromJavaScript: try service.transpile(source: source))
    }

    private func write(_ source: String, id: String) throws {
        try Data(source.utf8).write(to: fileURL(id), options: .atomic)
    }

    private func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).ts")
    }

    private static func freshId() -> String {
        "user-" + UUID().uuidString.lowercased()
    }

    // MARK: Migration

    /// One-time, non-destructive migration of legacy JSON user recipes to `.ts`:
    /// regenerate a self-describing `.ts` (verified to round-trip inside
    /// `rewrite`), then retire the `.json` (renamed to `.json.migrated`, not
    /// deleted). A file that can't form a valid recipe is left as JSON, so no
    /// recipe is lost. Idempotent: rerunning finds no `.json`.
    public func migrateLegacyJSON(using service: TypeScriptService?) {
        guard let service, let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for json in files where json.pathExtension == "json" {
            guard let data = try? Data(contentsOf: json),
                  let legacy = try? decoder.decode(LegacyUserRecipe.self, from: data) else { continue }
            let id = legacy.id.hasPrefix("user-") ? legacy.id : "user-\(legacy.id)"
            let ts: String
            do {
                ts = try Self.rewrite(source: legacy.source, title: legacy.title,
                                      prompt: legacy.prompt, using: service)
                try write(ts, id: id)
            } catch {
                continue   // can't form a valid .ts — leave the JSON untouched
            }
            let backup = json.appendingPathExtension("migrated")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: json, to: backup)
        }
    }
}
