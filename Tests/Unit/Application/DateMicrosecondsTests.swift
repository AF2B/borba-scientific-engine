import Foundation
import Testing

@testable import BorbaScientificCore

@Suite("Date microseconds")
struct DateMicrosecondsTests {
    @Test("counts whole microseconds since the epoch, and reads them back")
    func roundTrips() {
        let count: Int64 = 1_791_028_800_123_457

        let date = Date(wholeMicrosecondsSinceEpoch: count)

        #expect(date.wholeMicrosecondsSinceEpoch == count)
    }

    @Test(
        "names the epoch zero and instants before it negative",
        arguments: [Int64(0), -1, -1_500_000, -62_135_769_600_000_000]
    )
    func countsFromTheEpoch(count: Int64) {
        #expect(Date(wholeMicrosecondsSinceEpoch: count).wholeMicrosecondsSinceEpoch == count)
    }

    @Test(
        "saturates instead of trapping for an instant no count can hold",
        arguments: [
            (Double.greatestFiniteMagnitude, Int64.max),
            (Double.infinity, Int64.max),
            (Double.nan, Int64.max),
            (-Double.greatestFiniteMagnitude, Int64.min),
            (-Double.infinity, Int64.min),
        ]
    )
    func saturates(seconds: Double, expected: Int64) {
        #expect(Date(timeIntervalSince1970: seconds).wholeMicrosecondsSinceEpoch == expected)
    }
}
