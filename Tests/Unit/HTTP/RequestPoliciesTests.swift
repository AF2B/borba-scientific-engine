import BorbaScientificCore
import Foundation
import Testing

@testable import BorbaScientificEngine

@Suite("RequestIdentifierPolicy")
struct RequestIdentifierPolicyTests {
    @Test(
        "adopts short identifiers made of harmless characters",
        arguments: ["a", "req-1", "A_b.c:d-9", "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01"]
    )
    func acceptsWellFormed(candidate: String) {
        #expect(RequestIdentifierPolicy.isWellFormed(candidate))
    }

    @Test("accepts the longest allowed identifier and rejects one character more")
    func lengthBoundary() {
        #expect(
            RequestIdentifierPolicy.isWellFormed(String(repeating: "a", count: RequestIdentifierPolicy.maximumLength))
        )
        #expect(
            !RequestIdentifierPolicy.isWellFormed(
                String(repeating: "a", count: RequestIdentifierPolicy.maximumLength + 1)
            )
        )
    }

    @Test(
        "rejects what could pollute logs or storage",
        arguments: ["", "has space", "new\nline", "tab\there", "semi;colon", "quote\"", "ünicode", "slash/"]
    )
    func rejectsMalformed(candidate: String) {
        #expect(!RequestIdentifierPolicy.isWellFormed(candidate))
    }
}

@Suite("IdempotencyKeyPolicy")
struct IdempotencyKeyPolicyTests {
    @Test(
        "accepts keys of visible ASCII characters",
        arguments: ["k", "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01", "order:42/retry#3", "!", "~"]
    )
    func acceptsVisible(raw: String) {
        #expect(IdempotencyKeyPolicy.parse(raw)?.rawValue == raw)
    }

    @Test("accepts the longest allowed key and rejects one character more")
    func lengthBoundary() {
        #expect(IdempotencyKeyPolicy.parse(String(repeating: "k", count: IdempotencyKey.maximumLength)) != nil)
        #expect(IdempotencyKeyPolicy.parse(String(repeating: "k", count: IdempotencyKey.maximumLength + 1)) == nil)
    }

    @Test(
        "rejects empty keys, whitespace, control characters and non-ASCII",
        arguments: ["", " ", "a b", "tab\t", "line\n", "chave-ç"]
    )
    func rejectsInvisible(raw: String) {
        #expect(IdempotencyKeyPolicy.parse(raw) == nil)
    }
}

@Suite("Timestamp")
struct TimestampTests {
    @Test("writes UTC with millisecond precision, even for instants a double cannot hold exactly")
    func format() {
        #expect(Timestamp.format(Date(timeIntervalSince1970: 1_791_028_800.123)) == "2026-10-03T12:00:00.123Z")
        #expect(Timestamp.format(Date(timeIntervalSince1970: 1_791_028_800)) == "2026-10-03T12:00:00.000Z")
        #expect(Timestamp.format(Date(timeIntervalSince1970: 1_791_028_800.999_999)) == "2026-10-03T12:00:00.999Z")
        #expect(Timestamp.format(Date(timeIntervalSince1970: 1_791_028_800.000_001)) == "2026-10-03T12:00:00.000Z")
    }

    @Test("writes instants before the Unix epoch")
    func formatBeforeEpoch() {
        #expect(Timestamp.format(Date(timeIntervalSince1970: -0.5)) == "1969-12-31T23:59:59.500Z")
    }

    @Test(
        "reads timestamps with or without fractional seconds",
        arguments: ["2026-10-03T12:00:00Z", "2026-10-03T12:00:00.000Z"]
    )
    func parse(text: String) {
        #expect(Timestamp.parse(text) == Date(timeIntervalSince1970: 1_791_028_800))
    }

    @Test("reads fractions of any precision")
    func parseFractions() throws {
        let milliseconds = try #require(Timestamp.parse("2026-10-03T12:00:00.123Z"))
        let microseconds = try #require(Timestamp.parse("2026-10-03T12:00:00.123456Z"))

        #expect(abs(milliseconds.timeIntervalSince1970 - 1_791_028_800.123) < 1e-6)
        #expect(abs(microseconds.timeIntervalSince1970 - 1_791_028_800.123_456) < 1e-6)
    }

    @Test("reads an offset and converts it to the same instant")
    func parseOffset() {
        #expect(Timestamp.parse("2026-10-03T09:00:00-03:00") == Date(timeIntervalSince1970: 1_791_028_800))
    }

    @Test(
        "rejects what is not an ISO 8601 timestamp",
        arguments: ["", "yesterday", "2026-10-03", "2026-13-01T00:00:00Z", "12:00:00"]
    )
    func rejects(text: String) {
        #expect(Timestamp.parse(text) == nil)
    }
}

@Suite("Duration.totalMilliseconds")
struct DurationMillisecondsTests {
    @Test("keeps the sub-millisecond part")
    func fractional() {
        #expect(Duration.microseconds(21).totalMilliseconds == 0.021)
        #expect(Duration.seconds(2).totalMilliseconds == 2_000)
        #expect(Duration.zero.totalMilliseconds == 0)
    }
}
