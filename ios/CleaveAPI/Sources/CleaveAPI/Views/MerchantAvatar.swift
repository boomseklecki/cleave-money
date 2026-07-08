import SwiftUI

/// Leading avatar for a transaction/expense row: the row's cached favicon from the self-hosted
/// `/logos/{domain}` proxy when it resolves to a brand domain, otherwise the category SF Symbol.
///
/// Resolution is **note-first**: the user's per-row note override wins over the merchant string, so a
/// "Duolingo" note on an `APPLE.COM/BILL` charge shows Duolingo's favicon, not Apple's. Falls back to the
/// merchant, then to the category icon. Domain resolution reuses `Brand` (the app's existing
/// merchant→domain scheme); requesting the logo URL is what warms the proxy cache. The list owns the shared
/// `BrandModel` and runs one resolve pass - rows only read from it, so nothing async fires here.
struct MerchantAvatar: View {
    let merchant: String          // transaction.details / expense.details
    var note: String? = nil       // user's per-row note override (transaction_overrides / expense.note)
    let category: String?
    var size: CGFloat = 30
    var amount: Decimal? = nil    // the charge amount, for amount-scoped brand overrides
    var brandModel: BrandModel   // shared, injected by the list

    var body: some View {
        AvatarView(
            url: brandModel.logoURL(note: note, merchant: merchant, amount: amount),  // nil until a domain is known → fallback
            name: merchant,
            size: size,
            systemImage: categorySymbol(category),       // category icon as the *main* fallback
            logo: true,                                  // white tile for transparent favicons
            badgeSystemImage: categorySymbol(category),  // same icon, as a corner badge *when the favicon loads*
            badgeColor: categoryColor(category)
        )
    }
}
