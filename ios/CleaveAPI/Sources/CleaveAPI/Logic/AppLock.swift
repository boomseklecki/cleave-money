import Foundation
import LocalAuthentication

/// Local app lock via Face ID / Touch ID, falling back to the device passcode
/// (`.deviceOwnerAuthentication`). A privacy gate over the already-saved session - it never touches
/// sign-in or the stored token.
enum AppLock {
    /// `@AppStorage` key for the user's "require lock" preference (shared by the gate and Settings).
    static let enabledKey = "app.lockEnabled"

    /// Whether the device can authenticate the owner (a passcode is set / biometrics enrolled).
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Prompts for Face ID / passcode. Returns whether the owner authenticated. A fresh `LAContext`
    /// per call so each unlock is its own evaluation.
    static func authenticate(reason: String = "Unlock Cleave") async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
