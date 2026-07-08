import CryptoKit
import Foundation

/// ECIES decryption for E2E-encrypted push payloads, matching the backend's `services/crypto_push.seal`
/// (P-256 ECDH → HKDF-SHA256 → AES-256-GCM). Pure and testable - the private key is injected, so this is
/// pinned against the backend by a committed interop test vector (see `PushCryptoTests`). The notification
/// service extension calls `open` with the device's static key from `PushKeychain`.
public enum PushCrypto {
    // Must byte-match the backend constants in `crypto_push.py`.
    static let salt = Data("Cleave-push-v1".utf8)
    static let info = Data("Cleave-push-v1".utf8)

    /// Decrypts a sealed `{title, body[, target]}` payload. `epk`/`box` are base64; returns nil on any
    /// malformed input or authentication failure (the extension then leaves the generic fallback alert in
    /// place). `target` is the optional deep-link payload (`{type, id}`) the extension surfaces into userInfo.
    public static func open(epk: String, box: String, privateKey: P256.KeyAgreement.PrivateKey)
        -> (title: String, body: String, target: [String: String]?)? {
        guard let epkData = Data(base64Encoded: epk), let boxData = Data(base64Encoded: box),
              let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: epkData),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: ephemeral) else { return nil }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info,
                                                 outputByteCount: 32)
        guard let sealedBox = try? AES.GCM.SealedBox(combined: boxData),       // nonce‖ciphertext‖tag
              let plaintext = try? AES.GCM.open(sealedBox, using: key),
              let obj = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let title = obj["title"] as? String, let body = obj["body"] as? String else { return nil }
        return (title, body, obj["target"] as? [String: String])
    }
}
