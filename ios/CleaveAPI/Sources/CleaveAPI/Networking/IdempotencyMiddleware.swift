import Foundation
import OpenAPIRuntime
import HTTPTypes

/// Task-local carrier for a client-supplied `Idempotency-Key`. A create repository sets it around the POST
/// (via `IdempotencyContext.$key.withValue(...)`); `IdempotencyMiddleware` reads it and adds the header.
/// Task-local (not a stored property) so the value is scoped to exactly that one async call and never leaks
/// onto other requests sharing the client.
enum IdempotencyContext {
    @TaskLocal static var key: String?
}

/// Adds `Idempotency-Key: <key>` when a create repository has put one in scope, so a retried create
/// (double-tap, or a retry after a lost response where the server actually committed) collapses to one row - 
/// and, for a Splitwise expense, one `push_create` - server-side (audit High #9). A no-op for every request
/// with no key in scope, which is all reads/updates/deletes.
struct IdempotencyMiddleware: ClientMiddleware {
    private static let headerName = HTTPField.Name("Idempotency-Key")!

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let key = IdempotencyContext.key, !key.isEmpty {
            request.headerFields[Self.headerName] = key
        }
        return try await next(request, body, baseURL)
    }
}
