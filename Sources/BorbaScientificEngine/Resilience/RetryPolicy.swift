import BorbaScientificCore

/// When, how often and how long to wait before trying a failed repository call again.
///
/// The wait grows geometrically with every attempt and is then replaced by a random fraction of itself ("full
/// jitter"), so a crowd of requests that failed together does not come back together and hammer a database that is
/// just recovering.
struct RetryPolicy: Sendable, Equatable {
    private static let standardAttempts = 3
    private static let standardInitialDelayMilliseconds = 50
    private static let standardMultiplier = 4
    private static let standardMaximumDelaySeconds = 1

    /// Three tries in all, the first wait at most 50 ms, then at most 200 ms, never more than a second.
    static let standard = RetryPolicy(
        maximumAttempts: standardAttempts,
        initialDelay: .milliseconds(standardInitialDelayMilliseconds),
        multiplier: standardMultiplier,
        maximumDelay: .seconds(standardMaximumDelaySeconds)
    )

    /// Total tries, including the first. One means never retry.
    let maximumAttempts: Int

    /// Upper bound of the wait before the first retry.
    let initialDelay: Duration

    /// How much larger the upper bound of each wait is than the previous one.
    let multiplier: Int

    /// The upper bound no wait exceeds.
    let maximumDelay: Duration

    /// Whether a failure is worth another try.
    ///
    /// Only a store that cannot be reached is. A statement that timed out already spent its whole budget, and trying
    /// again would double the pressure on a server that is already struggling; every other failure is not going to go
    /// away by itself.
    ///
    /// - Parameter error: What the repository reported.
    /// - Returns: `true` when the call may succeed if repeated.
    func shouldRetry(_ error: RepositoryError) -> Bool {
        switch error {
        case .unavailable:
            true
        case .timeout, .integrity, .corrupted, .unexpected:
            false
        }
    }

    /// The longest the wait after a failed attempt may be.
    ///
    /// - Parameter attempt: The number of the attempt that failed, starting at 1.
    /// - Returns: `initialDelay` for the first, then `multiplier` times more each time, capped at `maximumDelay`.
    func ceiling(afterAttempt attempt: Int) -> Duration {
        var ceiling = initialDelay
        for _ in 1..<max(attempt, 1) {
            ceiling = min(ceiling * multiplier, maximumDelay)
        }
        return min(ceiling, maximumDelay)
    }

    /// How long to wait after a failed attempt.
    ///
    /// - Parameters:
    ///   - attempt: The number of the attempt that failed, starting at 1.
    ///   - fraction: A random number between 0 and 1.
    /// - Returns: That fraction of ``ceiling(afterAttempt:)``.
    func delay(
        afterAttempt attempt: Int,
        fraction: Double
    ) -> Duration {
        ceiling(afterAttempt: attempt) * min(max(fraction, 0), 1)
    }
}
