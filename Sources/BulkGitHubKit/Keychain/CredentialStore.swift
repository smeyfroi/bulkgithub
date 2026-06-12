import Foundation
import Security

public enum CredentialKey: String, CaseIterable, Sendable {
    case githubToken = "github-token"
    case anthropicAPIKey = "anthropic-api-key"
}

public protocol CredentialStore: Sendable {
    func read(_ key: CredentialKey) -> String?
    func write(_ key: CredentialKey, value: String) throws
    func delete(_ key: CredentialKey) throws
}

public enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Generic-password Keychain storage. Secrets never leave this process
/// boundary: scripts cannot read them, saved jobs never contain them.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String

    /// Service name before the 0.4.2 rename to com.meyfroidt; items stored
    /// under it migrate forward on first read, then the old item is removed
    /// so later deletes stay deleted.
    private static let legacyService = "me.geo.bulkgithub"

    public init(service: String = "com.meyfroidt.bulkgithub") {
        self.service = service
    }

    private func baseQuery(for key: CredentialKey, service: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service ?? self.service,
         kSecAttrAccount as String: key.rawValue]
    }

    public func read(_ key: CredentialKey) -> String? {
        if let value = read(key, service: service) { return value }
        guard service != Self.legacyService,
              let legacy = read(key, service: Self.legacyService) else { return nil }
        try? write(key, value: legacy)
        SecItemDelete(baseQuery(for: key, service: Self.legacyService) as CFDictionary)
        return legacy
    }

    private func read(_ key: CredentialKey, service: String) -> String? {
        var query = baseQuery(for: key, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ key: CredentialKey, value: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(baseQuery(for: key) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(for: key)
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }

    public func delete(_ key: CredentialKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }
}

/// For tests and previews; never persists.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialKey: String] = [:]

    public init(_ initial: [CredentialKey: String] = [:]) {
        self.values = initial
    }

    public func read(_ key: CredentialKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func write(_ key: CredentialKey, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    public func delete(_ key: CredentialKey) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
    }
}
