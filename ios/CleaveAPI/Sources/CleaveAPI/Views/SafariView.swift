import SwiftUI
import SafariServices

/// Presents a URL in an in-app Safari view (used for the backend-driven Splitwise OAuth login).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
