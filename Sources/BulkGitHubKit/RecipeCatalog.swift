import Foundation

/// A recipe: the script plus the natural-language prompt that would generate
/// it — loading one restores both. Every recipe is a self-describing `.ts`
/// file; its title/prompt/phase/icon come from the file's `meta` block, read at
/// load time (see RecipeCatalogLoader). The source is always carried inline —
/// the loader read it from disk, so there is no lazy id→path resolution that
/// could let one recipe accidentally read another's file.
public struct Recipe: Identifiable, Sendable, Equatable {
    /// Where the recipe came from — a bundled file that ships in the app, or a
    /// user file (saved, dropped in, or imported). Drives provenance in the UI.
    public enum Origin: String, Sendable, Equatable { case bundled, user }

    public let id: String          // recipe file name (without .ts)
    public let title: String
    public let prompt: String
    public let phase: JobPhase
    public let systemImage: String
    public let origin: Origin
    public let source: String

    public init(id: String, title: String, prompt: String, phase: JobPhase,
                systemImage: String, origin: Origin = .bundled, source: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.phase = phase
        self.systemImage = systemImage
        self.origin = origin
        self.source = source
    }

    /// Fallback icon when a recipe's `meta` declares no `icon`.
    public static func defaultIcon(for phase: JobPhase) -> String {
        switch phase {
        case .check: return "magnifyingglass"
        case .update: return "pencil"
        case .merge: return "arrow.triangle.merge"
        }
    }
}

/// Builds the recipe catalog by reading each recipe file's `meta` at runtime,
/// so a new recipe ships by dropping a `.ts` file — no Swift edit, no recompile
/// of catalog logic. Reads the bundled recipes directory and (Phase 2) a
/// user-writable directory; a user file shadows a bundled one with the same id.
///
/// `load()` is synchronous and, on a cold cache, pays the TypeScript
/// transpile + meta-extraction per file (~a few ms each plus a one-time
/// compiler boot) — call it OFF the main actor. Results are cached by file
/// path + modification date, so a re-scan after an import does no redundant
/// work. A malformed file is skipped and logged, never fatal to the library.
public final class RecipeCatalogLoader: @unchecked Sendable {
    private let service: TypeScriptService?
    private let bundledDirectory: URL?
    private let userDirectory: URL?
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    private struct CacheEntry { let mtime: Date; let recipe: Recipe }

    public init(service: TypeScriptService?,
                bundledDirectory: URL? = ResourceLocator.recipesDirectory,
                userDirectory: URL? = nil) {
        self.service = service
        self.bundledDirectory = bundledDirectory
        self.userDirectory = userDirectory
    }

    /// The full catalog, bundled then user (user shadows bundled on id clash),
    /// sorted by title.
    public func load() -> [Recipe] {
        guard let service else { return [] }
        var byId: [String: Recipe] = [:]
        for (directory, origin) in [(bundledDirectory, Recipe.Origin.bundled),
                                    (userDirectory, Recipe.Origin.user)] {
            guard let directory else { continue }
            for url in Self.recipeFiles(in: directory) {
                guard let recipe = loadOne(url, service: service, origin: origin) else { continue }
                byId[recipe.id] = recipe   // later origin (user) wins the clash
            }
        }
        return byId.values.sorted { $0.title.localizedLowercase < $1.title.localizedLowercase }
    }

    private static func recipeFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "ts" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    private func loadOne(_ url: URL, service: TypeScriptService, origin: Recipe.Origin) -> Recipe? {
        let path = url.path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let mtime {
            lock.lock()
            if let cached = cache[path], cached.mtime == mtime { lock.unlock(); return cached.recipe }
            lock.unlock()
        }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let recipe: Recipe
        do {
            let javaScript = try service.transpile(source: source)
            let meta = try ValidationPipeline.extractMeta(fromJavaScript: javaScript)
            recipe = Recipe(id: url.deletingPathExtension().lastPathComponent,
                            title: meta.title,
                            prompt: meta.prompt ?? "",
                            phase: meta.phase,
                            systemImage: meta.icon ?? Recipe.defaultIcon(for: meta.phase),
                            origin: origin,
                            source: source)
        } catch {
            // Skip-and-log: one bad file must never blank the whole library.
            print("BulkGitHub: skipping recipe \(url.lastPathComponent): \(error)")
            return nil
        }
        if let mtime {
            lock.lock(); cache[path] = CacheEntry(mtime: mtime, recipe: recipe); lock.unlock()
        }
        return recipe
    }
}
