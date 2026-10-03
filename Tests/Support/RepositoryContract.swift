public import BorbaScientificCore
public import Foundation
import Testing

/// Builds records for repository and service tests.
public enum RecordFixtures {
    /// A fixed instant whose fractional part is a whole number of milliseconds, so it survives storage with
    /// microsecond precision unchanged.
    public static let epoch = Date(timeIntervalSince1970: 1_700_000_000.250)

    /// The trace context shared by fixture records.
    public static let trace = TraceContext(
        requestID: RequestID("request-1"),
        correlationID: CorrelationID("correlation-1")
    )

    /// Builds a record.
    ///
    /// - Parameters:
    ///   - sequence: A number that determines the identifier, so records are easy to tell apart.
    ///   - offset: How long after ``epoch`` the record was created.
    ///   - type: Which calculation the record is for.
    ///   - outcome: What the calculation produced.
    /// - Returns: The record.
    public static func record(
        sequence: Int,
        offset: Duration = .zero,
        type: CalculationType = CalculationType(module: ModuleName("arithmetic"), operation: OperationName("add")),
        outcome: CalculationOutcome = .succeeded(.number(5))
    ) -> CalculationRecord {
        CalculationRecord(
            id: id(sequence),
            type: type,
            parameters: ["a": 2, "b": 3],
            outcome: outcome,
            executionTime: .microseconds(42),
            createdAt: epoch.addingTimeInterval(seconds(offset)),
            trace: trace
        )
    }

    /// Builds the identifier of the n-th fixture record. Identifiers sort in the order of their sequence numbers.
    ///
    /// - Parameter sequence: The sequence number.
    /// - Returns: A deterministic identifier.
    public static func id(_ sequence: Int) -> CalculationID {
        let text = String(format: "00000000-0000-7000-8000-%012x", sequence)
        return CalculationID(UUID(uuidString: text) ?? UUID())
    }

    /// A failure outcome with details, as a validation failure would produce.
    public static let failure = CalculationOutcome.failed(
        RecordedFailure(
            code: .divisionByZero,
            message: "Division by zero is undefined: the divisor must not be zero.",
            details: [RecordedDetail(field: "divisor", reason: "must not be zero")]
        )
    )

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// The behavior every ``CalculationRepository`` must have.
///
/// The same checks run against the in-memory test double and the PostgreSQL adapter, which is what keeps the double
/// honest: if the real store behaves differently, one of the two suites fails.
public enum RepositoryContract {
    /// Runs every check, each against a fresh repository.
    ///
    /// - Parameter makeRepository: Creates an empty repository.
    /// - Throws: Whatever the repository or its construction throws; every failed expectation is recorded as a test issue.
    public static func verify<Repository: CalculationRepository>(
        _ makeRepository: () async throws -> Repository
    ) async throws {
        try await storesAndFindsRecords(makeRepository())
        try await roundTripsLargePayloads(makeRepository())
        try await bindsIdempotencyKeysToTheFirstRecord(makeRepository())
        try await convergesConcurrentRetries(makeRepository())
        try await listsNewestFirstAndPaginates(makeRepository())
        try await breaksTiesByIdentifier(makeRepository())
        try await filtersHistory(makeRepository())
    }

    static func storesAndFindsRecords(_ repository: some CalculationRepository) async throws {
        let success = RecordFixtures.record(sequence: 1)
        let failure = RecordFixtures.record(sequence: 2, outcome: RecordFixtures.failure)

        #expect(try await repository.save(success, claiming: nil) == .created)
        #expect(try await repository.save(failure, claiming: nil) == .created)

        #expect(try await repository.find(id: success.id) == success)
        #expect(try await repository.find(id: failure.id) == failure)
        #expect(try await repository.find(id: RecordFixtures.id(99)) == nil)
    }

    static func roundTripsLargePayloads(_ repository: some CalculationRepository) async throws {
        let numbers = (0..<10_000).map(Double.init)
        let record = CalculationRecord(
            id: RecordFixtures.id(1),
            type: CalculationType(module: ModuleName("statistics"), operation: OperationName("mean")),
            parameters: ["values": .numbers(numbers), "nested": ["flag": true, "text": "héllo", "none": nil]],
            outcome: .succeeded(.fields(["mean": 4_999.5, "rows": .matrix([[1, 2], [3, 4]])])),
            executionTime: .nanoseconds(1_234_567),
            createdAt: RecordFixtures.epoch,
            trace: RecordFixtures.trace
        )

        _ = try await repository.save(record, claiming: nil)

        #expect(try await repository.find(id: record.id) == record)
    }

