import Foundation
import AuthenticationServices
import UIKit

/// Active-window helpers for presenting auth UI from SwiftUI.
@MainActor
enum AppPresentation {
    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Runs an `ASWebAuthenticationSession` and returns the callback URL. Used for the Splitwise OAuth flow,
/// whose backend callback 302s to `cleave://auth?token=<jwt>`.
@MainActor
final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    static func start(url: URL, callbackScheme: String) async throws -> URL {
        try await WebAuth().run(url: url, scheme: callbackScheme)
    }

    private func run(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: AuthError.invalidResponse)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AuthError.failed("Couldn't start web sign-in."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        AppPresentation.keyWindow() ?? ASPresentationAnchor()
    }
}
