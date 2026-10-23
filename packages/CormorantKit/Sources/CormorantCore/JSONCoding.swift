import Foundation

/// JSON coders shared by the on-disk stores.
///
/// Dates are written as `timeIntervalSinceReferenceDate` doubles, which round-trip a `Date` exactly
/// (ISO 8601 strings truncate to milliseconds, so a reloaded value no longer compared equal).
/// On read, numbers are taken as reference-date intervals and, for files written by earlier builds,
/// ISO 8601 strings with or without fractional seconds are accepted.
enum CoreJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let interval = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: interval)
            }
            let string = try container.decode(String.self)
            if let date = try? fractionalISO8601.parse(string) { return date }
            if let date = try? wholeSecondISO8601.parse(string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected a reference-date interval or an ISO 8601 date, got \(string)")
        }
        return decoder
    }

    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondISO8601 = Date.ISO8601FormatStyle()
}
