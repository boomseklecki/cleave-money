import UIKit
import UserNotifications
import CleaveAPI

/// Bridges APNs registration (a UIKit app-delegate concern) into the SwiftUI app via `PushTokenStore`.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil)
        -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushTokenStore.shared.received(token: hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// Show notifications while the app is foregrounded.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound, .badge] }

    /// A tapped notification: route to its deep-link target (the NSE decrypted it into `userInfo["target"]`).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let target = response.notification.request.content.userInfo["target"] as? [String: String]
        await DeepLinkRouter.shared.set(type: target?["type"], id: target?["id"])
    }
}
