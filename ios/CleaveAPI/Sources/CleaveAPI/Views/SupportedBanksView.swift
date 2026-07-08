import SwiftUI

/// "Banks you can import from" - a searchable directory of institutions that support OFX file (Web Connect)
/// export, sourced from Intuit's FIDIR list via `GET /institutions`. Each row shows the bank's logo (through
/// the same `/logos/{domain}` proxy account rows use) and links to its site for export instructions. Read-only
/// discovery hung off the Import Statement flow.
struct SupportedBanksView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var query = ""
    @State private var results: [Components.Schemas.InstitutionResponse] = []
    @State private var searching = false
    @State private var errorText: String?

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    ContentUnavailableView("Find your bank", systemImage: "magnifyingglass",
                        description: Text("Search for a bank or card to see if it offers an OFX/QFX statement "
                                          + "you can export and import here."))
                }
            } else if results.isEmpty && !searching {
                Section {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                Section {
                    ForEach(results, id: \.name) { bank in bankRow(bank) }
                } footer: {
                    Text("Listed banks support OFX file (Web Connect) export. Open a bank to find its "
                         + "“Download/Export transactions” option, then import the .ofx file.")
                }
            }
        }
        .navigationTitle("Supported Banks")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Bank or card name")
        .toolbar { if searching { ToolbarItem(placement: .topBarTrailing) { ProgressView() } } }
        .task(id: query) { await runSearch() }
        .errorAlert($errorText)
    }

    @ViewBuilder
    private func bankRow(_ bank: Components.Schemas.InstitutionResponse) -> some View {
        let row = HStack(spacing: 12) {
            AvatarView(url: InstitutionBrand.logoURL(domain: bank.domain, name: bank.name),
                       name: bank.name, size: 36, logo: true)
            Text(bank.name).lineLimit(2)
            Spacer()
            if let url = URL(string: bank.home_url) {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
            }
        }
        row
    }

    /// Debounced search - wait briefly so we don't fire a request per keystroke; `.task(id: query)` cancels the
    /// in-flight task whenever the query changes.
    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        searching = true
        defer { searching = false }
        do {
            results = try await env.institutions.search(q)
        } catch is CancellationError {
            // superseded by a newer query - ignore
        } catch {
            errorText = errorMessage(error)
        }
    }
}
