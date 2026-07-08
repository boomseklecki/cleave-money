import Foundation
import Security

/// Bridges the app's current backend base URL + bearer token into the shared App Group container so the
/// **Share Extension** (which runs out-of-process and can't see the app's per-server token store) can upload a
/// statement without opening the app. The app writes this on sign-in / token refresh / server switch; sign-out
/// clears the token. A single "current server" slot is enough - the extension imports to whatever backend the
/// app is currently pointed at.
public enum SharedImportConfig {
    private static let appGroup = "group.money.cleave.app"
    private static let baseURLKey = "apiBaseURL"
    private static let service = "money.cleave.app"
    private static let account = "shared-import-bearer-token"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: appGroup]
    }

    /// Mirror the current base URL + token (call on sign-in / token change / server switch). A nil/empty token
    /// (open backend or signed out) clears the stored token but keeps the base URL.
    public static func update(baseURL: String, token: String?) {
        defaults?.set(baseURL, forKey: baseURLKey)
        SecItemDelete(baseQuery as CFDictionary)
        guard let token, !token.isEmpty, let data = token.data(using: .utf8) else { return }
        var q = baseQuery
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock  // readable by the extension while locked
        SecItemAdd(q as CFDictionary, nil)
    }

    public static func baseURL() -> String? { defaults?.string(forKey: baseURLKey) }

    public static func token() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
