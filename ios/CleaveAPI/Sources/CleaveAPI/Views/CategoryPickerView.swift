import SwiftUI
import SwiftData

/// A searchable category list - each row shows the category's icon next to its name. Reports the
/// chosen category via `onSelect`. Reads the synced, editable taxonomy from the cache.
struct CategoryPickerView: View {
    let current: String?
    /// When set, the source being mapped (a Bank/Splitwise label) - shown so you know what you're mapping.
    var subject: String? = nil
    /// When set, a subtle "Reset to Automatic" row appears - clears the caller's per-row category signal
    /// (override + AI refinement) so it falls back to the automatic category. Callers that have nothing to
    /// reset pass nil (the default) and the row is hidden. (Declared before `onSelect` so trailing-closure
    /// callers still bind to `onSelect`.)
    var onReset: (() -> Void)? = nil
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendCategory.position) private var categories: [SpendCategory]
    @State private var query = ""

    private var names: [String] {
        let all = categories.map(\.name)
        return query.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let subject {
                    Section {
                        HStack(spacing: 6) {
                            Text(subject).fontWeight(.semibold)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text("pick a category").foregroundStyle(.secondary)
                        }
                    }
                }
                if let onReset {
                    Section {
                        Button {
                            onReset()
                            dismiss()
                        } label: {
                            Label("Reset to Automatic", systemImage: "arrow.uturn.backward")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(names, id: \.self) { category in
                        Button {
                            onSelect(category)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: categorySymbol(category))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26)
                                Text(category).foregroundStyle(.primary)
                                Spacer()
                                if category == current {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search categories")
            .overlay {
                if categories.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle(subject.map { "Map “\($0)”" } ?? "Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// A circular, category-colored icon with a pencil badge - the shared "tap to recategorize" affordance used
/// by Find Related Transactions and the Inbox categorize confirm. Pair it with a `Button` that opens
/// `CategoryPickerView`.
struct CategoryAvatar: View {
    let category: String?
    /// Optional merchant favicon. When set and it loads, the favicon fills the tile with the category as a
    /// corner badge (via `AvatarView`); otherwise the plain colored category circle. No pencil affordance.
    var logoURL: String? = nil

    var body: some View {
        if let logoURL {
            AvatarView(url: logoURL, name: category ?? "", size: 64,
                       systemImage: categorySymbol(category), logo: true,
                       badgeSystemImage: categorySymbol(category), badgeColor: categoryColor(category))
        } else {
            Image(systemName: categorySymbol(category))
                .font(.title)
                .foregroundStyle(categoryColor(category))
                .frame(width: 64, height: 64)
                .background(categoryColor(category).opacity(0.15), in: Circle())
        }
    }
}
