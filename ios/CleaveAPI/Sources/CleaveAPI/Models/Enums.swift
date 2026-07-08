import Foundation

/// Backend that owns a group. Raw values match the API (`self_hosted` | `splitwise`).
enum BackendType: String, Codable, CaseIterable, Sendable {
    case selfHosted = "self_hosted"
    case splitwise = "splitwise"
}

/// Origin of a transaction. Raw values match the API (`plaid` | `manual`).
enum TransactionSource: String, Codable, CaseIterable, Sendable {
    case plaid = "plaid"
    case manual = "manual"
    case simplefin = "simplefin"
}

/// Where a user/person record came from. Raw values match the API.
/// `app` = a household member with an API token; `manual` = added in-app; `splitwise` = imported.
enum UserSource: String, Codable, CaseIterable, Sendable {
    case app = "app"
    case manual = "manual"
    case splitwise = "splitwise"
}
