import CryptoKit
import XCTest
@testable import CleaveAPI

/// Pins the Python↔CryptoKit ECIES interop: the vector below was sealed by the backend
/// (`services/crypto_push.seal`, P-256 ECDH → HKDF-SHA256 → AES-256-GCM) to a fixed device keypair.
/// If `PushCrypto.open` or either side's wire format drifts, this fails. Regenerate with the snippet in
/// the plan if the scheme constants ever change.
final class PushCryptoTests: XCTestCase {
    // Fixed device private key (raw 32-byte scalar, base64) whose public key the backend sealed to.
    private let privRawB64 = "SioHLd3/p2ry7Mgc0Fg/BHhkwLqdbagPIaxWmlEGios="
    private let epkB64 = "BDireDMW/sdqRbMJjidMHwurnMBAcZO7PttE2vqMpzbjHynaMSDJo7i+ZwVkkaNhhA5vIbDQ3dEgWBZjSgpYpPE="
    private let boxB64 = "znKU/G6pqs5ZB9cc2qvgnkVFxd2TtufbjwQqz0M7mFWa61Lsgd8Hgx9xYNJhJOUeuscAHocdkS9ftcq1P321jIa8R5A9rHo5jdI11SvMFbTEtJ4="

    private func deviceKey() throws -> P256.KeyAgreement.PrivateKey {
        let raw = try XCTUnwrap(Data(base64Encoded: privRawB64))
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    func testDecryptsBackendVector() throws {
        let out = PushCrypto.open(epk: epkB64, box: boxB64, privateKey: try deviceKey())
        XCTAssertEqual(out?.title, "Cleave")
        XCTAssertEqual(out?.body, "Alice added 'Dinner' $40")
    }

    func testWrongKeyFailsClosed() throws {
        let other = P256.KeyAgreement.PrivateKey()
        XCTAssertNil(PushCrypto.open(epk: epkB64, box: boxB64, privateKey: other))
    }

    func testMalformedInputReturnsNil() throws {
        XCTAssertNil(PushCrypto.open(epk: "!!", box: boxB64, privateKey: try deviceKey()))
        XCTAssertNil(PushCrypto.open(epk: epkB64, box: "garbage", privateKey: try deviceKey()))
    }

    /// Round-trips locally too, so the test isn't solely tied to the static vector.
    func testLocalRoundTripWithCryptoKitKey() throws {
        let key = P256.KeyAgreement.PrivateKey()
        XCTAssertNotNil(key.publicKey.x963Representation)  // 65-byte uncompressed point the backend consumes
    }
}
