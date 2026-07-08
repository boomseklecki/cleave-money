import SwiftUI
import Foundation
import OpenAPIRuntime

private let unreachableMessage =
    "Couldn't reach the server. Make sure the backend is running and the base URL (Settings) is correct."

/// Converts a thrown error into a user-facing message, or `nil` when there's nothing to show (a cancelled
/// request - e.g. navigating away from an in-flight `.task` - isn't a failure). BackendError messages are
/// preferred; transport failures show a short "can't reach the server" note rather than a raw NSURLError.
func errorMessage(_ error: Error) -> String? {
    // The OpenAPI client wraps the real cause in a ClientError; unwrap to inspect it. A cancelled
    // request (navigating away from an in-flight .task) surfaces as either a CancellationError or
    // URLError.cancelled, directly or wrapped - none of which is a failure to show.
    let underlying = (error as? ClientError)?.underlyingError
    if error is CancellationError || underlying is CancellationError { return nil }
    if (error as? URLError)?.code == .cancelled || (underlying as? URLError)?.code == .cancelled { return nil }
    if let backend = error as? BackendError { return backend.errorDescription ?? "Request failed." }
    if error is URLError || underlying is URLError { return unreachableMessage }
    return error.localizedDescription
}

private struct ErrorAlertModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(
            "Something went wrong",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(message ?? "") }
        )
    }
}

extension View {
    /// Presents an alert whenever `message` is non-nil.
    func errorAlert(_ message: Binding<String?>) -> some View {
        modifier(ErrorAlertModifier(message: message))
    }
}
