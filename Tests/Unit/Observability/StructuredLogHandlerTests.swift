import BorbaScientificCore
import Foundation
import Logging
import Synchronization
import TestSupport
import Testing

@testable import BorbaScientificEngine

/// Collects the lines a handler writes.
final class MemorySink: LogSink {
    private let storage = Mutex<[String]>([])

    var lines: [String] {
        storage.withLock { $0 }
    }

    func write(_ line: String) {
        storage.withLock { $0.append(line) }
    }

    /// The only line written, parsed as JSON.
    func onlyLine() throws -> CalculationValue {
        let all = lines
        try #require(all.count == 1)
        return try JSONDecoder().decode(CalculationValue.self, from: Data(all[0].utf8))
    }
}

@Suite("StructuredLogHandler")
struct StructuredLogHandlerTests {
    private static let fixedInstant = Date(timeIntervalSince1970: 1_791_028_800.123)

    private func logger(
        sink: MemorySink,
        level: Logger.Level = .trace,
        provider: Logger.MetadataProvider? = nil
    ) -> Logger {
        Logger(label: "test.logger") { _ in
            StructuredLogHandler(
                label: "test.logger",
                level: level,
                metadataProvider: provider,
                sink: sink,
                now: { Self.fixedInstant }
            )
        }
    }

    @Test("writes one JSON object per event, with the fixed fields first and in a fixed order")
    func fixedFields() throws {
        let sink = MemorySink()

        logger(sink: sink).info("Hello", metadata: ["b": "2", "a": "1"])

        let expected =
            #"{"timestamp":"2026-10-03T12:00:00.123Z","level":"info","logger":"test.logger","message":"Hello","#
            + #""a":"1","b":"2"}"#
        #expect(sink.lines == [expected])
    }

    @Test("merges metadata in the order the handler, the provider and the call")
    func mergeOrder() throws {
        let sink = MemorySink()
        var log = logger(
            sink: sink,
            provider: Logger.MetadataProvider { ["layer": "provider", "kept": "provider"] }
        )
        log[metadataKey: "layer"] = "handler"
        log[metadataKey: "only_handler"] = "yes"

        log.info("Merged", metadata: ["layer": "call"])
        let line = try sink.onlyLine()

        #expect(line.at("layer") == "call")
        #expect(line.at("kept") == "provider")
        #expect(line.at("only_handler") == "yes")
    }

    @Test("adds the request and correlation identifiers of the task that is logging")
    func traceProvider() async throws {
        let sink = MemorySink()
        let log = logger(sink: sink, provider: .trace)
        let context = TraceContext(requestID: RequestID("req-7"), correlationID: CorrelationID("corr-7"))

        log.info("Outside")
        await TraceContext.withValue(context) {
            log.info("Inside")
        }
        let lines = try sink.lines.map { try JSONDecoder().decode(CalculationValue.self, from: Data($0.utf8)) }

        #expect(lines[0].at("request_id") == nil)
        #expect(lines[1].at("request_id") == "req-7")
        #expect(lines[1].at("correlation_id") == "corr-7")
    }

    @Test("keeps numbers and booleans as such, and nests dictionaries and arrays")
    func typedValues() throws {
        let sink = MemorySink()

        logger(sink: sink).info(
            "Typed",
            metadata: [
                "status": .stringConvertible(201),
                "duration_ms": .stringConvertible(1.5),
                "replayed": .stringConvertible(true),
                "not_finite": .stringConvertible(Double.infinity),
                "tags": ["a", "b"],
                "nested": ["inner": "x"],
            ]
        )
        let line = try sink.onlyLine()

        #expect(line.at("status") == 201)
        #expect(line.at("duration_ms") == 1.5)
        #expect(line.at("replayed") == true)
        #expect(line.at("not_finite") == "inf")
        #expect(line.at("tags", 1) == "b")
        #expect(line.at("nested", "inner") == "x")
    }

    @Test(
        "writes valid JSON whatever the text contains",
        arguments: [
            "quote \" backslash \\ slash /",
            "line\nbreak\r\ttab",
            "control \u{0001}\u{001F} and \u{007F}",
            "unicode: café — 日本語 🙂",
            "",
        ]
    )
    func escaping(text: String) throws {
        let sink = MemorySink()

        logger(sink: sink).info("\(text)", metadata: ["value": "\(text)"])
        let line = try sink.onlyLine()

        #expect(line.at("message")?.text == text)
        #expect(line.at("value")?.text == text)
    }

