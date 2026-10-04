import BorbaScientificCore
import Logging

/// Retries repository calls that failed because the store could not be reached, when repeating them is safe.
///
/// What is safe is decided per call, not globally:
///
/// - **Reads** (`find`, `list`, `record(for:)`) change nothing, so they are always safe to repeat.
/// - **A save with an idempotency claim** is safe: if the first attempt did commit before the connection dropped, the
///   second finds the key already bound, rolls back and returns the stored record — which is exactly what a retry of
///   an idempotent request is meant to do.
/// - **A save without a claim** is *not* safe: after an ambiguous failure it could store the calculation twice. It is
///   attempted once and its failure is reported.
///
/// Waiting uses the injected clock and stops as soon as the calling task is cancelled.
struct RetryingCalculationRepository: CalculationRepository {
    private let base: any CalculationRepository
    private let policy: RetryPolicy
    private let clock: any EngineClock
    private let logger: Logger
    private let randomFraction: @Sendable () -> Double

    /// Creates the decorator.
    ///
    /// - Parameters:
    ///   - base: The repository whose calls are retried.
    ///   - policy: When and how long to wait.
    ///   - clock: Measures the waits.
    ///   - logger: Reports every retry.
    ///   - randomFraction: Supplies the jitter, a number between 0 and 1.
    init(
        base: any CalculationRepository,
        policy: RetryPolicy,
        clock: any EngineClock,
        logger: Logger,
        randomFraction: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.base = base
        self.policy = policy
        self.clock = clock
        self.logger = logger
        self.randomFraction = randomFraction
    }

    /// Stores a record, retrying only when the call is idempotent.
    ///
    /// - Parameters:
    ///   - record: The record to store.
    ///   - claim: The idempotency key and request fingerprint; without one the call is attempted once.
    /// - Returns: ``SaveResult/created`` or the record that already owns the key.
    /// - Throws: ``RepositoryError`` when every attempt failed.
    func save(
        _ record: CalculationRecord,
        claiming claim: IdempotencyClaim?
    ) async throws(RepositoryError) -> SaveResult {
        guard claim != nil else {
            return try await base.save(record, claiming: nil)
        }
        return try await retrying("save") { () async throws(RepositoryError) -> SaveResult in
            try await base.save(record, claiming: claim)
        }
    }

    /// Finds the record created under an idempotency key.
    ///
    /// - Parameter key: The client's key.
    /// - Returns: The record and the fingerprint of the request that created it, or `nil` when the key is unused.
    /// - Throws: ``RepositoryError`` when every attempt failed.
    func record(for key: IdempotencyKey) async throws(RepositoryError) -> IdempotentRecord? {
        try await retrying("record") { () async throws(RepositoryError) -> IdempotentRecord? in
            try await base.record(for: key)
        }
    }

    /// Finds a record by identifier.
    ///
    /// - Parameter id: The identifier of the record.
    /// - Returns: The record, or `nil` when it does not exist.
    /// - Throws: ``RepositoryError`` when every attempt failed.
    func find(id: CalculationID) async throws(RepositoryError) -> CalculationRecord? {
        try await retrying("find") { () async throws(RepositoryError) -> CalculationRecord? in
            try await base.find(id: id)
        }
    }

    /// Lists records, newest first.
    ///
    /// - Parameters:
    ///   - filter: Narrows the records considered.
    ///   - page: Which page to read.
    /// - Returns: The page, with a cursor when more records follow.
    /// - Throws: ``RepositoryError`` when every attempt failed.
    func list(
        matching filter: HistoryFilter,
        page: PageRequest
    ) async throws(RepositoryError) -> Page<CalculationRecord> {
        try await retrying("list") { () async throws(RepositoryError) -> Page<CalculationRecord> in
            try await base.list(matching: filter, page: page)
        }
    }

    private func retrying<Value: Sendable>(
        _ operation: String,
        _ attempt: () async throws(RepositoryError) -> Value
    ) async throws(RepositoryError) -> Value {
        var attemptNumber = 1

        while true {
            do {
                return try await attempt()
            } catch {
                let failure = error
                guard policy.shouldRetry(failure), attemptNumber < policy.maximumAttempts else {
                    throw failure
                }

                let delay = policy.delay(afterAttempt: attemptNumber, fraction: randomFraction())
                logger.warning(
                    "Repository call failed; retrying",
                    metadata: [
                        "operation": "\(operation)",
                        "attempt": "\(attemptNumber)",
                        "retry_in": "\(delay)",
                        "diagnostic": "\(failure.diagnostic)",
                    ]
                )

                do {
                    try await clock.sleep(for: delay)
                } catch {
                    // Cancelled while waiting: nobody is interested in the answer any more.
                    throw failure
                }
                attemptNumber += 1
            }
        }
    }
}
