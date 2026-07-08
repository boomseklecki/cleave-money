import XCTest
@testable import CleaveAPI

/// Covers the note-first merchant→favicon resolution behind `MerchantAvatar` (via
/// `BrandModel.logoURL(note:merchant:)`). Deterministic: uses only the offline
/// `BrandCatalog`, never the on-device model, so it runs anywhere.
@MainActor
final class MerchantAvatarTests: XCTestCase {
    private func model() -> BrandModel { BrandModel() }

    /// Known brand → a `/logos/{domain}` URL (this is what warms the proxy cache).
    func testKnownMerchantYieldsLogoURL() {
        let url = model().logoURL(note: nil, merchant: "NETFLIX.COM 866-579-7172 CA")
        XCTAssertEqual(url, APIConfig.baseURL.appendingPathComponent("logos/netflix.com").absoluteString)
    }

    /// Unknown merchant with no on-device model → nil, so the row keeps its category icon.
    func testUnknownMerchantYieldsNil() {
        XCTAssertNil(model().logoURL(note: nil, merchant: "SQ *SOME OBSCURE CAFE"))
    }

    /// Note-first precedence: a brand note beats the merchant string.
    func testNoteBeatsMerchant() {
        // Merchant resolves to Apple; the note names a different brand → the note wins.
        let url = model().logoURL(note: "Netflix", merchant: "APPLE.COM/BILL")
        XCTAssertEqual(url, APIConfig.baseURL.appendingPathComponent("logos/netflix.com").absoluteString)
    }

    /// A freeform note that names no brand falls through to the merchant's resolution (never blank/broken).
    func testNonBrandNoteFallsThroughToMerchant() {
        let url = model().logoURL(note: "dinner with mom", merchant: "APPLE.COM/BILL")
        XCTAssertEqual(url, APIConfig.baseURL.appendingPathComponent("logos/apple.com").absoluteString)
    }

    /// No note + unresolvable merchant → nil (category-icon fallback), and an empty note is ignored.
    func testEmptyNoteIsIgnored() {
        let known = model().logoURL(note: "   ", merchant: "Spotify")
        XCTAssertEqual(known, APIConfig.baseURL.appendingPathComponent("logos/spotify.com").absoluteString)
    }
}
