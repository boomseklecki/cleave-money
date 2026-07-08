import CryptoKit
import Foundation
import Security

/// This device's static P-256 key-agreement keypair for E2E push. The private key lives in the Keychain
/// under a shared **App Group** access group (`group.money.cleave.app`) so the notification-service
/// extension can read it to decrypt pushes while the app owns generation + publishing of the public key.
/// `kSecAttrAccessibleAfterFirstUnlock` so the extension can decrypt even while the device is locked.
public struct PushKeychain: Sendable {
    public static let shared = PushKeychain()

    private let service = "money.cleave.app"
    private let account = "push-e2e-p256-private"
    // An App Group identifier is a valid keychain access group without the team-id prefix, and works for
    // app↔extension sharing. Requires the App Groups capability on both targets' entitlements.
    private let accessGroup = "group.money.cleave.app"

    public init() {}

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup]
    }

    /// The stored private key, if present.
    public func loadPrivateKey() -> P256.KeyAgreement.PrivateKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) else { return nil }
        return key
    }

    /// Returns the existing key or generates + stores a new one (app side, at push registration).
    @discardableResult
    public func loadOrCreatePrivateKey() -> P256.KeyAgreement.PrivateKey {
        if let key = loadPrivateKey() { return key }
        let key = P256.KeyAgreement.PrivateKey()
        var query = baseQuery
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = key.rawRepresentation
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
        return key
    }

    /// The device's static public key as base64 X9.63 (uncompressed point) for `POST /devices`.
    public func publicKeyBase64() -> String {
        loadOrCreatePrivateKey().publicKey.x963Representation.base64EncodedString()
    }
}
