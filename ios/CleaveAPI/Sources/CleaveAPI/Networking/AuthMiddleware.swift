import Foundation
import OpenAPIRuntime
import HTTPTypes

/// Injects `Authorization: Bearer <token>` when a token is available, and is a no-op otherwise so
/// development against the default-open backend needs no token.
struct AuthMiddleware: ClientMiddleware {
    let tokenProvider: @Sendable () -> String?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let token = tokenProvider(), !token.isEmpty {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        return try await next(request, body, baseURL)
    }
}
