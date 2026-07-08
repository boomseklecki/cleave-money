import Foundation

/// Model-free parsing of receipt OCR text, used when FoundationModels is unavailable. Pure, so it's
/// unit-testable.
enum ReceiptHeuristics {
    struct Result: Equatable {
        var merchant: String?
        var date: Date?
        var total: Decimal?
    }

    private static let amountRegex = try! NSRegularExpression(pattern: #"\d[\d,]*\.\d{2}"#)

    static func parse(_ text: String) -> Result {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Result(merchant: merchant(lines), date: date(in: text), total: total(lines))
    }

    static func merchant(_ lines: [String]) -> String? {
        lines.first
    }

    static func total(_ lines: [String]) -> Decimal? {
        // Prefer a "total" line (excluding "subtotal"); else the largest amount anywhere.
        let totalLines = lines.filter {
            let l = $0.lowercased()
            return l.contains("total") && !l.contains("subtotal")
        }
        if let best = totalLines.flatMap(amounts(in:)).max() { return best }
        return lines.flatMap(amounts(in:)).max()
    }

    static func date(in text: String) -> Date? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.date
    }

    private static func amounts(in line: String) -> [Decimal] {
        let ns = line as NSString
        return amountRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap {
            let raw = ns.substring(with: $0.range).replacingOccurrences(of: ",", with: "")
            return Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
        }
    }
}
