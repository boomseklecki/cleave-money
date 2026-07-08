import XCTest
import OpenAPIRuntime
@testable import CleaveAPI

final class ErrorAlertTests: XCTestCase {
    private func clientError(_ underlying: Error) -> ClientError {
        ClientError(operationID: "list_expenses_expenses_get", operationInput: "",
                    causeDescription: "Unknown", underlyingError: underlying)
    }

    /// Cancelled requests (navigating away from an in-flight .task) must not surface an alert - directly
    /// or wrapped in the OpenAPI ClientError (the form actually seen: ClientError(... CancellationError())).
    func testCancellationIsSilent() {
        XCTAssertNil(errorMessage(CancellationError()))
        XCTAssertNil(errorMessage(URLError(.cancelled)))
        XCTAssertNil(errorMessage(clientError(CancellationError())))
        XCTAssertNil(errorMessage(clientError(URLError(.cancelled))))
    }

    func testWrappedTransportFailureShowsUnreachable() {
        XCTAssertTrue(errorMessage(clientError(URLError(.timedOut)))?.lowercased().contains("reach") == true)
    }

    /// Real transport failures still show the "can't reach the server" note.
    func testRealTransportFailuresShowUnreachable() {
        for code in [URLError.Code.timedOut, .cannotConnectToHost, .notConnectedToInternet,
                     .networkConnectionLost] {
            let message = errorMessage(URLError(code))
            XCTAssertNotNil(message)
            XCTAssertTrue(message?.lowercased().contains("reach") == true, "code \(code)")
        }
    }

    func testBackendErrorKeepsItsMessage() {
        XCTAssertEqual(errorMessage(BackendError.validation("Bad split")), "Bad split")
    }
}
