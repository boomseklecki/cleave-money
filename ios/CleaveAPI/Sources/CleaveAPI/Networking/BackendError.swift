import Foundation

/// User-facing error mapped from the backend's documented (422) and undocumented (409/502/...) responses.
/// 422 = split imbalance or a participant missing a Splitwise link; 409 = no Splitwise token / conflict;
/// 502 = upstream Splitwise rejected or unreachable.
enum BackendError: Error, LocalizedError, Equatable {
    case validation(String)
    case conflict(String)
    case upstream(String)
    case notFound
    case http(Int)

    var errorDescription: String? {
        switch self {
        case let .validation(message): return message
        case let .conflict(message): return message
        case let .upstream(message): return message
        case .notFound: return "Not found."
        case let .http(code): return "Request failed (HTTP \(code))."
        }
    }

    /// Maps an undocumented status code (409/502/...) to a friendly error.
    static func fromUndocumented(_ statusCode: Int) -> BackendError {
        switch statusCode {
        case 409: return .conflict("Connect Splitwise before pushing expenses (no stored token).")
        case 502: return .upstream("Splitwise rejected the change or was unreachable. Try again.")
        case 404: return .notFound
        default: return .http(statusCode)
        }
    }

    /// Joins FastAPI validation messages from a 422 body into one string.
    static func validationMessage(_ error: Components.Schemas.HTTPValidationError?) -> String {
        guard let details = error?.detail, !details.isEmpty else { return "Validation failed." }
        return details.map(\.msg).joined(separator: "\n")
    }
}
