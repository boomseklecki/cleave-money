import Foundation

/// Troubleshooting data captured from a failed/aborted Plaid Link attempt - the link token plus the
/// session/request ids and error LinkKit returns on exit. Surfaced in Settings → Plaid so it can be shared
/// with Plaid support (e.g. to investigate a bank's "Access Denied" OAuth rejection).
struct PlaidLinkDiagnostics: Codable, Equatable {
    var capturedAt: Date
    var linkToken: String
    var linkSessionID: String?
    var requestID: String?
    var institutionName: String?
    var institutionID: String?
    var status: String?
    var errorCode: String?
    var errorMessage: String?
    var displayMessage: String?
    /// The LinkKit event trail for the session (e.g. OPEN → OPEN_OAUTH → TRANSITION_VIEW → ERROR), which
    /// pinpoints where an OAuth flow died after the redirect.
    var events: [String]

    init(capturedAt: Date = Date(), linkToken: String, linkSessionID: String? = nil,
         requestID: String? = nil, institutionName: String? = nil, institutionID: String? = nil,
         status: String? = nil, errorCode: String? = nil, errorMessage: String? = nil,
         displayMessage: String? = nil, events: [String] = []) {
        self.capturedAt = capturedAt
        self.linkToken = linkToken
        self.linkSessionID = linkSessionID
        self.requestID = requestID
        self.institutionName = institutionName
        self.institutionID = institutionID
        self.status = status
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.displayMessage = displayMessage
        self.events = events
    }

    /// Whether the exit carried an actual error (vs a plain user cancel with no error).
    var isError: Bool { errorCode != nil || errorMessage != nil }

    /// A labeled, support-ready text block to copy/share.
    var shareText: String {
        var lines = ["Cleave — Plaid Link diagnostics",
                     "captured: \(capturedAt.formatted(date: .abbreviated, time: .standard))"]
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { lines.append("\(label): \(value)") }
        }
        add("institution", institutionName)
        add("institution_id", institutionID)
        add("link_session_id", linkSessionID)
        add("request_id", requestID)
        add("status", status)
        add("error_code", errorCode)
        add("error_message", errorMessage)
        add("display_message", displayMessage)
        add("link_token", linkToken)
        if !events.isEmpty {
            lines.append("events:")
            lines.append(contentsOf: events.map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

/// Persists the most recent Plaid Link attempt's diagnostics (UserDefaults-backed so it survives the app
/// termination an OAuth round-trip can cause). A singleton for the app; constructible with a custom
/// `UserDefaults` for tests.
@MainActor
@Observable
final class PlaidLinkDiagnosticsStore {
    static let shared = PlaidLinkDiagnosticsStore()

    private let defaults: UserDefaults
    private let key: String
    private(set) var last: PlaidLinkDiagnostics?

    init(defaults: UserDefaults = .standard, key: String = "plaid.lastLinkDiagnostics") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key) {
            last = try? JSONDecoder().decode(PlaidLinkDiagnostics.self, from: data)
        }
    }

    func record(_ diagnostics: PlaidLinkDiagnostics) {
        last = diagnostics
        if let data = try? JSONEncoder().encode(diagnostics) {
            defaults.set(data, forKey: key)
        }
    }

    func clear() {
        last = nil
        defaults.removeObject(forKey: key)
    }
}
