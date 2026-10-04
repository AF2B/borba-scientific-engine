import BorbaScientificCore
import Foundation
import TestSupport
import Testing

@testable import BorbaScientificEngine

@Suite("PageCursorCodec")
struct PageCursorCodecTests {
    private static let microsecondsPerSecond = 1_000_000.0

    private static func microseconds(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * microsecondsPerSecond).rounded())
    }

    @Test("returns the position it was given, to the microsecond")
    func roundTrips() throws {
        let cursor = PageCursor(
            createdAt: Date(timeIntervalSince1970: 1_791_028_800.123_457),
            id: RecordFixtures.id(42)
        )

        let decoded = try #require(PageCursorCodec.decode(PageCursorCodec.encode(cursor)))

        #expect(Self.microseconds(of: decoded.createdAt) == Self.microseconds(of: cursor.createdAt))
        #expect(decoded.id == cursor.id)
    }

    @Test("writes a token that is safe in a URL")
    func isURLSafe() {
        let token = PageCursorCodec.encode(
            PageCursor(createdAt: Date(timeIntervalSince1970: 0.000_001), id: RecordFixtures.id(1))
        )

        #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test(
        "rejects tokens it did not produce",
        arguments: [
            "",
            "!!!",
            "bm90LWEtY3Vyc29y",
            "djIuMTAuMDAwMDAwMDAtMDAwMC03MDAwLTgwMDAtMDAwMDAwMDAwMDAx",
        ]
    )
    func rejectsForeignTokens(token: String) {
        #expect(PageCursorCodec.decode(token) == nil)
    }

    @Test(
        "rejects well-formed Base64 whose content is not a cursor",
        arguments: [
            "v1.1790000000000000",
            "v1.abc.00000000-0000-7000-8000-000000000001",
            "v1.1790000000000000.not-a-uuid",
            "v2.1790000000000000.00000000-0000-7000-8000-000000000001",
            "v1.1790000000000000.00000000-0000-7000-8000-000000000001.extra",
        ]
    )
    func rejectsMalformedPayloads(payload: String) {
        #expect(PageCursorCodec.decode(Base64URL.encode(Data(payload.utf8))) == nil)
    }
}

@Suite("Base64URL")
struct Base64URLTests {
    @Test("round-trips bytes whose standard encoding uses +, / and padding")
    func roundTrips() throws {
        let bytes = Data([0xFB, 0xFF, 0xFE, 0x01, 0x02])

        let encoded = Base64URL.encode(bytes)

        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
        #expect(Base64URL.decode(encoded) == bytes)
    }

    @Test("rejects text that is not Base64")
    func rejectsGarbage() {
        #expect(Base64URL.decode("a") == nil)
        #expect(Base64URL.decode("@@@@") == nil)
    }
}
