import XCTest
@testable import CleaveAPI

@MainActor
final class PlaidLinkDiagnosticsTests: XCTestCase {
    /// A store backed by a throwaway UserDefaults suite, so tests don't touch the app's `.standard`.
    private func freshStore() -> (PlaidLinkDiagnosticsStore, UserDefaults, String) {
        let suite = "test.plaiddiag.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PlaidLinkDiagnosticsStore(defaults: defaults, key: "diag"), defaults, suite)
    }

    func testRecordPersistsAndReloads() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(store.last)

        let d = PlaidLinkDiagnostics(linkToken: "link-production-abc", linkSessionID: "ls-1",
                                     requestID: "req-1", institutionName: "PNC",
                                     errorCode: "institutionError", errorMessage: "Access Denied")
        store.record(d)
        XCTAssertEqual(store.last, d)

        // A fresh store over the same defaults reloads what was persisted.
        let reloaded = PlaidLinkDiagnosticsStore(defaults: defaults, key: "diag")
        XCTAssertEqual(reloaded.last?.linkSessionID, "ls-1")
        XCTAssertEqual(reloaded.last?.requestID, "req-1")
        XCTAssertTrue(reloaded.last?.isError ?? false)
    }

    func testClearEmptiesStoreAndDefaults() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.record(PlaidLinkDiagnostics(linkToken: "tok"))
        store.clear()
        XCTAssertNil(store.last)
        XCTAssertNil(PlaidLinkDiagnosticsStore(defaults: defaults, key: "diag").last)
    }

    func testShareTextIncludesKeyFieldsAndEvents() {
        let d = PlaidLinkDiagnostics(linkToken: "tok", linkSessionID: "ls-9", requestID: "rq-9",
                                     errorMessage: "denied",
                                     events: ["OPEN", "OPEN_OAUTH view=CONNECTED", "ERROR error=denied"])
        let text = d.shareText
        XCTAssertTrue(text.contains("link_session_id: ls-9"))
        XCTAssertTrue(text.contains("request_id: rq-9"))
        XCTAssertTrue(text.contains("link_token: tok"))
        XCTAssertFalse(text.contains("display_message"))  // omitted when nil
        XCTAssertTrue(text.contains("events:"))
        XCTAssertTrue(text.contains("OPEN_OAUTH view=CONNECTED"))
    }

    func testCleanCancelIsNotError() {
        XCTAssertFalse(PlaidLinkDiagnostics(linkToken: "tok").isError)
        XCTAssertTrue(PlaidLinkDiagnostics(linkToken: "tok", errorMessage: "x").isError)
    }
}
