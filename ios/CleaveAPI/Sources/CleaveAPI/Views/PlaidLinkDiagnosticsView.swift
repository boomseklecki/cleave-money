import SwiftUI
import UIKit

/// Shows the most recent failed Plaid Link attempt's diagnostics (link token + session/request ids + error)
/// with Share / Copy / Clear, so it can be handed to Plaid support. Reached from Settings → Plaid.
struct PlaidLinkDiagnosticsView: View {
    @State private var store = PlaidLinkDiagnosticsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        List {
            if let d = store.last {
                Section {
                    field("Institution", d.institutionName)
                    field("Link Session ID", d.linkSessionID)
                    field("Request ID", d.requestID)
                    field("Status", d.status)
                    field("Error Code", d.errorCode)
                    field("Error Message", d.errorMessage)
                    field("Display Message", d.displayMessage)
                    LabeledContent("Captured",
                                   value: d.capturedAt.formatted(date: .abbreviated, time: .standard))
                } footer: {
                    Text("Send these to Plaid support to investigate a failed bank link "
                         + "(link_session_id and request_id are the key fields).")
                }

                if !d.events.isEmpty {
                    Section("Link Events") {
                        ForEach(Array(d.events.enumerated()), id: \.offset) { _, event in
                            Text(event).font(.caption2).monospaced().textSelection(.enabled)
                        }
                    }
                }

                Section("Link Token") {
                    Text(d.linkToken).font(.caption2).textSelection(.enabled)
                }

                Section {
                    ShareLink(item: d.shareText) {
                        Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = d.shareText
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Diagnostics", systemImage: "doc.on.doc")
                    }
                    Button("Clear", role: .destructive) { store.clear(); dismiss() }
                }
            } else {
                ContentUnavailableView("No Link Errors", systemImage: "checkmark.seal",
                    description: Text("Diagnostics from a failed bank link will appear here."))
            }
        }
        .navigationTitle("Link Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) {
                Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
            }
        }
    }
}
