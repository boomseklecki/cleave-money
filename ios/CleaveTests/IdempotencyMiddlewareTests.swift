import XCTest
import OpenAPIRuntime
import HTTPTypes
@testable import CleaveAPI

/// The idempotency middleware injects `Idempotency-Key` only when a create repository has put a key in scope
/// via the `IdempotencyContext` task-local - and never leaks it onto other requests. Drives `intercept` with
/// a stub `next` that captures the outgoing request's headers.
final class IdempotencyMiddlewareTests: XCTestCase {
    private let mw = IdempotencyMiddleware()
    private let req = HTTPRequest(method: .post, scheme: "https", authority: "api", path: "/expenses")
    private let url = URL(string: "https://api")!
    private let header = HTTPField.Name("Idempotency-Key")!

    /// Runs the middleware and returns the `Idempotency-Key` the transport would have seen.
    private func sentKey() async throws -> String? {
        var captured: String?
        _ = try await mw.intercept(req, body: nil, baseURL: url, operationID: "create_expense_expenses_post") {
            request, body, base in
            captured = request.headerFields[self.header]
            return (HTTPResponse(status: .ok), body)
        }
        return captured
    }

    func testInjectsKeyWhenInScope() async throws {
        let key = try await IdempotencyContext.$key.withValue("abc-123") { try await sentKey() }
        XCTAssertEqual(key, "abc-123")
    }

    func testNoHeaderWhenNoKeyInScope() async throws {
        let key = try await sentKey()  // task-local defaults to nil
        XCTAssertNil(key)
    }

    func testNoHeaderForEmptyKey() async throws {
        let key = try await IdempotencyContext.$key.withValue("") { try await sentKey() }
        XCTAssertNil(key)
    }

    func testKeyDoesNotLeakOutsideScope() async throws {
        _ = try await IdempotencyContext.$key.withValue("scoped") { try await sentKey() }
        let after = try await sentKey()  // outside the withValue - must be gone
        XCTAssertNil(after)
    }
}
