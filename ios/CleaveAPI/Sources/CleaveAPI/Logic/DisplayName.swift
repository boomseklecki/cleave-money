import Foundation

extension String {
    /// Title-cases a name only when it has no capitals already - fixes lowercase imports like
    /// "alice" → "Alice" while leaving already-cased names ("John McDonald") untouched.
    var titleCased: String {
        contains(where: \.isUppercase) ? self : capitalized
    }
}
