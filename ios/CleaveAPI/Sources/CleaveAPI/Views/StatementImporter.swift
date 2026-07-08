import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// OFX statement import as a reusable modifier: a file picker → `POST /statements/import`, with the "this card
/// looks already linked via Plaid → Import anyway" confirmation. Adopted by the Accounts list, Linked Banks, and
/// Settings so the duplicate-prompt logic lives in exactly one place. The host owns `isPresented` and decides how
/// to surface the result summary via `onImported`.
struct StatementImporter: ViewModifier {
    @Binding var isPresented: Bool
    var onImported: (String) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var pendingImport: PendingImport?
    @State private var errorText: String?

    /// An OFX import the server flagged as a likely Plaid duplicate - stashed so "Import anyway" re-sends the
    /// same bytes (force) without re-prompting the file picker.
    private struct PendingImport: Identifiable { let id = UUID(); let data: Data; let accountName: String }

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented,
                          allowedContentTypes: [UTType(filenameExtension: "ofx") ?? .data]) { importStatement($0) }
            .confirmationDialog(
                "Already linked via Plaid?",
                isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
                titleVisibility: .visible
            ) {
                Button("Import anyway", role: .destructive) { if let p = pendingImport { forceImport(p) } }
            } message: {
                Text(pendingImport.map {
                    "This card looks already linked via Plaid as “\($0.accountName)”. Importing makes a separate, "
                    + "duplicate account that double-counts in spending."
                } ?? "")
            }
            .errorAlert($errorText)
    }

    private func importStatement(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let r = try await env.statements(context).importOFX(data)
                if r.plaid_conflict == true {
                    pendingImport = PendingImport(data: data, accountName: r.account_name)  // confirm, then force
                } else {
                    onImported(importedSummary(r))
                }
            } catch { errorText = errorMessage(error) }
        }
    }

    private func forceImport(_ p: PendingImport) {
        pendingImport = nil
        Task {
            do { onImported(importedSummary(try await env.statements(context).importOFX(p.data, force: true))) }
            catch { errorText = errorMessage(error) }
        }
    }

    private func importedSummary(_ r: Components.Schemas.StatementImportResult) -> String {
        "Imported \(r.imported.formatted()) of \(r.total.formatted()) "
            + "transaction\(r.total == 1 ? "" : "s") into \(r.account_name)."
    }
}

extension View {
    /// Attach the OFX statement importer (file picker + Plaid-duplicate confirmation). `onImported` receives the
    /// result summary string; the host displays it however it likes.
    func statementImporter(isPresented: Binding<Bool>, onImported: @escaping (String) -> Void) -> some View {
        modifier(StatementImporter(isPresented: isPresented, onImported: onImported))
    }
}
