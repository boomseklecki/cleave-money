import XCTest
import OpenAPIRuntime
import HTTPTypes
@testable import CleaveAPI

/// The response middleware maps non-2xx backend responses to `BackendError` (so repositories only handle the
/// success path). Drives `intercept` with a synthetic upstream response.
final class ResponseErrorMiddlewareTests: XCTestCase {
    private let mw = ResponseErrorMiddleware()
    private let req = HTTPRequest(method: .post, scheme: "https", authority: "api", path: "/x")
    private let url = URL(string: "https://api")!

    private func run(status: Int, body: HTTPBody? = nil, operationID: String = "op") async throws -> (HTTPResponse, HTTPBody?) {
        try await mw.intercept(req, body: nil, baseURL: url, operationID: operationID) { _, _, _ in
            (HTTPResponse(status: .init(code: status)), body)
        }
    }

    /// Asserts `run` throws a `BackendError` satisfying `check`.
    private func assertThrows(status: Int, body: HTTPBody? = nil, _ check: (BackendError) -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await run(status: status, body: body)
            XCTFail("expected a thrown BackendError for \(status)", file: file, line: line)
        } catch let error as BackendError {
            check(error)
        } catch {
            XCTFail("threw a non-BackendError: \(error)", file: file, line: line)
        }
    }

    func testPassesThrough2xx() async throws {
        let (response, _) = try await run(status: 200)
        XCTAssertEqual(response.status.code, 200)
    }

    func testMaps422WithBodyToValidation() async {
        let json = #"{"detail":[{"loc":["body","amount"],"msg":"must be positive","type":"value_error"}]}"#
        await assertThrows(status: 422, body: HTTPBody(Array(json.utf8))) {
            guard case .validation = $0 else { return XCTFail("expected .validation, got \($0)") }
        }
    }

    func testMaps422WithoutBodyToDefaultValidation() async {
        await assertThrows(status: 422) { XCTAssertEqual($0, .validation("Validation failed.")) }
    }

    func testMaps409ToConflict() async {
        await assertThrows(status: 409) {
            guard case .conflict = $0 else { return XCTFail("expected .conflict, got \($0)") }
        }
    }

    func testMaps502ToUpstream() async {
        await assertThrows(status: 502) {
            guard case .upstream = $0 else { return XCTFail("expected .upstream, got \($0)") }
        }
    }

    func testMaps404ToNotFound() async {
        await assertThrows(status: 404) { XCTAssertEqual($0, .notFound) }
    }

    func testMaps500ToHTTP() async {
        await assertThrows(status: 500) { XCTAssertEqual($0, .http(500)) }
    }

    func testAuthEndpointsPassThroughOnError() async throws {
        // Sign-in endpoints map their own AuthError in AuthService - the middleware must not hijack them.
        let (response, _) = try await run(status: 422, operationID: "auth_apple_auth_apple_post")
        XCTAssertEqual(response.status.code, 422)
    }
}
