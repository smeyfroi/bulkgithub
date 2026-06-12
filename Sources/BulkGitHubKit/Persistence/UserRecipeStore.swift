import Foundation

/// A user-saved recipe: the workspace captured as reusable reference
/// material — prompt, script source, and phase together, like the bundled
/// recipes.
public struct UserRecipe: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var prompt: String
    public var phase: JobPhase
    public var source: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, title: String, prompt: String,
                phase: JobPhase, source: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.phase = phase
        self.source = source
        self.createdAt = createdAt
    }

    public var asRecipe: Recipe {
        Recipe(id: id, title: title, prompt: prompt, phase: phase,
               systemImage: "bookmark", source: source)
    }
}

/// One JSON file per user recipe in Application Support/BulkGitHub/recipes —
/// the files are the source of truth, human-readable and easy to back up or
/// hand to a colleague.
public final class UserRecipeStore: @unchecked Sendable {
    private let directory: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BulkGitHub", isDirectory: true)
            .appendingPathComponent("recipes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
    }

    public func load() -> [UserRecipe] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(UserRecipe.self, from: data)
            }
            .sorted { ($0.title.localizedLowercase, $0.createdAt)
                    < ($1.title.localizedLowercase, $1.createdAt) }
    }

    public func save(_ recipe: UserRecipe) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(recipe)
        try data.write(to: fileURL(for: recipe.id), options: .atomic)
    }

    public func delete(id: String) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}
