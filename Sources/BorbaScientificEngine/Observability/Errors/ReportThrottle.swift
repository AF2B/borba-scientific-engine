import BorbaScientificCore

/// What the throttle decided about a failure.
enum ThrottleDecision: Sendable, Equatable {
    /// Send it. `repeats` counts the identical failures that were folded into it since the last report.
    case send(repeats: Int)

    /// Do not send it; it is counted and will be mentioned in the next report of its kind.
    case suppress

    /// The overall limit on reports was reached.
    case overLimit
}

/// Keeps an incident from turning into a flood of identical reports.
///
/// An outage makes every request fail the same way, and reporting each one would exhaust the tracker's quota and bury
/// the signal. The throttle sends the first failure of a kind at once, folds the identical ones that follow into a
/// counter for the length of a window, and mentions the count in the next report. A global limit bounds the total
/// number of reports per window whatever their kind.
///
/// It is an actor because the table of recent failures is shared by every request that fails.
actor ReportThrottle {
    private static let maximumTrackedKinds = 1_000

    private struct Entry {
        var firstSeenAt: Duration
        var suppressed: Int
    }

    private let window: Duration
    private let limitPerWindow: Int
    private let clock: any EngineClock

    private var entries: [String: Entry] = [:]
    private var windowStartedAt: Duration
    private var sentInWindow = 0

    /// Creates a throttle.
    ///
    /// - Parameters:
    ///   - window: How long identical failures are folded together, and the period of the global limit.
    ///   - limitPerWindow: The most reports sent in one window, of any kind.
    ///   - clock: Measures the windows.
    init(
        window: Duration,
        limitPerWindow: Int,
        clock: any EngineClock
    ) {
        self.window = window
        self.limitPerWindow = limitPerWindow
        self.clock = clock
        windowStartedAt = clock.uptime()
    }

    /// Decides whether a failure is reported now.
    ///
    /// - Parameter kind: What makes two failures "the same": the error code and the route.
    /// - Returns: The decision.
    func admit(kind: String) -> ThrottleDecision {
        let now = clock.uptime()
        startNewWindowIfDue(now)

        if var entry = entries[kind], now - entry.firstSeenAt < window {
            entry.suppressed += 1
            entries[kind] = entry
            return .suppress
        }

        guard sentInWindow < limitPerWindow else {
            return .overLimit
        }
        sentInWindow += 1

        let repeats = entries[kind]?.suppressed ?? 0
        entries[kind] = Entry(firstSeenAt: now, suppressed: 0)
        return .send(repeats: repeats)
    }

    private func startNewWindowIfDue(_ now: Duration) {
        guard now - windowStartedAt >= window else {
            return
        }
        windowStartedAt = now
        sentInWindow = 0

        if entries.count > Self.maximumTrackedKinds {
            entries = entries.filter { now - $0.value.firstSeenAt < window }
        }
    }
}
