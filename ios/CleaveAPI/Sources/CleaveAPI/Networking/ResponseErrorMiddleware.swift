import Foundation
import OpenAPIRuntime
import HTTPTypes

/// Maps non-2xx backend responses to `BackendError` centrally, so repositories only handle the success path
/// (via the generated throwing accessors) instead of repeating the `.unprocessableContent` / `.undocumented`
/// arms at ~75 call sites. A 422 body (FastAPI validation) is parsed into a message; every other code maps via
/// `BackendError.fromUndocumented` (409→conflict, 502→upstream, 404→notFound, else→http). 2xx passes through
/// untouched so the generated client decodes it as usual.
struct ResponseErrorMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        let code = response.status.code
        guard code >= 400 else { return (response, responseBody) }
        // The sign-in endpoints map their own `AuthError` in AuthService - don't hijack them into BackendError.
        guard !operationID.hasPrefix("auth_") else { return (response, responseBody) }
        if code == 422 {
            var parsed: Components.Schemas.HTTPValidationError?
            if let responseBody, let data = try? await Data(collecting: responseBody, upTo: 64 * 1024) {
                parsed = try? JSONDecoder().decode(Components.Schemas.HTTPValidationError.self, from: data)
            }
            throw BackendError.validation(BackendError.validationMessage(parsed))
        }
        throw BackendError.fromUndocumented(code)
    }
}
