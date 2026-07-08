import Foundation

/// Normalizing a raw merchant/description string into brand-bearing words, a token set, and a stable grouping
/// key. Used app-wide (brand resolution, related-item grouping, subscription/recurring detection, split
/// templates), so it lives here rather than inside any one consumer.
enum MerchantText {
    /// Merchant tokens that carry no brand signal (payment plumbing / geography / suffixes).
    private static let noise: Set<String> = [
        "com", "www", "http", "https", "inc", "llc", "ltd", "co", "corp",
        "pos", "purchase", "recurring", "payment", "autopay", "auto", "bill",
        "online", "usa", "the", "subscription", "monthly", "annual",
    ]

    /// A stable grouping key from a merchant string: lowercase, letters only, noise/short words dropped, first
    /// few significant words joined (e.g. "Netflix.com 866-579-7172 CA" -> "netflix").
    static func key(_ details: String) -> String {
        words(details).prefix(3).joined(separator: " ")
    }

    /// The brand-bearing words of a merchant string, in order: lowercased, letters only, with noise and short
    /// (<3 char) words dropped.
    static func words(_ details: String) -> [String] {
        details.lowercased()
            .map { ($0.isLetter || $0 == " ") ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
            .filter { $0.count >= 3 && !noise.contains($0) }
    }

    /// The unordered set of significant words - for fuzzy "same merchant?" overlap checks.
    static func tokens(_ details: String) -> Set<String> { Set(words(details)) }
}
