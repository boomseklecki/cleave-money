import Foundation
import Security

/// Stores the optional bearer token in the Keychain, **keyed per server** (the `account` embeds the base
/// URL), so each backend keeps its own session - switching dev↔prod doesn't force a re-auth, and a token is
/// only ever sent to the server that minted it. The backend is default-open (no token needed) until auth is
/// enabled; once it is, every guarded request must carry the token.
struct KeychainTokenStore {
    let service: String
    let account: String

    init(service: String = "money.cleave.app", account: String = "api-bearer-token") {
        self.service = service
        self.account = account
    }

    /// A stable per-server account key from the base URL (scheme+host+port; trailing slash stripped).
    static func serverKey(_ url: URL) -> String {
        var s = url.absoluteString.lowercased()
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The token store for a specific backend.
    static func forServer(_ url: URL) -> KeychainTokenStore {
        KeychainTokenStore(account: "api-bearer-token::\(serverKey(url))")
    }

    /// One-time migration: move a token from the old single global slot into a per-server `store` (the first
    /// time we run keyed). Idempotent - a no-op once the legacy slot is empty.
    static func migrateLegacyTokenIfNeeded(into store: KeychainTokenStore) {
        let legacy = KeychainTokenStore()  // old global account: "api-bearer-token"
        guard legacy.account != store.account,
              store.load() == nil, let token = legacy.load(), !token.isEmpty else { return }
        store.save(token)
        legacy.delete()
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Saves (or replaces) the token. Passing nil/empty clears it.
    func save(_ token: String?) {
        guard let token, !token.isEmpty, let data = token.data(using: .utf8) else {
            delete()
            return
        }
        var query = baseQuery
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
