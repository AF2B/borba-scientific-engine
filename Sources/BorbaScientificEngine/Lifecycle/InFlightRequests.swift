import Synchronization

/// Counts the requests that are being served, and lets the shutdown wait until there are none.
///
/// When the process is told to stop, Vapor closes the listener and then lets the application shut down, which closes
/// the database pool — possibly while accepted requests are still running. Without this count those requests would find
/// their database gone halfway through. With it, the shutdown waits (up to a deadline) until every request that was
/// accepted has been answered, and only then lets the pool close.
final class InFlightRequests: Sendable {
    private struct State {
        var active = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// How many requests are being served right now.
    var active: Int {
        state.withLock { $0.active }
    }

    /// Records that a request started.
    func begin() {
        state.withLock { $0.active += 1 }
    }

    /// Records that a request finished, and wakes whoever waits for the service to go idle when it was the last one.
    func end() {
        let released = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.active -= 1
            guard state.active == 0 else {
                return []
            }
            defer { state.waiters = [] }
            return state.waiters
        }
        released.forEach { $0.resume() }
    }

    /// Suspends until no request is being served; returns at once when none is.
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let isIdle = state.withLock { state -> Bool in
                guard state.active > 0 else {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if isIdle {
                continuation.resume()
            }
        }
    }
}
