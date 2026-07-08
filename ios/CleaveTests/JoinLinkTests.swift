import XCTest
@testable import CleaveAPI

/// The shareable join link builder/parser + the "publicly reachable" check (so a link doesn't point at a
/// LAN-only backend).
final class JoinLinkTests: XCTestCase {
    func testURLRequiresANonEmptyBackend() {
        XCTAssertNil(JoinLink.url(apiBaseURL: "   ", name: "test"))
        XCTAssertNil(JoinLink.url(apiBaseURL: "", name: nil))
        XCTAssertNotNil(JoinLink.url(apiBaseURL: "https://api.example.com", name: nil))
    }

    func testURLParseRoundTrip() throws {
        let url = try XCTUnwrap(JoinLink.url(apiBaseURL: "https://api.example.com", name: "My Backend",
                                             invite: "abc123"))
        let parsed = JoinLink.parse(url)
        XCTAssertEqual(parsed?.api, "https://api.example.com")
        XCTAssertEqual(parsed?.invite, "abc123")
    }

    func testParseWithoutInvite() {
        let url = JoinLink.url(apiBaseURL: "https://api.example.com", name: nil)!
        XCTAssertEqual(JoinLink.parse(url)?.api, "https://api.example.com")
        XCTAssertNil(JoinLink.parse(url)?.invite)
    }

    func testParseRejectsOtherURLs() {
        XCTAssertNil(JoinLink.parse(URL(string: "https://cleave.money/other")!))
        XCTAssertNil(JoinLink.parse(URL(string: "https://example.com/join?api=x")!))
    }

    func testPubliclyReachable() {
        XCTAssertTrue(JoinLink.isPubliclyReachable("https://api.example.com"))
        XCTAssertFalse(JoinLink.isPubliclyReachable("http://localhost"))
        XCTAssertFalse(JoinLink.isPubliclyReachable("http://127.0.0.1"))
        XCTAssertFalse(JoinLink.isPubliclyReachable("http://192.168.1.5:8000"))
        XCTAssertFalse(JoinLink.isPubliclyReachable("http://10.0.0.1"))
        XCTAssertFalse(JoinLink.isPubliclyReachable("http://mymac.local"))
        XCTAssertFalse(JoinLink.isPubliclyReachable("https://server.lan"))
    }
}
