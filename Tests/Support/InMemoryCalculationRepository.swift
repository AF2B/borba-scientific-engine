public import BorbaScientificCore
import Foundation

/// A repository that keeps everything in memory, with the same observable behavior as the PostgreSQL adapter:
/// idempotency keys bind atomically to the first record, listing is newest first with keyset pagination, and
/// failures can be injected on demand.
///
/// It exists for unit tests of the use cases; the shared repository contract suite runs against both this and the
/// real adapter so the two cannot drift apart.
public actor InMemoryCalculationRepository: CalculationRepository {
    private struct Claim {
        let id: CalculationID
        let fingerprint: RequestFingerprint
    }

    private var records: [CalculationID: CalculationRecord] = [:]
    private var claims: [IdempotencyKey: Claim] = [:]
    private var injectedFailures: [RepositoryError] = []

    /// How many times ``save(_:claiming:)`` has been called, including calls that failed or found a duplicate.
    public private(set) var saveAttempts = 0

    /// Creates an empty repository.
    public init() {}

    /// Number of stored records.
    public var recordCount: Int {
        records.count
    }

    /// Every stored record, newest first.
    public var allRecords: [CalculationRecord] {
        records.values.sorted(by: Self.isNewer)
    }

    /// Makes the next calls to any repository method fail.
    ///
    /// - Parameters:
    ///   - error: The failure to raise.
    ///   - times: How many consecutive calls fail before the repository recovers.
    public func failNextCalls(
        with error: RepositoryError,
        times: Int = 1
    ) {
        injectedFailures.append(contentsOf: Array(repeating: error, count: times))
    }

    /// Stores a record, binding the idempotency key atomically when a claim is given.
    ///
    /// - Parameters:
    ///   - record: The record to store.
    ///   - claim: The idempotency key and request fingerprint.
    /// - Returns: ``SaveResult/created`` or the record that already owns the key.
    /// - Throws: An injected ``RepositoryError``.
    public func save(
        _ record: CalculationRecord,
        claiming claim: IdempotencyClaim?
    ) async throws(RepositoryError) -> SaveResult {
        saveAttempts += 1
        try raiseInjectedFailure()

        if let claim, let existing = claims[claim.key], let owner = records[existing.id] {
            return .duplicate(IdempotentRecord(record: owner, fingerprint: existing.fingerprint))
        }

        records[record.id] = record
        if let claim {
            claims[claim.key] = Claim(id: record.id, fingerprint: claim.fingerprint)
        }
        return .created
    }

    /// Finds the record created under an idempotency key.
    ///
    /// - Parameter key: The client's key.
    /// - Returns: The record and its request fingerprint, or `nil`.
    /// - Throws: An injected ``RepositoryError``.
    public func record(for key: IdempotencyKey) async throws(RepositoryError) -> IdempotentRecord? {
        try raiseInjectedFailure()

        guard let claim = claims[key], let record = records[claim.id] else {
            return nil
        }
        return IdempotentRecord(record: record, fingerprint: claim.fingerprint)
    }

    /// Finds a record by identifier.
    ///
    /// - Parameter id: The identifier of the record.
    /// - Returns: The record, or `nil`.
    /// - Throws: An injected ``RepositoryError``.
    public func find(id: CalculationID) async throws(RepositoryError) -> CalculationRecord? {
        try raiseInjectedFailure()
        return records[id]
    }

    /// Lists records, newest first, with keyset pagination.
    ///
    /// - Parameters:
    ///   - filter: Narrows the records considered.
    ///   - page: Which page to read.
    /// - Returns: The page.
    /// - Throws: An injected ``RepositoryError``.
    public func list(
        matching filter: HistoryFilter,
        page: PageRequest
    ) async throws(RepositoryError) -> Page<CalculationRecord> {
        try raiseInjectedFailure()

        let matching = records.values
            .filter { Self.matches($0, filter) }
            .sorted(by: Self.isNewer)
            .filter { record in
                guard let cursor = page.cursor else {
                    return true
                }
                return (record.createdAt, record.id) < (cursor.createdAt, cursor.id)
            }

        let items = Array(matching.prefix(page.limit))
        let hasMore = matching.count > page.limit
        let nextCursor = hasMore ? items.last.map { PageCursor(createdAt: $0.createdAt, id: $0.id) } : nil
        return Page(items: items, nextCursor: nextCursor)
    }

    private func raiseInjectedFailure() throws(RepositoryError) {
        guard !injectedFailures.isEmpty else {
            return
        }
        throw injectedFailures.removeFirst()
    }

    private static func isNewer(
        _ lhs: CalculationRecord,
        _ rhs: CalculationRecord
    ) -> Bool {
        (lhs.createdAt, lhs.id) > (rhs.createdAt, rhs.id)
    }

    private static func matches(
        _ record: CalculationRecord,
        _ filter: HistoryFilter
    ) -> Bool {
        (filter.module.map { $0 == record.type.module } ?? true)
            && (filter.operation.map { $0 == record.type.operation } ?? true)
            && (filter.status.map { $0 == record.status } ?? true)
            && (filter.createdFrom.map { record.createdAt >= $0 } ?? true)
            && (filter.createdBefore.map { record.createdAt < $0 } ?? true)
    }
}
