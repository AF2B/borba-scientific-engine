public import Foundation

extension Date {
    private static let microsecondsPerSecond = 1_000_000.0

    /// The instant as whole microseconds since the Unix epoch: the resolution of the database and of the timestamps the
    /// API writes, and a count that is exact where a number of seconds as a `Double` is not.
    ///
    /// An instant that no 64-bit count of microseconds can hold saturates, to the earliest or the latest count, instead of
    /// trapping as a direct conversion would. Whoever receives it can refuse it with an error, and the process lives.
    public var wholeMicrosecondsSinceEpoch: Int64 {
        let microseconds = (timeIntervalSince1970 * Self.microsecondsPerSecond).rounded()

        return Int64(exactly: microseconds) ?? (microseconds < 0 ? .min : .max)
    }

    /// The instant a count of whole microseconds since the Unix epoch names.
    ///
    /// - Parameter wholeMicrosecondsSinceEpoch: The count.
    public init(wholeMicrosecondsSinceEpoch: Int64) {
        self.init(timeIntervalSince1970: Double(wholeMicrosecondsSinceEpoch) / Self.microsecondsPerSecond)
    }
}
