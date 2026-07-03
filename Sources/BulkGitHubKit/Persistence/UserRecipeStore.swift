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

/// Writes user recipes as self-describing `.ts` files in
/// Application Support/BulkGitHub/recipes — the SAME format as bundled recipes,
/// so they load through the one `RecipeCatalogLoader` and interchange as plain
/// files. This type is the writer (save / rename / delete / import) plus the
/// one-time JSON→`.ts` migration; reading is the loader's job over `directory`.
///
/// Filenames (and hence recipe ids) are unique `user-<uuid>` stems, so a saved
/// or imported recipe never silently shadows a bundled recipe of the same name.
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

    /// Persist `source` as a user recipe under the given display name + prompt
    /// (written into the file's `meta`, so the `.ts` is self-describing).
    /// Returns the new recipe id (filename stem).
    @discardableResult
    public func save(title: String, prompt: String, source: String) throws -> String {
        let id = Self.freshId()
        let ts = RecipeMetaWriter.applying(title: title, prompt: prompt, to: source) ?? source
        try write(ts, id: id)
        return id
    }

    /// Rewrite an existing user recipe's display name (`meta.title`) in place.
    public func rename(id: String, to newTitle: String) throws {
        let url = fileURL(id)
        let source = try String(contentsOf: url, encoding: .utf8)
        try write(RecipeMetaWriter.setField("title", to: newTitle, in: source) ?? source, id: id)
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
    /// write the `.ts`, verify (via `service`) it loads back with the expected
    /// title, and only THEN retire the `.json` (renamed to `.json.migrated`, not
    /// deleted). A file that fails to migrate is left as JSON, untouched — so no
    /// recipe is ever lost mid-migration. Idempotent: rerunning finds no `.json`.
    public func migrateLegacyJSON(using service: TypeScriptService?) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for json in files where json.pathExtension == "json" {
            guard let data = try? Data(contentsOf: json),
                  let legacy = try? decoder.decode(LegacyUserRecipe.self, from: data) else { continue }
            let id = legacy.id.hasPrefix("user-") ? legacy.id : "user-\(legacy.id)"
            let ts = RecipeMetaWriter.applying(title: legacy.title, prompt: legacy.prompt,
                                               to: legacy.source) ?? legacy.source
            do {
                try write(ts, id: id)
            } catch {
                continue   // couldn't write the .ts — leave the JSON in place
            }
            if extractedTitle(ts, using: service) == legacy.title {
                let backup = json.appendingPathExtension("migrated")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: json, to: backup)
            } else {
                // The .ts didn't round-trip; don't leave a broken file behind,
                // and keep the JSON as the source of truth for a later retry.
                try? FileManager.default.removeItem(at: fileURL(id))
            }
        }
    }

    private func extractedTitle(_ ts: String, using service: TypeScriptService?) -> String? {
        guard let service,
              let javaScript = try? service.transpile(source: ts),
              let meta = try? ValidationPipeline.extractMeta(fromJavaScript: javaScript) else { return nil }
        return meta.title
    }
}
