import Foundation

/// Bridges the UIKit app-delegate push callbacks (which can't see the SwiftUI environment) to
/// `AppEnvironment`. The delegate calls `received(token:)` when APNs hands over the device token;
/// `AppEnvironment` sets `onToken` to forward it to the backend.
@MainActor
public final class PushTokenStore {
    public static let shared = PushTokenStore()
    private init() {}

    /// The latest APNs device token (hex), if registration has completed.
    public private(set) var token: String?
    /// Set by `AppEnvironment` to forward a newly-received token to `POST /devices`.
    public var onToken: ((String) -> Void)?

    public func received(token: String) {
        self.token = token
        onToken?(token)
    }
}
