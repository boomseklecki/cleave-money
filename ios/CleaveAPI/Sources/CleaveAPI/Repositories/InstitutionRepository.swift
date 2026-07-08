import Foundation

/// Searches the OFX-importable institution directory (Intuit FIDIR Web Connect banks). Reference data - 
/// transient API objects the directory screen holds in view state.
@MainActor
struct InstitutionRepository {
    let client: Client

    func search(_ query: String, limit: Int = 50) async throws -> [Components.Schemas.InstitutionResponse] {
        let output = try await client.list_institutions_institutions_get(query: .init(q: query, limit: limit))
        let ok = try output.ok
        return try ok.body.json
    }
}
