import XCTest
import UIKit
@testable import CleaveAPI

final class ReceiptImageTests: XCTestCase {
    func testFilenameFormat() {
        let date = Date(timeIntervalSince1970: 0)  // 1970-01-01 00:00:00 UTC
        XCTAssertEqual(ReceiptImage.filename(date: date), "receipt-19700101-000000-000.jpg")
    }

    func testJpegConversionFromImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let data = ReceiptImage.jpegData(image)
        XCTAssertNotNil(data)
        XCTAssertFalse(data?.isEmpty ?? true)
    }

    func testJpegReencodeFromDataAndRejectsGarbage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        XCTAssertNotNil(ReceiptImage.jpegData(from: image.pngData()!))
        XCTAssertNil(ReceiptImage.jpegData(from: Data([0, 1, 2])))
    }
}
