import Foundation

/// Session gate for preference pushes. No store may back up (`Preferences.put` / `CategorySync` PUT) until this
/// session's launch restore (`bootstrapPreferences`) has run its `applyIfNewer` sweep. Reset by
/// `eraseLocalCache`. This enforces the invariant "a not-yet-restored device never overwrites the server",
/// closing the clobber where a wiped/reduced device pushed its local set over the fuller server copy and
/// destroyed it (categories + merchant/subscription prefs, 2026-07-07). A gated push returns "not written",
/// so the store stays dirty and retries once the restore lands.
@MainActor
enum PreferenceSyncGate {
    private(set) static var restored = false
    static func markRestored() { restored = true }
    static func reset() { restored = false }
}

/// Thin wrapper over the per-owner preferences endpoints (`GET /preferences`, `PUT /preferences/{key}`).
/// Each preference is an opaque, app-versioned JSON string scoped to the caller - the backup channel for
/// locally-authoritative settings (categories, tab order, ...). One `fetchAll` serves every consumer on launch.
enum Preferences {
    /// Every preference blob for the caller, keyed by name. Best-effort: returns empty on any failure
    /// (offline, or a backend without the endpoint).
    @MainActor
    static func fetchAll(_ client: Client) async -> [String: (value: String, updatedAt: Date)] {
        guard let rows = try? await client.list_preferences_preferences_get().ok.body.json else { return [:] }
        return Dictionary(rows.map { ($0.key, ($0.value, $0.updated_at)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Store one preference blob; returns the server `updated_at` on success (for the local watermark).
    @MainActor
    @discardableResult
    static func put(_ key: String, _ value: String, client: Client) async -> Date? {
        guard PreferenceSyncGate.restored else { return nil }  // never push before this session's restore ran
        return try? await client.upsert_preference_preferences__key__put(
            path: .init(key: key), body: .json(.init(value: value))).ok.body.json.updated_at
    }
}
