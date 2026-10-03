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
enum Timestamp {
    /// Writes an instant with millisecond precision.
    ///
    /// - Parameter date: The instant to write.
    /// - Returns: The ISO 8601 text.
    static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Reads an instant written with or without fractional seconds.
    ///
    /// - Parameter text: The ISO 8601 text.
    /// - Returns: The instant, or `nil` when the text is not a valid ISO 8601 timestamp.
    static func parse(_ text: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let withoutFraction = Date.ISO8601FormatStyle()
        return (try? withFraction.parse(text)) ?? (try? withoutFraction.parse(text))
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
