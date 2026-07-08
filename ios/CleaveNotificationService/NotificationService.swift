import UserNotifications

/// Decrypts E2E push payloads on-device so the relay (and Apple) never see the content. The backend seals
/// `{title, body}` to this device's public key and the relay delivers ciphertext + a generic fallback alert
/// (`mutable-content`). We read the matching private key from the shared App Group Keychain and decrypt; on
/// any failure (no key, malformed, auth) we leave the fallback alert in place.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = request.content.mutableCopy() as? UNMutableNotificationContent
        bestAttempt = content

        if let content,
           let e2e = request.content.userInfo["e2e"] as? [String: String],
           let epk = e2e["epk"], let box = e2e["box"],
           let privateKey = PushKeychain.shared.loadPrivateKey(),
           let decrypted = PushCrypto.open(epk: epk, box: box, privateKey: privateKey) {
            content.title = decrypted.title
            content.body = decrypted.body
            if let target = decrypted.target { content.userInfo["target"] = target }  // for the tap handler
        }
        contentHandler(content ?? request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt { contentHandler(bestAttempt) }
    }
}
