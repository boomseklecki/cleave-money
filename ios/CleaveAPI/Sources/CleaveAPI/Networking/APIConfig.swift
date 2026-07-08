import Foundation

/// Backend connection configuration. Precedence: a runtime override (UserDefaults, set in Settings - 
/// also settable via a `-api_base_url <url>` launch argument) → the app's Info.plist `API_BASE_URL`
/// → the local default. Not hardcoded at call sites.
public enum APIConfig {
    static let defaultBaseURL = URL(string: "http://localhost:8000")!
    static let overrideKey = "api_base_url"

    public static var baseURL: URL {
        if let raw = UserDefaults.standard.string(forKey: overrideKey),
           !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
           let url = URL(string: raw) {
            return url
        }
        return defaultBaseURL
    }

    /// Persists a base-URL override (nil/empty clears it, reverting to the Info.plist default).
    static func setOverride(_ string: String?) {
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: overrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: overrideKey)
        }
    }
}
