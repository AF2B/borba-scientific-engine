import Synchronization

/// Whether the process has begun to shut down.
///
/// Readiness reads it so the service stops asking to be sent traffic the moment a termination signal arrives, while
/// requests that are already running are still allowed to finish.
final class ShutdownState: Sendable {
    private let flag = Mutex(false)

    /// Whether shutdown has begun.
    var isShuttingDown: Bool {
        flag.withLock { $0 }
    }

    /// Records that shutdown has begun. It cannot be undone.
    func begin() {
        flag.withLock { $0 = true }
    }
}
