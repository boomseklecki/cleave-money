import Foundation

/// The server-managed merchant→logo (favicon) catalog. GET is readable by any enrolled member so the app can
/// resolve favicons; the replace-all PUT is admin-only. Editing happens in Server Settings → Brand Logos.
@MainActor
struct BrandOverridesRepository {
    let client: Client

    func get() async throws -> [Components.Schemas.BrandOverrideItem] {
        try await client.list_brand_overrides_brand_overrides_get().ok.body.json
    }

    @discardableResult
    func replace(
        _ items: [Components.Schemas.BrandOverrideItem]
    ) async throws -> [Components.Schemas.BrandOverrideItem] {
        try await client.replace_brand_overrides_brand_overrides_put(
            body: .json(.init(items: items))
        ).ok.body.json
    }
}
