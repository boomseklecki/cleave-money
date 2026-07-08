import Foundation

extension Collection where Element == User {
    /// The title-cased display name for a person identifier, falling back to the title-cased
    /// identifier when the user isn't in the directory. Use wherever a `userIdentifier` slug would
    /// otherwise be shown (group members, split rows).
    func displayName(for identifier: String) -> String {
        first { $0.identifier == identifier }?.displayName.titleCased ?? identifier.titleCased
    }

    /// The avatar URL for a person identifier, or nil when the user isn't in the directory or has none.
    func avatarURL(for identifier: String) -> String? {
        first { $0.identifier == identifier }?.avatarURL
    }
}
