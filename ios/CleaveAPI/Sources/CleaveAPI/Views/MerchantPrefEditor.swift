import SwiftUI

/// The shared editor for a single merchant preference, so the Merchant Preferences manager row and the
/// find-related "Merchant Preferences" section stay visually in line. Layout: the website favicon avatar and
/// the brand name inline, then the category (tap to pick) above the website, the regex pattern, and the amount
/// type + amount. The avatar mirrors the rest of the app (favicon -> category icon -> initials, with the
/// category as a corner badge once the favicon loads).
struct MerchantPrefEditor: View {
    @Binding var name: String
    @Binding var website: String
    @Binding var pattern: String
    @Binding var amountModeRaw: String
    @Binding var amountStr: String
    let category: String?
    /// Opens the caller's category picker (each screen wires its own).
    var onPickCategory: () -> Void
    /// Fired on any field edit (dirty/save-state tracking).
    var onChange: () -> Void = {}

    var body: some View {
        let site = website.trimmingCharacters(in: .whitespaces)
        let hasCategory = !(category ?? "").isEmpty
        let catSymbol = hasCategory ? categorySymbol(category) : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onPickCategory) {
                    AvatarView(
                        url: site.isEmpty ? nil : Brand(name: "", domain: site).logoURL,
                        name: name.isEmpty ? pattern : name,
                        size: 40,
                        systemImage: catSymbol,              // category icon fallback, else initials
                        logo: true,
                        badgeSystemImage: catSymbol,         // category badge once the favicon loads
                        badgeColor: categoryColor(category))
                }
                .buttonStyle(.plain)
                TextField("Brand name / note", text: $name).font(.headline)
            }
            if let cat = category, !cat.isEmpty {
                Button(action: onPickCategory) {
                    Text(cat).font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            TextField("Website (e.g. duolingo.com)", text: $website)
                .font(.subheadline).foregroundStyle(.secondary)
                .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
            RegexPatternTextField(text: $pattern)
            Picker("Amount", selection: $amountModeRaw) {
                ForEach(RelatedTransactions.AmountMatch.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if amountModeRaw != RelatedTransactions.AmountMatch.any.rawValue {
                TextField("Amount", text: $amountStr).keyboardType(.decimalPad)
            }
        }
        .onChange(of: name) { onChange() }
        .onChange(of: website) { onChange() }
        .onChange(of: pattern) { onChange() }
        .onChange(of: amountModeRaw) { onChange() }
        .onChange(of: amountStr) { onChange() }
    }
}
