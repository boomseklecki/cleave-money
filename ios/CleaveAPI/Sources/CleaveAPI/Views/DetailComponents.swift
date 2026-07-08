import SwiftUI

/// The 52×52 tappable category-icon button (with the pencil-edit overlay) shared by both detail headers.
/// `color == nil` leaves the symbol its default tint (the expense header's look); a color tints it (transaction).
/// When `logoURL` is set and the image loads, the merchant favicon fills the tile and the category symbol
/// moves to a small corner badge (matching the row avatars); loading/error/no-URL falls back to the symbol.
struct CategoryIconButton: View {
    let symbol: String
    let color: Color?
    var logoURL: String? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            tile
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tile: some View {
        if let logoURL, let url = URL(string: logoURL) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().padding(9)          // favicon on a white tile (matches rows)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) { categoryBadge }  // category cue in the bottom-trailing corner, matching every row avatar
                } else {
                    symbolTile                                          // loading/error → category symbol
                }
            }
        } else {
            symbolTile
        }
    }

    /// Category glyph as a small corner badge, drawn only when the favicon loaded (otherwise the tile already
    /// shows the category symbol). Mirrors the row avatar's badge: a system-background chip so it reads over
    /// the white logo tile, straddling the corner like a standard iOS status badge.
    private var categoryBadge: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color ?? .secondary)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color(.systemBackground)))
            .offset(x: 6, y: 6)                                         // straddle the bottom-trailing corner (as rows do)
    }

    private var symbolTile: some View {
        SwiftUI.Group {
            if let color {
                Image(systemName: symbol).font(.title2).foregroundStyle(color)
            } else {
                Image(systemName: symbol).font(.title2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The shared header for the transaction + expense detail screens: category-icon button, an amount hero row with
/// trailing action icons, then date / description / category+provenance. `actions` is the host's trailing button
/// cluster (txn: AI+Note+Receipt; expense: Note+Receipt).
struct DetailHeader<Actions: View>: View {
    let symbol: String
    let iconColor: Color?
    /// Optional merchant favicon for the leading tile; when it loads it replaces the category symbol.
    var logoURL: String? = nil
    let amount: String
    let date: String
    let description: String
    let category: String?
    let provenance: CategoryOrigin
    let inspector: String?
    let onCategoryTap: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            CategoryIconButton(symbol: symbol, color: iconColor, logoURL: logoURL, onTap: onCategoryTap)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 14) {
                    Text(amount).font(.title2).fontWeight(.semibold)
                    Spacer()
                    actions
                }
                Text(date).font(.caption).foregroundStyle(.secondary)
                Text(description).font(.body)
                HStack(spacing: 6) {
                    Text(category ?? "Uncategorized").font(.subheadline).foregroundStyle(.secondary)
                    CategoryProvenanceBadge(source: provenance)
                }
                if let inspector {
                    Text(inspector).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One line item (category glyph + name + category/owner subtitle + trailing price), shared by the transaction
/// and expense Items sections. `owner` (a display name) is shown only for expense items with a local assignee.
struct ItemListRow: View {
    let name: String
    let category: String?
    let owner: String?
    let price: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: categorySymbol(category))
                .foregroundStyle(categoryColor(category)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                HStack(spacing: 4) {
                    Text(category ?? "Uncategorized")
                    if let owner { Text("· \(owner)") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(price).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// The "Budget" section (Include in spending / cash flow) shared by both detail screens; only the footer differs.
struct BudgetFlagsSection: View {
    let includeInSpending: Binding<Bool>
    let includeInCashFlow: Binding<Bool>
    let footer: String

    var body: some View {
        Section {
            Toggle("Include in spending", isOn: includeInSpending)
            Toggle("Include in cash flow", isOn: includeInCashFlow)
        } header: {
            Text("Budget")
        } footer: {
            Text(footer)
        }
    }
}

// MARK: - Previews (presentational - inline data, no AppEnvironment/SwiftData needed)

#if DEBUG
#Preview("DetailHeader") {
    Form {
        Section {
            DetailHeader(symbol: "fork.knife", iconColor: .orange, amount: "$42.50", date: "Jun 30, 2026",
                         description: "Dinner at Luigi's", category: "Dining", provenance: .deterministic,
                         inspector: nil, onCategoryTap: {}) {
                Image(systemName: "sparkles")
                Image(systemName: "note.text")
                Image(systemName: "doc.text.image")
            }
            .foregroundStyle(.tint)
        }
    }
}

#Preview("ItemListRow") {
    List {
        ItemListRow(name: "Margherita Pizza", category: "Dining", owner: nil, price: "$18.00")
        ItemListRow(name: "House Wine", category: "Alcohol", owner: "Bob", price: "$12.00")
        ItemListRow(name: "Uncategorized thing", category: nil, owner: nil, price: "$4.00")
    }
}

#Preview("BudgetFlagsSection") {
    Form {
        BudgetFlagsSection(includeInSpending: .constant(true), includeInCashFlow: .constant(false),
                           footer: "Exclude a one-off (like a reimbursed purchase) from your spending totals.")
    }
}
#endif
