import Foundation
import OpenAPIRuntime

/// Decodes ISO-8601 date-times with fractional seconds of any precision. The backend (Postgres/
/// FastAPI) emits microseconds (e.g. `2026-06-18T14:29:50.604204Z`), which the runtime's default
/// transcoder and `ISO8601FormatStyle` reject (they expect milliseconds). We normalize the fractional
/// part to 3 digits, then parse. Encodes with millisecond fractional seconds.
struct FlexibleDateTranscoder: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func decode(_ string: String) throws -> Date {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: Self.normalizeFractionalSeconds(string)) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) {
            return date
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Expected an ISO-8601 date, got \"\(string)\"")
        )
    }

    /// Trims/pads the fractional-seconds digits to exactly 3 so `ISO8601DateFormatter` accepts them.
    /// `...:50.604204Z` → `...:50.604Z`; leaves strings without fractional seconds untouched.
    static func normalizeFractionalSeconds(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        var index = string.index(after: dot)
        var digits = ""
        while index < string.endIndex, string[index].isNumber {
            digits.append(string[index])
            index = string.index(after: index)
        }
        guard !digits.isEmpty else { return string }
        let milliseconds = (digits + "000").prefix(3)
        return string[..<dot] + "." + milliseconds + string[index...]
    }
}
