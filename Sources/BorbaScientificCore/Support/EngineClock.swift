public import Foundation

/// The engine's only view of time.
///
/// Business logic never reads the system clock. Everything that depends on time — timestamps, execution
/// measurements and time budgets — goes through this port, so tests can drive time deterministically.
public protocol EngineClock: Sendable {
    /// The current wall-clock time, used for timestamps that are stored or shown.
    func currentDate() -> Date

    /// A monotonic reading used only to measure elapsed time; differences between readings are meaningful, the
    /// absolute value is not. Unlike ``currentDate()`` it never jumps when the system clock is adjusted.
    func uptime() -> Duration

    /// Suspends for a duration measured on the same timeline as ``uptime()``.
    ///
    /// - Parameter duration: How long to suspend.
    /// - Throws: `CancellationError` when the task is cancelled while suspended.
    func sleep(for duration: Duration) async throws
}

/// The production clock, backed by the system.
public struct SystemClock: EngineClock {
    private let origin = ContinuousClock.now

    /// Creates a system clock. Uptime readings are measured from this moment.
    public init() {}

    /// The current system time.
    public func currentDate() -> Date {
        Date()
    }

    /// Time elapsed since the clock was created, on a monotonic timeline.
    public func uptime() -> Duration {
        origin.duration(to: ContinuousClock.now)
    }

    /// Suspends the current task.
    ///
    /// - Parameter duration: How long to suspend.
    /// - Throws: `CancellationError` when the task is cancelled while suspended.
    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
