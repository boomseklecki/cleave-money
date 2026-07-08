import SwiftUI

/// Admin editor for the server-managed merchant to logo (favicon) catalog. Loads `GET /brand-overrides`, saves
/// the full list via the replace-all `PUT`. Each row is a favicon preview + a display name, its website, and a
/// match pattern (substring, `*`/`?` glob, or `/regex/`). Order matters: the app resolves a merchant/note to
/// the first row whose pattern matches, so a broad pattern must sit below a more specific one. Reachable from
/// Server Settings; the whole screen is behind the admin-only Server Settings link.
struct BrandCatalogView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var items: [EditableBrand] = []
    @State private var loaded = false
    @State private var saving = false
    @State private var saved = false
    @State private var errorText: String?

    private struct EditableBrand: Identifiable {
        let id = UUID()
        var pattern: String
        var name: String
        var domain: String

        init(pattern: String, name: String, domain: String) {
            self.pattern = pattern; self.name = name; self.domain = domain
        }
        init(_ i: Components.Schemas.BrandOverrideItem) {
            self.init(pattern: i.pattern, name: i.name, domain: i.domain ?? "")
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach($items) { $item in
                    row($item)
                }
                .onDelete { items.remove(atOffsets: $0) }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }

                Button {
                    withAnimation { items.append(.init(pattern: "", name: "", domain: "")) }
                } label: {
                    Label("Add brand", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Brands")
            } footer: {
                Text("The pattern is matched (case-insensitive) inside a merchant name or your note. Plain text "
                     + "is a substring (netflix). Use * for any characters (apple*bill) and ? for one character "
                     + "(giant?eagle), or wrap a regular expression in slashes (/aldi|lidl/). The website drives "
                     + "the logo via this server's /logos proxy; leave it blank for a name with no logo. The "
                     + "first matching row wins, so drag broader patterns lower.")
            }

            Section {
                Button {
                    withAnimation { items = BrandCatalog.builtins.map {
                        .init(pattern: $0.pattern, name: $0.brand.name, domain: $0.brand.domain ?? "")
                    } }
                } label: {
                    Label("Load built-in defaults", systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text("Replaces the list above with the app's shipped set. Nothing is saved until you tap Save.")
            }

            Section {
                Button { save() } label: {
                    Label(saving ? "Saving…" : (saved ? "Saved" : "Save Changes"),
                          systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
                .disabled(saving || !loaded)
            }
        }
        .navigationTitle("Brand Logos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .errorAlert($errorText)
        .task { if !loaded { await load() } }
    }

    @ViewBuilder
    private func row(_ item: Binding<EditableBrand>) -> some View {
        let domain = item.wrappedValue.domain.trimmingCharacters(in: .whitespaces)
        let patternInvalid = !item.wrappedValue.pattern.isEmpty
            && !BrandMatcher.isValid(item.wrappedValue.pattern)
        HStack(alignment: .center, spacing: 12) {
            AvatarView(
                url: Brand(name: item.wrappedValue.name, domain: domain.isEmpty ? nil : domain).logoURL,
                name: item.wrappedValue.name.isEmpty ? item.wrappedValue.pattern : item.wrappedValue.name,
                size: 44,
                systemImage: "tag.fill",
                logo: true
            )
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: item.name)
                    .font(.headline)
                TextField("website.com", text: item.domain)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                HStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                    TextField("Pattern (netflix, apple*bill, /aldi|lidl/)", text: item.pattern)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    if patternInvalid {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func load() async {
        do { items = try await env.brandOverrides.get().map(EditableBrand.init); loaded = true }
        catch { errorText = errorMessage(error) }
    }

    private func save() {
        saving = true
        saved = false
        Task {
            defer { saving = false }
            let payload = items.compactMap { row -> Components.Schemas.BrandOverrideItem? in
                let pattern = row.pattern.trimmingCharacters(in: .whitespaces)
                let name = row.name.trimmingCharacters(in: .whitespaces)
                guard !pattern.isEmpty, !name.isEmpty else { return nil }   // drop blank/incomplete rows
                return .init(pattern: pattern, name: name,
                             domain: row.domain.trimmingCharacters(in: .whitespaces))
            }
            do {
                let result = try await env.brandOverrides.replace(payload)
                BrandCatalogStore.shared.apply(result)   // reflect the saved catalog app-wide immediately
                items = result.map(EditableBrand.init)
                saved = true
            } catch { errorText = errorMessage(error) }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { BrandCatalogView() }
        .previewEnvironment()
}
#endif
