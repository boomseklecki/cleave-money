import Foundation

/// Bridges a tapped push notification into the SwiftUI root: the app-target `PushAppDelegate` parses the
/// notification's `userInfo["target"]` and sets `pending`; `RootView` presents the target's detail as a
/// modal. Mirrors `PlaidLinkSession.shared` - a shared observable the UIKit delegate can poke. Routing via a
/// root modal sidesteps the per-tab NavigationStacks.
@MainActor
@Observable
public final class DeepLinkRouter {
    public static let shared = DeepLinkRouter()
    private init() {}

    var pending: NotificationTarget?

    /// Set from a tapped push's decrypted target (`{type, id}`). No-op when the payload has no/invalid target.
    public func set(type: String?, id: String?) {
        if let target = NotificationTarget(type: type, id: id) { pending = target }
    }
}
