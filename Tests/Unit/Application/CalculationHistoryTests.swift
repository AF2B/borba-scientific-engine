import Foundation
import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("CalculationHistory")
struct CalculationHistoryTests {
    @Test("returns a stored calculation and reports a missing one")
    func lookup() async throws {
        let repository = InMemoryCalculationRepository()
        let history = CalculationHistory(repository: repository)
        let record = RecordFixtures.record(sequence: 1)
        _ = try await repository.save(record, claiming: nil)

        #expect(try await history.calculation(id: record.id) == record)
        await #expect(throws: HistoryFailure.notFound(RecordFixtures.id(2))) {
            try await history.calculation(id: RecordFixtures.id(2))
        }
    }

    @Test("reports storage failures with their stable codes")
    func storageFailures() async throws {
        let repository = InMemoryCalculationRepository()
        let history = CalculationHistory(repository: repository)
        await repository.failNextCalls(with: .timeout, times: 2)

        let single = await #expect(throws: HistoryFailure.self) {
            try await history.calculation(id: RecordFixtures.id(1))
        }
        let listing = await #expect(throws: HistoryFailure.self) {
            try await history.calculations(matching: HistoryFilter(), page: PageRequest())
        }

        #expect(single == .storage(.timeout))
        #expect(listing?.code == .storageUnavailable)
        #expect(HistoryFailure.notFound(RecordFixtures.id(1)).code == .calculationNotFound)
        #expect(HistoryFailure.notFound(RecordFixtures.id(1)).classification == .application)
    }

    @Test("lists calculations with filters and cursors")
    func listing() async throws {
        let repository = InMemoryCalculationRepository()
        let history = CalculationHistory(repository: repository)
        for sequence in 1...5 {
            _ = try await repository.save(
                RecordFixtures.record(sequence: sequence, offset: .seconds(sequence)),
                claiming: nil
            )
        }

        let first = try await history.calculations(matching: HistoryFilter(), page: PageRequest(limit: 2))
        let second = try await history.calculations(
            matching: HistoryFilter(),
            page: PageRequest(limit: 2, cursor: first.nextCursor)
        )

        #expect(first.items.map(\.id) == [RecordFixtures.id(5), RecordFixtures.id(4)])
        #expect(second.items.map(\.id) == [RecordFixtures.id(3), RecordFixtures.id(2)])
    }
}
