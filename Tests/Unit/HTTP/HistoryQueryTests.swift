import BorbaScientificCore
import Foundation
import TestSupport
import Testing

@testable import BorbaScientificEngine

@Suite("HistoryQuery")
struct HistoryQueryTests {
    private static func parse(_ pairs: KeyValuePairs<String, String>) throws -> HistoryQuery {
        try HistoryQuery.parse(pairs.map { URLQueryItem(name: $0.key, value: $0.value) })
    }

    private static func problems(_ pairs: KeyValuePairs<String, String>) -> [ErrorDetail] {
        do {
            _ = try parse(pairs)
            return []
        } catch let failure as APIFailure {
            guard case .invalidRequest(let details) = failure else {
                return []
            }
            return details
        } catch {
            return []
        }
    }

    @Test("lists everything, one default page at a time, when no parameter is given")
    func defaults() throws {
        let query = try Self.parse([:])

        #expect(query.filter == HistoryFilter())
        #expect(query.page == PageRequest())
    }

    @Test("reads every parameter")
    func everyParameter() throws {
        let cursor = PageCursorCodec.encode(
            PageCursor(createdAt: Date(timeIntervalSince1970: 1_791_028_800), id: RecordFixtures.id(3))
        )

        let query = try Self.parse([
            "module": "statistics",
            "operation": "mean",
            "status": "failed",
            "created_from": "2026-10-01T00:00:00Z",
            "created_before": "2026-10-04T00:00:00.500Z",
            "limit": "50",
            "cursor": cursor,
        ])

        #expect(query.filter.module == ModuleName("statistics"))
        #expect(query.filter.operation == OperationName("mean"))
        #expect(query.filter.status == .failed)
        #expect(query.filter.createdFrom == Timestamp.parse("2026-10-01T00:00:00Z"))
        #expect(query.filter.createdBefore == Timestamp.parse("2026-10-04T00:00:00.500Z"))
        #expect(query.page.limit == 50)
        #expect(query.page.cursor?.id == RecordFixtures.id(3))
    }

    @Test("accepts the smallest and the largest page size")
    func limitBoundaries() throws {
        #expect(try Self.parse(["limit": "1"]).page.limit == 1)
        #expect(try Self.parse(["limit": "\(PageRequest.maximumLimit)"]).page.limit == PageRequest.maximumLimit)
    }

    @Test(
        "rejects values outside what a parameter accepts and names the parameter",
        arguments: [
            ("limit", "0"),
            ("limit", "\(PageRequest.maximumLimit + 1)"),
            ("limit", "ten"),
            ("limit", "-1"),
            ("status", "pending"),
            ("created_from", "yesterday"),
            ("created_before", "2026-13-01T00:00:00Z"),
            ("cursor", "not-a-cursor"),
            ("module", "Statistics"),
            ("module", "two words"),
            ("module", "a\u{0}b"),
            ("module", "9lives"),
            ("operation", "mean!"),
            ("operation", "\u{0}"),
        ]
    )
    func invalidValues(name: String, value: String) {
        let problems = Self.problems([name: value])

        #expect(problems.map(\.field) == [name])
    }

    @Test("rejects parameters it does not know, so a misspelt filter cannot silently list everything")
    func unknownParameter() {
        #expect(Self.problems(["staus": "failed"]).map(\.field) == ["staus"])
    }

    @Test("rejects empty and repeated parameters")
    func emptyAndRepeated() throws {
        #expect(Self.problems(["module": ""]).map(\.field) == ["module"])

        let repeated = [URLQueryItem(name: "limit", value: "1"), URLQueryItem(name: "limit", value: "2")]
        #expect(throws: APIFailure.self) { try HistoryQuery.parse(repeated) }
    }

    @Test("rejects a range that ends before it starts")
    func emptyRange() {
        let problems = Self.problems(["created_from": "2026-10-04T00:00:00Z", "created_before": "2026-10-03T00:00:00Z"])

        #expect(problems.map(\.field) == ["created_before"])
    }

    @Test("reports every problem at once")
    func collectsEveryProblem() {
        let problems = Self.problems(["limit": "0", "status": "pending", "bogus": "1"])

        #expect(Set(problems.compactMap(\.field)) == ["limit", "status", "bogus"])
    }
}
