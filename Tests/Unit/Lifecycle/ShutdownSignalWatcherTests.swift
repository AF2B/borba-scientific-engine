import Foundation
import Testing

@testable import BorbaScientificEngine

/// Delivering real signals to the process that runs the tests is not tested here: signals are process-wide, so the result
/// depends on every other test running beside it, and a stray one can stop the whole run. The behaviour that matters,
/// readiness flipping when `SIGTERM` arrives while requests finish, is checked against the real executable by
/// `make smoke-shutdown` and by the release validation of the Build pipeline.
///
/// What a unit test can hold is the lifecycle of the sources. libdispatch aborts the process when a source that was
/// created but never activated is released, which is the failure this guards against.
@Suite("ShutdownSignalWatcher")
struct ShutdownSignalWatcherTests {
    @Test("can be started, started again, stopped and released without taking the process down")
    func lifecycle() {
        let watcher = ShutdownSignalWatcher(signals: [SIGUSR1, SIGUSR2], state: ShutdownState())

        watcher.start()
        watcher.start()
        watcher.stop()
        watcher.stop()
    }

    @Test("can be released without ever having been started")
    func releasedUnstarted() {
        _ = ShutdownSignalWatcher(signals: [SIGUSR1], state: ShutdownState())
    }

    @Test("can be released while it is still observing")
    func releasedWhileObserving() {
        let watcher = ShutdownSignalWatcher(signals: [SIGUSR1], state: ShutdownState())
        watcher.start()
        _ = watcher
    }
}
