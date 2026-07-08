import UIKit
import UniformTypeIdentifiers

/// Receives an OFX statement shared from the Wallet app (or Files) and uploads it to the user's backend via
/// `StatementUploader` - so the import happens without opening the app. Shows the result inline.
final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let doneButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        status.numberOfLines = 0
        status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .headline)
        status.text = "Importing statement…"

        doneButton.setTitle("Done", for: .normal)
        doneButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        doneButton.isHidden = true

        let stack = UIStackView(arrangedSubviews: [spinner, status, doneButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        spinner.startAnimating()

        Task { await run() }
    }

    private func run() async {
        do {
            let data = try await loadOFXData()
            let result = try await StatementUploader.upload(ofx: data)
            let n = result.imported
            finish("Imported \(n) transaction\(n == 1 ? "" : "s") into \(result.account_name).")
        } catch {
            finish(message(for: error), isError: true)
        }
    }

    private func loadOFXData() async throws -> Data {
        guard let provider = (extensionContext?.inputItems.first as? NSExtensionItem)?.attachments?.first else {
            throw StatementUploader.UploadError.decode
        }
        let type = ["money.cleave.ofx", UTType.data.identifier]
            .first { provider.hasItemConformingToTypeIdentifier($0) } ?? UTType.data.identifier
        return try await withCheckedThrowingContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if let url, let data = try? Data(contentsOf: url) { cont.resume(returning: data) }
                else { cont.resume(throwing: error ?? StatementUploader.UploadError.decode) }
            }
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case StatementUploader.UploadError.notConfigured:
            return "Open Cleave and sign in once, then try again."
        case StatementUploader.UploadError.server(let code):
            return "The server rejected the statement (error \(code))."
        default:
            return "Couldn’t import this statement."
        }
    }

    private func finish(_ message: String, isError: Bool = false) {
        spinner.stopAnimating()
        status.text = message
        status.textColor = isError ? .systemRed : .label
        doneButton.isHidden = false
    }

    @objc private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
