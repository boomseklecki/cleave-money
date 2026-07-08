import Foundation
import Vision
import UIKit

/// On-device OCR for receipt images using the Vision framework. Works in the simulator.
enum ReceiptOCR {
    enum OCRError: Error { case noImage }

    /// Recognizes text and returns it joined top-to-bottom (one line per observation).
    static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { throw OCRError.noImage }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                // Vision returns observations roughly bottom-to-top; sort by descending y so the
                // output reads top-to-bottom.
                let lines = observations
                    .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
