import Foundation
#if canImport(Security)
import Security
#endif

/// The two tokens that keep a device signed in.
public struct StoredTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String

    public init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

public protocol TokenStore: Sendable {
    func load() -> StoredTokens?
    func save(_ tokens: StoredTokens)
    func clear()
}

/// Keeps tokens in memory only. Used by tests and previews.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: StoredTokens?

    public init(_ tokens: StoredTokens? = nil) {
        self.tokens = tokens
    }

    public func load() -> StoredTokens? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: StoredTokens) {
        lock.lock(); defer { lock.unlock() }
        self.tokens = tokens
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        tokens = nil
    }
}

#if canImport(Security)
/// Stores the tokens in the Keychain. They stay on this device: a session belongs to one
/// device, so the item is not synced or restored onto another one.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "dev.horine.lorislist", account: String = "api-tokens") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func load() -> StoredTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    public func save(_ tokens: StoredTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
#endif
