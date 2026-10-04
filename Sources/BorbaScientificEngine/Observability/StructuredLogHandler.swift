import Foundation
import Logging
import Synchronization

/// Where finished log lines go.
protocol LogSink: Sendable {
    /// Writes one line, which has no trailing newline.
    ///
    /// - Parameter line: The line to write.
    func write(_ line: String)
}

/// Writes lines to standard output.
///
/// Every line is written with a single call while a lock is held, so lines from concurrent requests never interleave.
final class StandardOutputSink: LogSink {
    /// The sink shared by every handler of the process.
    static let shared = StandardOutputSink()

    private let lock = Mutex(())

    func write(_ line: String) {
        lock.withLock { _ in
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }
}

/// Writes each log event as one JSON object on one line, which is what log aggregators ingest.
///
/// ```json
/// {"timestamp":"2026-10-04T22:05:14.102Z","level":"info","logger":"codes.vapor.application","message":"Request completed","correlation_id":"…","duration_ms":1.2,"request_id":"…","status":201}
/// ```
///
/// The fixed fields come first, in a fixed order; everything else is flat metadata, sorted by key. Metadata is merged in
/// the order swift-log prescribes — the handler's own, then the metadata provider's (which adds the request and
/// correlation identifiers of the task that is logging), then the call's — and secrets are redacted on the way out.
struct StructuredLogHandler: LogHandler {
    /// Vapor's own request identifier, superseded by `request_id`, which every layer of this service uses.
    private static let droppedKeys: Set<String> = ["request-id"]

    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    var logLevel: Logger.Level

    private let label: String
    private let sink: any LogSink
    private let now: @Sendable () -> Date

    /// Creates a handler.
    ///
    /// - Parameters:
    ///   - label: The label of the logger, such as `codes.vapor.application`.
    ///   - level: The minimum level that is written.
    ///   - metadataProvider: Supplies metadata from the execution context, such as the trace identifiers.
    ///   - sink: Where lines are written.
    ///   - now: The time source of the `timestamp` field.
    init(
        label: String,
        level: Logger.Level,
        metadataProvider: Logger.MetadataProvider?,
        sink: any LogSink = StandardOutputSink.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.label = label
        self.logLevel = level
        self.metadataProvider = metadataProvider
        self.sink = sink
        self.now = now
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// Writes one event.
    ///
    /// - Parameter event: The event to write.
    func log(event: LogEvent) {
        var fields = metadata
        if let provided = metadataProvider?.get() {
            fields.merge(provided) { _, new in new }
        }
        if let explicit = event.metadata {
            fields.merge(explicit) { _, new in new }
        }

        sink.write(
            LogLine.render(
                LogRecord(
                    timestamp: Timestamp.format(now()),
                    level: event.level,
                    label: label,
                    message: event.message.description,
                    error: event.error.map { String(describing: type(of: $0)) },
                    fields: fields.filter { !Self.droppedKeys.contains($0.key) }
                )
            )
        )
    }
}

/// Everything one log line says.
struct LogRecord {
    /// When the event happened.
    let timestamp: String

    /// The severity.
    let level: Logger.Level

    /// The label of the logger.
    let label: String

    /// The message.
    let message: String

    /// The type of the error attached to the event, when there is one. Its contents are never written.
    let error: String?

    /// The metadata, already merged.
    let fields: Logger.Metadata
}

/// Builds the JSON text of a log line.
enum LogLine {
    private static let reservedKeys: Set<String> = ["timestamp", "level", "logger", "message", "error"]
    private static let reservedKeyPrefix = "meta_"

    /// Renders a line.
    ///
    /// - Parameter record: What the line says.
    /// - Returns: One JSON object, without a trailing newline.
    static func render(_ record: LogRecord) -> String {
        var members = [
            member("timestamp", JSONText.quoted(record.timestamp)),
            member("level", JSONText.quoted(record.level.rawValue)),
            member("logger", JSONText.quoted(record.label)),
            member("message", JSONText.quoted(LogRedaction.mask(record.message))),
        ]
        if let error = record.error {
            members.append(member("error", JSONText.quoted(error)))
        }

        for (key, value) in record.fields.sorted(by: { $0.key < $1.key }) {
            let name = reservedKeys.contains(key) ? reservedKeyPrefix + key : key
            members.append(member(name, render(value, key: key)))
        }
        return "{" + members.joined(separator: ",") + "}"
    }

    private static func member(
        _ key: String,
        _ value: String
    ) -> String {
        JSONText.quoted(key) + ":" + value
    }

    private static func render(
        _ value: Logger.MetadataValue,
        key: String
    ) -> String {
        guard !LogRedaction.isSensitive(key: key) else {
            return JSONText.quoted(LogRedaction.placeholder)
        }

        switch value {
        case .string(let text):
            return JSONText.quoted(LogRedaction.mask(text))
        case .stringConvertible(let convertible):
            return render(convertible)
        case .array(let elements):
            return "[" + elements.map { render($0, key: key) }.joined(separator: ",") + "]"
        case .dictionary(let entries):
            let members = entries.sorted(by: { $0.key < $1.key }).map { member($0.key, render($0.value, key: $0.key)) }
            return "{" + members.joined(separator: ",") + "}"
        }
    }

    /// Numbers and booleans stay numbers and booleans, so an aggregator can filter on `status >= 500`.
    private static func render(_ convertible: any CustomStringConvertible) -> String {
        switch convertible {
        case let number as Int:
            return String(number)
        case let number as Double where number.isFinite:
            return String(number)
        case let flag as Bool:
            return flag ? "true" : "false"
        default:
            return JSONText.quoted(LogRedaction.mask(convertible.description))
        }
    }
}

/// JSON string literals, written by hand so a log call never pays for an encoder.
enum JSONText {
    private static let controlCharacterLimit: UInt32 = 0x20
    private static let unicodeEscapeDigits = 4
    private static let hexadecimalRadix = 16

    /// Quotes and escapes text as a JSON string (RFC 8259 §7).
    ///
    /// - Parameter text: The text to quote.
    /// - Returns: The JSON string literal, quotes included.
    static func quoted(_ text: String) -> String {
        var result = "\""

        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            case _ where scalar.value < controlCharacterLimit:
                let digits = String(scalar.value, radix: hexadecimalRadix)
                result += "\\u" + String(repeating: "0", count: unicodeEscapeDigits - digits.count) + digits
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
