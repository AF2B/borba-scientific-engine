public import BorbaScientificCore
public import Foundation
import Synchronization

/// A clock whose sleeps return at once and are recorded.
///
/// For code whose waits are the subject of the test but whose real duration is not: the test can check how long the code
/// asked to wait without actually waiting. A cancelled task still gets `CancellationError`, like a real sleep.
public final class RecordingSleepClock: EngineClock, Sendable {
    private let recorded = Mutex<[Duration]>([])

    /// Creates a clock with no sleeps recorded.
    public init() {}

    /// A fixed instant.
    public func currentDate() -> Date {
        Date(timeIntervalSince1970: 0)
    }

    /// A reading that never advances.
    public func uptime() -> Duration {
        .zero
    }

    /// Records the request and returns immediately.
    ///
    /// - Parameter duration: How long the caller asked to wait.
    /// - Throws: `CancellationError` when the calling task is cancelled.
    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        recorded.withLock { $0.append(duration) }
    }

    /// Every duration slept so far, in order.
    public var sleeps: [Duration] {
        recorded.withLock { $0 }
    }
}