    static func bindsIdempotencyKeysToTheFirstRecord(_ repository: some CalculationRepository) async throws {
        let key = IdempotencyKey("key-1")
        let first = RecordFixtures.record(sequence: 1)
        let second = RecordFixtures.record(sequence: 2)
        let firstClaim = IdempotencyClaim(key: key, fingerprint: RequestFingerprint("fingerprint-a"))
        let secondClaim = IdempotencyClaim(key: key, fingerprint: RequestFingerprint("fingerprint-b"))

        #expect(try await repository.record(for: key) == nil)
        #expect(try await repository.save(first, claiming: firstClaim) == .created)

        let duplicate = try await repository.save(second, claiming: secondClaim)
        let owner = IdempotentRecord(record: first, fingerprint: RequestFingerprint("fingerprint-a"))

        #expect(duplicate == .duplicate(owner))
        #expect(try await repository.record(for: key) == owner)
        #expect(try await repository.find(id: second.id) == nil, "a rejected duplicate must not be stored")
        #expect(try await repository.record(for: IdempotencyKey("other")) == nil)
    }

    static func convergesConcurrentRetries(_ repository: some CalculationRepository) async throws {
        let claim = IdempotencyClaim(key: IdempotencyKey("racing"), fingerprint: RequestFingerprint("same"))
        let attempts = 12

        let results = try await withThrowingTaskGroup(of: SaveResult.self) { group in
            for sequence in 1...attempts {
                group.addTask {
                    try await repository.save(RecordFixtures.record(sequence: sequence), claiming: claim)
                }
            }
            return try await group.reduce(into: [SaveResult]()) { $0.append($1) }
        }

        let created = results.filter { $0 == .created }.count
        let page = try await repository.list(
            matching: HistoryFilter(),
            page: PageRequest(limit: PageRequest.maximumLimit)
        )

        #expect(created == 1, "exactly one concurrent save may win the key")
        #expect(page.items.count == 1, "the losers must not leave records behind")
    }

    static func listsNewestFirstAndPaginates(_ repository: some CalculationRepository) async throws {
        let total = 7
        for sequence in 1...total {
            _ = try await repository.save(
                RecordFixtures.record(sequence: sequence, offset: .seconds(sequence)),
                claiming: nil
            )
        }

        var collected: [CalculationID] = []
        var cursor: PageCursor?
        var pages = 0
        repeat {
            let page = try await repository.list(matching: HistoryFilter(), page: PageRequest(limit: 3, cursor: cursor))
            collected.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < total

        #expect(collected == (1...total).reversed().map(RecordFixtures.id), "newest first, each record exactly once")
        #expect(pages == 3)
    }

    static func breaksTiesByIdentifier(_ repository: some CalculationRepository) async throws {
        for sequence in 1...4 {
            _ = try await repository.save(RecordFixtures.record(sequence: sequence), claiming: nil)
        }

        let first = try await repository.list(matching: HistoryFilter(), page: PageRequest(limit: 2))
        let second = try await repository.list(
            matching: HistoryFilter(),
            page: PageRequest(limit: 2, cursor: first.nextCursor)
        )

        #expect(first.items.map(\.id) == [RecordFixtures.id(4), RecordFixtures.id(3)])
        #expect(second.items.map(\.id) == [RecordFixtures.id(2), RecordFixtures.id(1)])
        #expect(second.nextCursor == nil)
    }

    static func filtersHistory(_ repository: some CalculationRepository) async throws {
        let statistics = CalculationType(module: ModuleName("statistics"), operation: OperationName("mean"))
        let division = CalculationType(module: ModuleName("arithmetic"), operation: OperationName("divide"))
        _ = try await repository.save(RecordFixtures.record(sequence: 1, offset: .seconds(1)), claiming: nil)
        _ = try await repository.save(
            RecordFixtures.record(sequence: 2, offset: .seconds(2), type: statistics),
            claiming: nil
        )
        _ = try await repository.save(
            RecordFixtures.record(sequence: 3, offset: .seconds(3), type: division, outcome: RecordFixtures.failure),
            claiming: nil
        )

        func ids(_ filter: HistoryFilter) async throws -> [CalculationID] {
            try await repository.list(matching: filter, page: PageRequest()).items.map(\.id)
        }

        #expect(
            try await ids(HistoryFilter(module: ModuleName("arithmetic"))) == [
                RecordFixtures.id(3), RecordFixtures.id(1),
            ]
        )
        #expect(
            try await ids(HistoryFilter(module: ModuleName("arithmetic"), operation: OperationName("divide"))) == [
                RecordFixtures.id(3)
            ]
        )
        #expect(try await ids(HistoryFilter(status: .failed)) == [RecordFixtures.id(3)])
        #expect(try await ids(HistoryFilter(status: .succeeded)) == [RecordFixtures.id(2), RecordFixtures.id(1)])
        #expect(
            try await ids(HistoryFilter(createdFrom: RecordFixtures.epoch.addingTimeInterval(2))) == [
                RecordFixtures.id(3), RecordFixtures.id(2),
            ]
        )
        #expect(
            try await ids(HistoryFilter(createdBefore: RecordFixtures.epoch.addingTimeInterval(2))) == [
                RecordFixtures.id(1)
            ]
        )
        #expect(try await ids(HistoryFilter(module: ModuleName("missing"))).isEmpty)
    }
}
