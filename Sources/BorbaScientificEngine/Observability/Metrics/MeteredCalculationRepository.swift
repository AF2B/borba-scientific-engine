import BorbaScientificCore

/// Measures every call to the calculation history: how long it took and, when it failed, how.
///
/// It sits directly on the database adapter, under the retry decorator, so every attempt is measured separately and a
/// call that needed three tries shows up as three durations and two failures — which is the truth about the database.
struct MeteredCalculationRepository: CalculationRepository {
    private let base: any CalculationRepository
    private let metrics: EngineMetrics
    private let clock: any EngineClock

    /// Creates the decorator.
    ///
    /// - Parameters:
    ///   - base: The repository to measure.
    ///   - metrics: Where measurements are recorded.
    ///   - clock: Measures durations.
    init(
        base: any CalculationRepository,
        metrics: EngineMetrics,
        clock: any EngineClock
    ) {
        self.base = base
        self.metrics = metrics
        self.clock = clock
    }

    /// Stores a record.
    ///
    /// - Parameters:
    ///   - record: The record to store.
    ///   - claim: The idempotency key and request fingerprint, when the client supplied a key.
    /// - Returns: ``SaveResult/created`` or the record that already owns the key.
    /// - Throws: ``RepositoryError`` when the store fails.
    func save(
        _ record: CalculationRecord,
        claiming claim: IdempotencyClaim?
    ) async throws(RepositoryError) -> SaveResult {
        try await measured("save") { () async throws(RepositoryError) -> SaveResult in
            try await base.save(record, claiming: claim)
        }
    }

    /// Finds the record created under an idempotency key.
    ///
    /// - Parameter key: The client's key.
    /// - Returns: The record and the fingerprint of the request that created it, or `nil` when the key is unused.
    /// - Throws: ``RepositoryError`` when the store fails.
    func record(for key: IdempotencyKey) async throws(RepositoryError) -> IdempotentRecord? {
        try await measured("record") { () async throws(RepositoryError) -> IdempotentRecord? in
            try await base.record(for: key)
        }
    }

    /// Finds a record by identifier.
    ///
    /// - Parameter id: The identifier of the record.
    /// - Returns: The record, or `nil` when it does not exist.
    /// - Throws: ``RepositoryError`` when the store fails.
    func find(id: CalculationID) async throws(RepositoryError) -> CalculationRecord? {
        try await measured("find") { () async throws(RepositoryError) -> CalculationRecord? in
            try await base.find(id: id)
        }
    }

    /// Lists records, newest first.
    ///
    /// - Parameters:
    ///   - filter: Narrows the records considered.
    ///   - page: Which page to read.
    /// - Returns: The page, with a cursor when more records follow.
    /// - Throws: ``RepositoryError`` when the store fails.
    func list(
        matching filter: HistoryFilter,
        page: PageRequest
    ) async throws(RepositoryError) -> Page<CalculationRecord> {
        try await measured("list") { () async throws(RepositoryError) -> Page<CalculationRecord> in
            try await base.list(matching: filter, page: page)
        }
    }

    private func measured<Value: Sendable>(
        _ operation: String,
        _ call: () async throws(RepositoryError) -> Value
    ) async throws(RepositoryError) -> Value {
        let startedAt = clock.uptime()

        do {
            let value = try await call()
            metrics.recordDatabaseOperation(operation, duration: clock.uptime() - startedAt, failure: nil)
            return value
        } catch {
            metrics.recordDatabaseOperation(operation, duration: clock.uptime() - startedAt, failure: error)
            throw error
        }
    }
}
