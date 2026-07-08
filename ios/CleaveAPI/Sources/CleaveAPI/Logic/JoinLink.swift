import Foundation

/// Builds the shareable join link (`https://cleave.money/join?api=<backend>&name=<label>`) that sets
/// up Cleave on another device against this backend. Opens the app via the `applinks:cleave.money`
/// Universal Link (or the web confirm page if the app isn't installed).
enum JoinLink {
    static func url(apiBaseURL: String, name: String?, invite: String? = nil) -> URL? {
        let trimmed = apiBaseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://cleave.money/join")
        var items = [URLQueryItem(name: "api", value: trimmed)]
        if let name, !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
        if let invite, !invite.isEmpty { items.append(URLQueryItem(name: "invite", value: invite)) }
        components?.queryItems = items
        return components?.url
    }

    /// Parses an inbound join link (`https://cleave.money/join?api=...[&invite=...]`, or the `cleave://join`
    /// scheme) into the backend URL + optional single-use invite. Returns nil for any other URL.
    static func parse(_ url: URL) -> (api: String, invite: String?)? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let isJoin = (comps.host == "cleave.money" && comps.path == "/join")
            || (url.scheme == "cleave" && (comps.host == "join" || comps.path.hasSuffix("join")))
        guard isJoin else { return nil }
        let items = comps.queryItems ?? []
        guard let api = items.first(where: { $0.name == "api" })?.value, !api.isEmpty else { return nil }
        let invite = items.first(where: { $0.name == "invite" })?.value
        return (api, (invite?.isEmpty == false) ? invite : nil)
    }

    /// Whether a base URL is publicly reachable (so the link works off the local network). Loopback and
    /// `.local`/`.lan` hosts only resolve on the same network.
    static func isPubliclyReachable(_ apiBaseURL: String) -> Bool {
        guard let host = URLComponents(string: apiBaseURL)?.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" { return false }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") { return false }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.") { return false }
        return true
    }
}
