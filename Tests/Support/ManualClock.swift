public import BorbaScientificCore
public import Foundation
import Synchronization

/// A clock whose time only moves when a test says so, which makes time budgets and timestamps deterministic.
///
/// Tasks that call ``sleep(for:)`` stay suspended until ``advance(by:)`` moves the clock past their deadline, so a
/// test can reproduce a timeout without waiting for it.
public final class ManualClock: EngineClock, Sendable {
    private static let attosecondsPerSecond = 1_000_000_000_000_000_000.0

    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private enum Registration {
        case registered
        case alreadyElapsed
        case alreadyCancelled
    }

    private struct State {
        var uptime = Duration.zero
        var date: Date
        var sleepers: [UInt64: Sleeper] = [:]
        var lastSleeperID: UInt64 = 0
    }

    private let state: Mutex<State>

    /// Creates a clock frozen at a moment in time.
    ///
    /// - Parameter date: The wall-clock time the clock starts at.
    public init(date: Date = Date(timeIntervalSince1970: 0)) {
        state = Mutex(State(date: date))
    }

    /// The frozen wall-clock time, moved only by ``advance(by:)``.
    public func currentDate() -> Date {
        state.withLock { $0.date }
    }

    /// The frozen monotonic reading, moved only by ``advance(by:)``.
    public func uptime() -> Duration {
        state.withLock { $0.uptime }
    }

    /// Number of tasks currently suspended in ``sleep(for:)``.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Suspends until the clock is advanced past the deadline, or the task is cancelled.
    ///
    /// - Parameter duration: How long to suspend, on the manual timeline.
    /// - Throws: `CancellationError` when the task is cancelled while suspended.
    public func sleep(for duration: Duration) async throws {
        let identifier = state.withLock { state -> UInt64 in
            state.lastSleeperID += 1
            return state.lastSleeperID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let registration = state.withLock { state -> Registration in
                    if Task.isCancelled {
                        return .alreadyCancelled
                    }
                    if duration <= .zero {
                        return .alreadyElapsed
                    }
                    state.sleepers[identifier] = Sleeper(deadline: state.uptime + duration, continuation: continuation)
                    return .registered
                }

                switch registration {
                case .registered:
                    break
                case .alreadyElapsed:
                    continuation.resume()
                case .alreadyCancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: identifier) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    ///
    /// - Parameter duration: How far to move the clock.
    public func advance(by duration: Duration) {
        let due = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.uptime += duration
            state.date = state.date.addingTimeInterval(Self.seconds(in: duration))

            let readyIdentifiers = state.sleepers.filter { $0.value.deadline <= state.uptime }.keys
            return readyIdentifiers.compactMap { state.sleepers.removeValue(forKey: $0)?.continuation }
        }

        for continuation in due {
            continuation.resume()
        }
    }

    /// Suspends the caller until at least `count` tasks are asleep on this clock.
    ///
    /// Tests use this to be sure a task has reached its suspension point before they advance time.
    ///
    /// - Parameter count: Number of sleeping tasks to wait for.
    public func waitUntilSleeping(count: Int = 1) async {
        while sleeperCount < count {
            await Task.yield()
        }
    }

    private static func seconds(in duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / attosecondsPerSecond
    }
}
