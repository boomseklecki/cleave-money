import Foundation
import FoundationModels

/// Runs on-device structured extraction with Apple's FoundationModels. Gracefully reports
/// unavailability (ineligible device, Apple Intelligence off, model still downloading, or simulator)
/// so callers can fall back to `ReceiptHeuristics`.
struct ReceiptExtractor {
    enum ExtractionError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            if case let .unavailable(reason) = self { return reason }
            return nil
        }
    }

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var unavailableReason: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return ""
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible: return "This device doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings to use AI extraction."
            case .modelNotReady: return "The on-device model is still downloading. Try again shortly."
            @unknown default: return "On-device AI is unavailable."
            }
        @unknown default:
            return "On-device AI is unavailable."
        }
    }

    func extract(from ocrText: String, categories: [String] = []) async throws -> ReceiptExtraction {
        guard isAvailable else { throw ExtractionError.unavailable(unavailableReason) }
        var instructions = """
        You extract structured data from the OCR text of a shopping receipt. Identify the merchant \
        name, the purchase date (format YYYY-MM-DD), the grand total as a number, and the line items \
        with their prices.
        """
        if !categories.isEmpty {
            instructions += "\nPrefer one of these categories when it fits: \(categories.joined(separator: ", "))."
        }
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: ocrText, generating: ReceiptExtraction.self)
        return response.content
    }
}
