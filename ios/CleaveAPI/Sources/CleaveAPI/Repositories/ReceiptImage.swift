import Foundation
import UIKit

/// Helpers for turning captured images into upload payloads. Receipts are stored as JPEG.
enum ReceiptImage {
    static let contentType = "image/jpeg"

    /// A timestamped, collision-resistant filename for an uploaded receipt.
    static func filename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "receipt-\(formatter.string(from: date)).jpg"
    }

    static func jpegData(_ image: UIImage, quality: CGFloat = 0.8) -> Data? {
        image.jpegData(compressionQuality: quality)
    }

    /// Re-encodes arbitrary picked image data (HEIC/PNG/...) as JPEG.
    static func jpegData(from data: Data, quality: CGFloat = 0.8) -> Data? {
        UIImage(data: data).flatMap { $0.jpegData(compressionQuality: quality) }
    }
}
