import Foundation

/// The one place that decides how JSON is written and read, so every response and every request body follow the
/// same rules.
enum JSONCoding {
    /// Creates an encoder with deterministic output: keys are sorted, so the same value always produces the same
    /// bytes, which makes responses diffable and golden tests stable.
    ///
    /// A new encoder is created per use because encoders are mutable reference types.
    ///
    /// - Returns: A configured encoder.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Creates a decoder for request bodies.
    ///
    /// - Returns: A configured decoder.
    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

/// Wall-clock instants as the API writes and reads them: ISO 8601 in UTC, such as `2026-10-03T12:00:00.123Z`.
///
/// Both directions work on whole microseconds, the resolution of the database, and never on a floating-point number of
/// seconds: a double cannot hold most millisecond values exactly, and formatting it directly would print `.122` for an
/// instant that was stored as `.123`.
enum Timestamp {
    private static let microsecondsPerSecond: Int64 = 1_000_000
    private static let microsecondsPerMillisecond: Int64 = 1_000
    private static let fractionWidth = 3
    private static let zuluSuffix = "Z"
    private static let fractionSeparator = "."
    private static let zeroPadding = "0"

    /// Writes an instant with millisecond precision, truncating anything finer.
    ///
    /// - Parameter date: The instant to write.
    /// - Returns: The ISO 8601 text.
    static func format(_ date: Date) -> String {
        let microseconds = Int64((date.timeIntervalSince1970 * Double(microsecondsPerSecond)).rounded())

        var seconds = microseconds / microsecondsPerSecond
        var remainder = microseconds % microsecondsPerSecond
        if remainder < 0 {
            remainder += microsecondsPerSecond
            seconds -= 1
        }

        let wholeSeconds = Date(timeIntervalSince1970: Double(seconds)).formatted(Date.ISO8601FormatStyle())
        let milliseconds = String(remainder / microsecondsPerMillisecond)
        let fraction = String(repeating: zeroPadding, count: fractionWidth - milliseconds.count) + milliseconds

        return wholeSeconds.dropLast(zuluSuffix.count) + fractionSeparator + fraction + zuluSuffix
    }

    /// Reads an instant written with or without fractional seconds, of any precision up to nanoseconds.
    ///
    /// - Parameter text: The ISO 8601 text, in UTC (`Z`) or with an offset.
    /// - Returns: The instant, or `nil` when the text is not a valid ISO 8601 timestamp.
    static func parse(_ text: String) -> Date? {
        guard let match = text.wholeMatch(of: #/^(.+T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$/#) else {
            return nil
        }

        let withoutFraction = String(match.output.1) + String(match.output.3)
        guard let base = try? Date.ISO8601FormatStyle().parse(withoutFraction) else {
            return nil
        }
        guard let digits = match.output.2 else {
            return base
        }
        return Double(zeroPadding + fractionSeparator + digits).map { base.addingTimeInterval($0) }
    }
}

extension Duration {
    private static let millisecondsPerSecond = 1_000.0
    private static let attosecondsPerMillisecond = 1_000_000_000_000_000.0

    /// The duration in milliseconds, with the fractional part that sub-millisecond calculations need.
    var totalMilliseconds: Double {
        Double(components.seconds) * Self.millisecondsPerSecond
            + Double(components.attoseconds) / Self.attosecondsPerMillisecond
    }
}
