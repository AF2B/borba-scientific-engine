import BorbaScientificCore
import Dispatch
import Foundation
import Logging
import Synchronization
import Vapor

/// Notices the termination signals the moment they arrive.
///
/// Vapor handles `SIGTERM` and `SIGINT` by closing the listener and draining the requests in flight. This watcher runs
/// alongside it and only records that shutdown has begun, so readiness reports "not ready" right away — including to
/// probes arriving on connections that are still open — while the requests already running are allowed to finish.
///
/// The dispatch sources are created and activated together in ``start()``: libdispatch aborts the process if a source
/// that was created but never activated is released.
final class ShutdownSignalWatcher: Sendable {
    private let signals: [Int32]
    private let state: ShutdownState
    private let sources = Mutex<[any DispatchSourceSignal]>([])

    /// Prepares a watcher; nothing is observed until ``start()``.
    ///
    /// - Parameters:
    ///   - signals: The signal numbers that mean "stop".
    ///   - state: Told when one arrives.
    init(
        signals: [Int32],
        state: ShutdownState
    ) {
        self.signals = signals
        self.state = state
    }

    deinit {
        stop()
    }

    /// Starts observing. The default action of the signals (killing the process) is replaced by ignoring them, so the
    /// application decides how to stop. Calling it again has no effect.
    func start() {
        sources.withLock { active in
            guard active.isEmpty else {
                return
            }
            for number in signals {
                signal(number, SIG_IGN)

                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { [state] in state.begin() }
                source.resume()
                active.append(source)
            }
        }
    }

    /// Stops observing.
    func stop() {
        sources.withLock { active in
            active.forEach { $0.cancel() }
            active.removeAll()
        }
    }
}

/// What happens, in order, when the application is told to stop.
///
/// 1. Readiness flips to "not ready", if a signal had not already done it, so no new traffic is sent.
/// 2. The requests that were already accepted get up to `requestDrainTimeout` to finish, with the database still open.
/// 3. The event subscribers get up to `eventDrainTimeout` to deliver what is queued.
/// 4. The error reporter gets up to `errorReportDrainTimeout` to deliver the reports that are still waiting.
///
/// Only after this does Vapor close the database pool.
struct ShutdownSequence: Sendable {
    let state: ShutdownState
    let inFlight: InFlightRequests
    let events: EventDispatcher?
    let errorReporter: any ErrorReporter
    let requestDrainTimeout: Duration
    let eventDrainTimeout: Duration
    let errorReportDrainTimeout: Duration
    let clock: any EngineClock
    let logger: Logger

    /// Runs the sequence. It never throws and returns when the application may close its dependencies.
    func run() async {
        state.begin()

        let drained = await Race.firstToFinish(
            {
                await inFlight.waitUntilIdle()
                return true
            },
            {
                try? await clock.sleep(for: requestDrainTimeout)
                return false
            }
        )
        if !drained {
            logger.warning(
                "Shutdown deadline reached with requests still in flight",
                metadata: ["in_flight": "\(inFlight.active)"]
            )
        }

        await events?.shutdown(within: eventDrainTimeout, clock: clock)
        await errorReporter.shutdown(within: errorReportDrainTimeout, clock: clock)
    }
}

/// Ties the shutdown sequence into Vapor's lifecycle.
///
/// Vapor shuts handlers down in reverse registration order, and this one is registered after the database, so the
/// sequence — which waits for requests that still need the database — completes before the pool closes.
final class ShutdownLifecycle: LifecycleHandler, Sendable {
    private let sequence: ShutdownSequence
    private let watcher: ShutdownSignalWatcher?

    /// Creates the handler.
    ///
    /// - Parameters:
    ///   - sequence: What to do on shutdown.
    ///   - watcher: Notices termination signals; `nil` where the process must keep its default signal handling, as in
    ///     tests.
    init(
        sequence: ShutdownSequence,
        watcher: ShutdownSignalWatcher?
    ) {
        self.sequence = sequence
        self.watcher = watcher
    }

    /// Starts watching for termination signals.
    ///
    /// - Parameter application: The application that is about to boot.
    /// - Throws: Nothing; the signature is the protocol's.
    func willBootAsync(_ application: Application) async throws {
        watcher?.start()
    }

    /// Runs the shutdown sequence.
    ///
    /// - Parameter application: The application that is shutting down.
    func shutdownAsync(_ application: Application) async {
        watcher?.stop()
        await sequence.run()
    }
}
