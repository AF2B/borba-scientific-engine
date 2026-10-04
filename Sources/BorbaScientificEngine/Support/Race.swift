import Synchronization

/// Lets exactly one of several parties claim a result.
private final class OneShotFlag: Sendable {
    private let taken = Mutex(false)

    /// Claims the flag.
    ///
    /// - Returns: `true` for the first caller only.
    func take() -> Bool {
        taken.withLock { wasTaken in
            defer { wasTaken = true }
            return !wasTaken
        }
    }
}

/// Holds tasks so the winner of a race can cancel them.
private final class TaskHolder: Sendable {
    private let tasks = Mutex<[Task<Void, Never>]>([])

    func hold(_ newTasks: [Task<Void, Never>]) {
        tasks.withLock { $0 = newTasks }
    }

    func cancelAll() {
        tasks.withLock { $0.forEach { $0.cancel() } }
    }
}

/// Runs operations against each other and takes the answer of whichever finishes first.
enum Race {
    /// Runs two operations concurrently and returns the result of the first to finish, then cancels the other.
    ///
    /// A task group cannot do this job: it always waits for *every* child before it returns, so an operation that does
    /// not react to cancellation — a database query, say — would hold up the winner, and a time limit built on it
    /// would not limit anything. Here the winner is returned at once; a loser that ignores cancellation is left to
    /// finish on its own, which is why the operations must be bounded by their own timeouts.
    ///
    /// - Parameters:
    ///   - first: The first contender.
    ///   - second: The second contender.
    /// - Returns: The result of whichever contender finished first.
    static func firstToFinish<Value: Sendable>(
        _ first: @escaping @Sendable () async -> Value,
        _ second: @escaping @Sendable () async -> Value
    ) async -> Value {
        let flag = OneShotFlag()
        let holder = TaskHolder()

        let value = await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            holder.hold([
                Task {
                    let result = await first()
                    if flag.take() {
                        continuation.resume(returning: result)
                    }
                },
                Task {
                    let result = await second()
                    if flag.take() {
                        continuation.resume(returning: result)
                    }
                },
            ])
        }

        holder.cancelAll()
        return value
    }
}