    @Test("prefixes metadata keys that collide with the fixed fields")
    func reservedKeys() throws {
        let sink = MemorySink()

        logger(sink: sink).info("Real message", metadata: ["message": "from metadata", "level": "from metadata"])
        let line = try sink.onlyLine()

        #expect(line.at("message") == "Real message")
        #expect(line.at("level") == "info")
        #expect(line.at("meta_message") == "from metadata")
        #expect(line.at("meta_level") == "from metadata")
    }

    @Test("drops Vapor's own request identifier, which request_id supersedes")
    func dropsVaporsRequestIdentifier() throws {
        let sink = MemorySink()

        logger(sink: sink).info("Hi", metadata: ["request-id": "vapor-own", "request_id": "ours"])
        let line = try sink.onlyLine()

        #expect(line.at("request-id") == nil)
        #expect(line.at("request_id") == "ours")
    }

    @Test("writes the type of an attached error, never its contents")
    func errorsAreSummarised() throws {
        struct SecretFailure: Error, CustomStringConvertible {
            let description = "password=hunter2"
        }
        let sink = MemorySink()

        logger(sink: sink).log(level: .error, "Failed", error: SecretFailure())

        #expect(sink.lines.joined().contains("hunter2") == false)
        #expect(try sink.onlyLine().at("error") == "SecretFailure")
    }

    @Test("writes nothing below the configured level")
    func respectsTheLevel() {
        let sink = MemorySink()

        logger(sink: sink, level: .warning).info("Quiet")
        logger(sink: sink, level: .warning).warning("Loud")

        #expect(sink.lines.count == 1)
    }

    @Test("treats the level and metadata of one logger as values")
    func valueSemantics() {
        let sink = MemorySink()
        var first = logger(sink: sink)
        first[metadataKey: "only_on"] = "first"
        var second = first
        second[metadataKey: "only_on"] = "second"
        second.logLevel = .error

        #expect(first[metadataKey: "only_on"] == "first")
        #expect(first.logLevel == .trace)
        #expect(second.logLevel == .error)
    }
}

@Suite("LogRedaction")
struct LogRedactionTests {
    private func logged(_ metadata: Logger.Metadata) throws -> CalculationValue {
        let sink = MemorySink()
        Logger(label: "redaction") { _ in
            StructuredLogHandler(label: "redaction", level: .trace, metadataProvider: nil, sink: sink)
        }.info("Check", metadata: metadata)
        return try sink.onlyLine()
    }

    @Test(
        "replaces the value of a key that names a secret",
        arguments: [
            "password", "DB_PASSWORD", "api-key", "Authorization", "sentry_dsn", "access_token", "client_secret",
            "DATABASE_URL", "cookie",
        ]
    )
    func sensitiveKeys(key: String) throws {
        let line = try logged([key: "super-secret-value"])

        #expect(line.at(.key(key)) == "[redacted]")
    }

    @Test("redacts secrets nested in dictionaries and arrays")
    func nestedSecrets() throws {
        let line = try logged(["config": ["password": "hunter2", "host": "db"], "items": [["token": "abc"]]])

        #expect(line.at("config", "password") == "[redacted]")
        #expect(line.at("config", "host") == "db")
        #expect(line.at("items", 0, "token") == "[redacted]")
    }

    @Test("masks the password of a URL wherever it appears in text")
    func urlCredentials() {
        #expect(
            LogRedaction.mask("connect to postgres://engine:hunter2@db:5432/app failed")
                == "connect to postgres://engine:[redacted]@db:5432/app failed"
        )
        #expect(LogRedaction.mask("https://example.com/path") == "https://example.com/path")
        #expect(LogRedaction.mask("user@example.com") == "user@example.com")
    }

    @Test("masks URL credentials in messages and values")
    func maskedInOutput() throws {
        let sink = MemorySink()
        Logger(label: "redaction") { _ in
            StructuredLogHandler(label: "redaction", level: .trace, metadataProvider: nil, sink: sink)
        }.error("failed for postgres://u:pw123@h/d", metadata: ["detail": "postgres://u:pw456@h/d"])

        #expect(!sink.lines.joined().contains("pw123"))
        #expect(!sink.lines.joined().contains("pw456"))
    }

    @Test("withholds the parameters of database statements")
    func bindsAreWithheld() throws {
        let line = try logged(["binds": ["2", "a calculation parameter"], "sql": "INSERT INTO calculations"])

        #expect(line.at("binds") == "[redacted]")
        #expect(line.at("sql") == "INSERT INTO calculations")
    }

    @Test("leaves ordinary keys alone")
    func ordinaryKeys() throws {
        let line = try logged(["request_id": "r1", "route": "/x", "tokens_per_second": "5"])

        #expect(line.at("request_id") == "r1")
        #expect(line.at("route") == "/x")
    }
}
