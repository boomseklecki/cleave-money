import XCTest
@testable import CleaveAPI

final class DateTranscoderTests: XCTestCase {
    private let transcoder = FlexibleDateTranscoder()

    func testDecodesMicrosecondTimestamp() throws {
        // The backend emits microsecond precision; the default transcoder rejects this.
        let date = try transcoder.decode("2026-06-18T14:29:50.604204Z")
        let expected = try transcoder.decode("2026-06-18T14:29:50.604Z")
        XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.0005)
    }

    func testDecodesWithoutFractionalSeconds() throws {
        let date = try transcoder.decode("2026-06-18T14:29:50Z")
        XCTAssertTrue(try transcoder.encode(date).hasPrefix("2026-06-18T14:29:50"))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try transcoder.decode("not-a-date"))
    }

    func testNormalizePadsAndTrims() {
        XCTAssertEqual(FlexibleDateTranscoder.normalizeFractionalSeconds("2026-06-18T14:29:50.604204Z"),
                       "2026-06-18T14:29:50.604Z")
        XCTAssertEqual(FlexibleDateTranscoder.normalizeFractionalSeconds("2026-06-18T14:29:50.6Z"),
                       "2026-06-18T14:29:50.600Z")
        XCTAssertEqual(FlexibleDateTranscoder.normalizeFractionalSeconds("2026-06-18T14:29:50Z"),
                       "2026-06-18T14:29:50Z")
    }
}
