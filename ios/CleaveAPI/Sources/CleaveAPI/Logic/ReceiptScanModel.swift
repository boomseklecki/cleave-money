import SwiftUI
import UIKit
import Observation

/// Orchestrates the scan→OCR→extract pipeline off the UI and produces a `ExpensePrefill` + the JPEG
/// bytes for the new-expense editor. Falls back to `ReceiptHeuristics` when the on-device model is
/// unavailable or extraction fails.
@MainActor
@Observable
final class ReceiptScanModel {
    var isScanning = false
    var prefill: ExpensePrefill?
    var imageData: Data?
    var presentEditor = false
    var infoMessage: String?
    var errorText: String?

    func process(image: UIImage, categories: [String]) async {
        isScanning = true
        defer { isScanning = false }
        imageData = ReceiptImage.jpegData(image)

        let text: String
        do {
            text = try await ReceiptOCR.recognizeText(in: image)
        } catch {
            errorText = errorMessage(error)
            return
        }

        let extractor = ReceiptExtractor()
        if extractor.isAvailable {
            do {
                prefill = await .from(try await extractor.extract(from: text, categories: categories),
                                      categories: categories)
            } catch {
                prefill = .from(ReceiptHeuristics.parse(text))
                infoMessage = "AI extraction failed; used a quick scan — please double-check."
            }
        } else {
            prefill = .from(ReceiptHeuristics.parse(text))
            infoMessage = extractor.unavailableReason
        }
        presentEditor = true
    }
}
