import Foundation

/// Everything restored on launch. Secrets are excluded by construction:
/// they live in Keychain, referenced only by CredentialKey.
public struct AppStateSnapshot: Codable, Sendable {
    public var settings: AppSettings
    public var job: Job?

    public init(settings: AppSettings = AppSettings(), job: Job? = nil) {
        self.settings = settings
        self.job = job
    }
}

/// JSON-file persistence for a single active job. Deliberately small and
/// swappable (SwiftData/SQLite if the model grows to saved jobs and run
/// history).
public final class AppStateStore: @unchecked Sendable {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BulkGitHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("state.json")
    }

    public func load() -> AppStateSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppStateSnapshot.self, from: data)
    }

    public func save(_ snapshot: AppStateSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
