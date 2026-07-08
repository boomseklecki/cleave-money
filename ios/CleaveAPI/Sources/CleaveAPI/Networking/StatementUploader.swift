import Foundation

/// Uploads raw OFX bytes to `{base}/statements/import` using the shared base URL + token
/// (`SharedImportConfig`). Used by the Share Extension, which can't pull in the generated API client - a tiny
/// `URLSession` POST instead. (The in-app import path uses the app's own client.)
public enum StatementUploader {
    public struct Result: Decodable, Sendable {
        public let account_name: String
        public let imported: Int
        public let skipped: Int
        public let total: Int
    }

    public enum UploadError: Error { case notConfigured, badURL, server(Int), decode }

    public static func upload(ofx data: Data) async throws -> Result {
        guard let base = SharedImportConfig.baseURL() else { throw UploadError.notConfigured }
        let joined = base.hasSuffix("/") ? base + "statements/import" : base + "/statements/import"
        guard let url = URL(string: joined) else { throw UploadError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-ofx", forHTTPHeaderField: "Content-Type")
        if let token = SharedImportConfig.token(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")  // omitted for open backends
        }
        req.httpBody = data

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UploadError.server(-1) }
        guard (200..<300).contains(http.statusCode) else { throw UploadError.server(http.statusCode) }
        guard let result = try? JSONDecoder().decode(Result.self, from: respData) else { throw UploadError.decode }
        return result
    }
}
