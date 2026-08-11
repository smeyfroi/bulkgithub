import Foundation
import CryptoKit

/// File parameters: a script param whose KEY ends in "File" (case-sensitive)
/// is a file parameter — its value is supplied by the user picking a local
/// file in the app, never typed and never defaulted in the script. The picked
/// file's bytes reach the script via `job.file(key)`; `job.params[key]`
/// carries only the file's display name, so paths and content never leak into
/// commit messages or PR text through the params habit.
///
/// The convention is a key-naming rule (like the params bar's long-text and
/// git-param groupings) rather than a meta schema extension, so it survives
/// RecipeMetaWriter's meta regeneration untouched and needs no apiVersion
/// bump: what travels in a recipe is the EMPTY declaration — the requirement,
/// not the bytes. Validation enforces the empty default (see
/// ValidationPipeline.extractMeta), which also means a shared recipe can never
/// arrive pointing at a path on someone else's machine.
public enum FileParams {

    /// Hard ceiling on an attached file. The whole write path is String-typed
    /// (putContent, PlannedAction diffs, the JSC bridge), and every attached
    /// byte is snapshotted into state.json — keep attachments review-sized.
    public static let maxByteSize = 2 * 1024 * 1024

    /// True when `key` declares a file parameter: ends in "File", and isn't
    /// just the bare suffix.
    public static func isFileParam(key: String) -> Bool {
        key.hasSuffix("File") && key != "File"
    }

    /// The file-param keys of a params map, sorted for stable presentation.
    public static func fileParamKeys(in params: [String: String]) -> [String] {
        params.keys.filter { isFileParam(key: $0) }.sorted()
    }

    public enum ResolveError: LocalizedError, Equatable {
        case notFound(String)
        case notAFile(String)
        case sensitiveLocation(String)
        case notUTF8(String)
        case tooLarge(String, Int)
        case unreadable(String, String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let path):
                return "The attached file no longer exists: \(path). Pick it again."
            case .notAFile(let path):
                return "\(path) is not a regular file — pick a plain text file."
            case .sensitiveLocation(let path):
                return "\(path) is in a hidden or system location under your home folder, where "
                    + "credentials and keys usually live — this app refuses to attach files from "
                    + "there. Copy the file somewhere ordinary first if it really is meant to be "
                    + "published."
            case .notUTF8(let path):
                return "\(path) is not UTF-8 text. Only text files can be attached — binary "
                    + "content would be silently corrupted on the way to GitHub."
            case .tooLarge(let path, let size):
                return "\(path) is \(size / 1024) KB — attached files are limited to "
                    + "\(FileParams.maxByteSize / (1024 * 1024)) MB so every byte stays reviewable."
            case .unreadable(let path, let reason):
                return "Could not read \(path): \(reason)"
            }
        }
    }

    /// A resolved attachment: the exact bytes (as validated UTF-8 text) plus
    /// the provenance the review pane and the staleness check need.
    public struct Resolved: Sendable, Equatable {
        public let content: String
        public let sha256: String
        public let sourcePath: String
        public let byteSize: Int

        /// The display name scripts see in `job.params` — never the path.
        public var displayName: String {
            (sourcePath as NSString).lastPathComponent
        }
    }

    /// Resolve a picked path to its content, fail-closed: symlinks resolved
    /// first, then the sensitive-location check against the REAL path (TCC
    /// does not guard ~/.ssh or ~/.aws — the app must), then strict UTF-8
    /// (never lossy — a lossy decode would commit mojibake through every
    /// guard), then the size cap. Any failure throws; nothing is partially
    /// resolved.
    public static func resolve(path: String,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Resolved {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isDirectory) else {
            throw ResolveError.notFound(path)
        }
        guard !isDirectory.boolValue else { throw ResolveError.notAFile(path) }
        if let reason = deniedReason(forResolvedPath: real, home: home) {
            throw ResolveError.sensitiveLocation(reason)
        }
        // Stat before reading: refuse an oversized file WITHOUT materialising
        // it. The post-read count below remains as the TOCTOU backstop.
        if let size = try? real.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxByteSize {
            throw ResolveError.tooLarge(path, size)
        }
        let data: Data
        do {
            data = try Data(contentsOf: real)
        } catch {
            throw ResolveError.unreadable(path, error.localizedDescription)
        }
        guard data.count <= maxByteSize else { throw ResolveError.tooLarge(path, data.count) }
        guard let content = String(data: data, encoding: .utf8) else {
            throw ResolveError.notUTF8(path)
        }
        return Resolved(content: content,
                        sha256: Self.sha256(of: data),
                        sourcePath: real.path,
                        byteSize: data.count)
    }

    /// The sensitive-location rule, on the symlink-RESOLVED path: anything
    /// whose first component under the home directory is hidden (dot-prefixed)
    /// — ~/.ssh, ~/.aws, ~/.gnupg, ~/.config, ~/.netrc, ~/.gitconfig, … —
    /// plus the ENTIRE ~/Library subtree (Keychains, cookies, app containers,
    /// browser profiles — credential stores that are not dot-prefixed live
    /// there, and nothing a user legitimately attaches for this feature
    /// does). Returns the offending path for the error, or nil when allowed.
    /// Exposed for tests (home is injectable).
    public static func deniedReason(forResolvedPath url: URL, home: URL) -> String? {
        let homeComponents = home.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > homeComponents.count,
              Array(components.prefix(homeComponents.count)) == homeComponents else {
            return nil   // outside the home directory: TCC and the picker govern
        }
        let underHome = components[homeComponents.count...]
        if let first = underHome.first, first.hasPrefix(".") || first == "Library" {
            return url.path
        }
        return nil
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of text: String) -> String {
        sha256(of: Data(text.utf8))
    }
}

/// The dry-run snapshot of one attached file, persisted on the Job: the armed
/// run applies THESE bytes (already proven byte-equal to the reviewed plan),
/// so an approved plan survives the local file being edited, moved, or
/// deleted after review. The sha256 lets the app flag a changed local file as
/// staleness at review time instead of a surprise at apply time.
public struct FileParamSnapshot: Codable, Sendable, Equatable {
    public var content: String
    public var sha256: String
    public var sourcePath: String
    public var byteSize: Int

    public init(resolved: FileParams.Resolved) {
        self.content = resolved.content
        self.sha256 = resolved.sha256
        self.sourcePath = resolved.sourcePath
        self.byteSize = resolved.byteSize
    }

    /// The display name scripts see in `job.params` — never the path.
    public var displayName: String {
        (sourcePath as NSString).lastPathComponent
    }
}
