import Foundation
import TestSupport
import Testing

@testable import BorbaScientificCore

/// A service wired to in-memory collaborators and a manual clock.
struct ServiceHarness {
    static let timeLimit = Duration.seconds(5)
    static let trace = TraceContext(requestID: RequestID("request-7"), correlationID: CorrelationID("correlation-7"))

    let clock: ManualClock
    let repository: InMemoryCalculationRepository
    let events: RecordingEventPublisher
    let controls: FixtureControls
    let service: CalculationService

    init() throws {
        clock = ManualClock(date: RecordFixtures.epoch)
        repository = InMemoryCalculationRepository()
        events = RecordingEventPublisher()
        controls = FixtureControls()

        let registry = try ModuleRegistry(
            modules: [ArithmeticModule(), FixtureModule(clock: clock, controls: controls)]
        )
        service = CalculationService(
            engine: CalculationEngine(registry: registry, clock: clock, timeout: Self.timeLimit),
            repository: repository,
            events: events,
            clock: clock,
            identifiers: SequentialIdentifiers()
        )
    }

    /// Builds a command for an arithmetic operation.
    func arithmetic(
        _ operation: ArithmeticOperation,
        _ parameters: [String: CalculationValue],
        key: String? = nil,
        fingerprint: String = "fingerprint"
    ) -> ExecuteCalculation {
        command(ModuleName.arithmetic, operation, parameters, key: key, fingerprint: fingerprint)
    }

    /// Builds a command for a fixture operation.
    func fixture(
        _ operation: FixtureOperation,
        _ parameters: [String: CalculationValue] = [:]
    ) -> ExecuteCalculation {
        command(ModuleName("fixture"), operation, parameters, key: nil, fingerprint: "fingerprint")
    }

    private func command(
        _ module: ModuleName,
        _ operation: some RawRepresentable<String>,
        _ parameters: [String: CalculationValue],
        key: String?,
        fingerprint: String
    ) -> ExecuteCalculation {
        ExecuteCalculation(
            request: CalculationRequest(
                type: CalculationType(module: module, operation: OperationName(operation.rawValue)),
                parameters: parameters
            ),
            idempotency: key.map {
                IdempotencyClaim(key: IdempotencyKey($0), fingerprint: RequestFingerprint(fingerprint))
            },
            trace: Self.trace
        )
    }
}

extension ServiceHarness {
    var addition: ExecuteCalculation {
        arithmetic(.add, ["a": 2, "b": 3])
    }

    var divisionByZero: ExecuteCalculation {
        arithmetic(.divide, ["dividend": 1, "divisor": 0])
    }
}

@Suite("CalculationService")
struct CalculationServiceTests {
    @Test("runs a calculation, records it and publishes requested then completed")
    func recordsSuccess() async throws {
        let harness = try ServiceHarness()

        let result = try await harness.service.execute(harness.addition)

        guard case .executed(let record) = result else {
            Issue.record("Expected a new execution")
            return
        }
        #expect(record.outcome == .succeeded(.number(5)))
        #expect(record.type.description == "arithmetic.add")
        #expect(record.parameters == ["a": 2, "b": 3])
        #expect(record.createdAt == RecordFixtures.epoch)
        #expect(record.trace == ServiceHarness.trace)
        #expect(record.id == CalculationID(UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()))
        #expect(try await harness.repository.find(id: record.id) == record)
        #expect(await harness.events.eventNames == ["CalculationRequested", "CalculationCompleted"])
    }

    @Test("carries the same identifiers through the record and every event")
    func tracesEverything() async throws {
        let harness = try ServiceHarness()

        let record = try await harness.service.execute(harness.addition).record
        let events = await harness.events.events

        #expect(events.map(\.calculationID) == [record.id, record.id])
        #expect(events.map(\.trace) == [ServiceHarness.trace, ServiceHarness.trace])
        #expect(events.map(\.type) == [record.type, record.type])
    }

    @Test("records a domain failure as an outcome, not as an error")
    func recordsDomainFailure() async throws {
        let harness = try ServiceHarness()

        let record = try await harness.service.execute(harness.divisionByZero).record

        guard case .failed(let failure) = record.outcome else {
            Issue.record("Expected a failed outcome")
            return
        }
        #expect(failure.code == .divisionByZero)
        #expect(record.status == .failed)
        #expect(try await harness.repository.find(id: record.id) == record)

        let events = await harness.events.events
        guard case .failed(let event)? = events.last else {
            Issue.record("Expected a failed event")
            return
        }
        #expect(event.code == .divisionByZero)
        #expect(event.classification == .expectedDomain)
        #expect(events.count == 2)
    }

    @Test("refuses invalid requests before running and records nothing")
    func rejectsInvalidRequests() async throws {
        let harness = try ServiceHarness()

        let invalid = await #expect(throws: ExecutionFailure.self) {
            try await harness.service.execute(harness.arithmetic(.add, ["a": "two"]))
        }
        let unknown = await #expect(throws: ExecutionFailure.self) {
            try await harness.service.execute(
                ExecuteCalculation(
                    request: CalculationRequest(
                        type: CalculationType(module: ModuleName("nope"), operation: OperationName("nothing")),
                        parameters: [:]
                    ),
                    trace: ServiceHarness.trace
                )
            )
        }

        guard case .rejected(.validation)? = invalid, case .rejected(.unsupportedOperation)? = unknown else {
            Issue.record("Expected rejections, got \(String(describing: invalid)) and \(String(describing: unknown))")
            return
        }
        #expect(await harness.repository.recordCount == 0)
        #expect(await harness.events.events.isEmpty)
        #expect(invalid?.classification == .expectedDomain)
    }

    @Test("reports a defect, records nothing and still closes the event pair")
    func reportsDefects() async throws {
        let harness = try ServiceHarness()

        let failure = await #expect(throws: ExecutionFailure.self) {
            try await harness.service.execute(harness.fixture(.crash))
        }

        guard case .defect? = failure else {
            Issue.record("Expected a defect, got \(String(describing: failure))")
            return
        }
        #expect(failure?.classification == .unexpected)
        #expect(failure?.message == "An unexpected error occurred.")
        #expect(await harness.repository.recordCount == 0)
        #expect(await harness.events.eventNames == ["CalculationRequested", "CalculationFailed"])
    }

    @Test("reports cancellation without recording and still closes the event pair")
    func reportsCancellation() async throws {
        let harness = try ServiceHarness()
        let command = harness.fixture(.spin)

        let task = Task { () async -> ExecutionFailure? in
            do {
                _ = try await harness.service.execute(command)
                return nil
            } catch let failure as ExecutionFailure {
                return failure
            } catch {
                return .defect(reason: "\(error)")
            }
        }
        task.cancel()
        let failure = await task.value

        #expect(failure == .cancelled)
        #expect(await harness.repository.recordCount == 0)
        let events = await harness.events.events
        guard case .failed(let event)? = events.last else {
            Issue.record("Expected a failed event, got \(events)")
            return
        }
        #expect(event.code == .calculationCancelled)
    }

    @Test("records a calculation that exhausted its time budget as a failed outcome")
    func recordsTimeouts() async throws {
        let harness = try ServiceHarness()
        let command = harness.fixture(.sleep, [FixtureParameters.seconds.name: 60])

        let task = Task { try await harness.service.execute(command) }
        await harness.clock.waitUntilSleeping(count: 2)
        harness.clock.advance(by: ServiceHarness.timeLimit)
        let record = try await task.value.record

        guard case .failed(let failure) = record.outcome else {
            Issue.record("Expected a failed outcome")
            return
        }
        #expect(failure.code == .calculationTimeout)
        #expect(record.executionTime == ServiceHarness.timeLimit)
        #expect(try await harness.repository.find(id: record.id) == record)
    }

    @Test("reports a storage failure and tells observers the calculation did not complete")
    func reportsStorageFailure() async throws {
        let harness = try ServiceHarness()
        await harness.repository.failNextCalls(with: .unavailable(reason: "connection refused"))

        let failure = await #expect(throws: ExecutionFailure.self) {
            try await harness.service.execute(harness.addition)
        }

        #expect(failure == .storage(.unavailable(reason: "connection refused")))
        #expect(failure?.code == .storageUnavailable)
        #expect(failure?.classification == .infrastructure)
        #expect(failure?.message == "The calculation history is temporarily unavailable.")
        let events = await harness.events.events
        guard case .failed(let event)? = events.last else {
            Issue.record("Expected a failed event")
            return
        }
        #expect(event.code == .storageUnavailable)
        #expect(event.classification == .infrastructure)
    }

    // MARK: - Idempotency

    @Test("returns the stored record for a retried request instead of running it again")
    func replaysRetries() async throws {
        let harness = try ServiceHarness()
        let command = harness.arithmetic(.add, ["a": 2, "b": 3], key: "retry-1")

        let first = try await harness.service.execute(command)
        let second = try await harness.service.execute(command)

        guard case .executed(let original) = first, case .replayed(let replayed) = second else {
            Issue.record("Expected an execution followed by a replay, got \(first) and \(second)")
            return
        }
        #expect(replayed == original)
        #expect(await harness.repository.recordCount == 1)
        #expect(await harness.repository.saveAttempts == 1)
        #expect(await harness.events.eventNames == ["CalculationRequested", "CalculationCompleted"])
    }

    @Test("replays failed calculations exactly like successful ones")
    func replaysFailures() async throws {
        let harness = try ServiceHarness()
        let command = harness.arithmetic(.divide, ["dividend": 1, "divisor": 0], key: "retry-2")

        let first = try await harness.service.execute(command).record
        let second = try await harness.service.execute(command)

        #expect(second == .replayed(first))
        #expect(first.status == .failed)
    }

    @Test("rejects a key reused for a different request")
    func rejectsKeyReuse() async throws {
        let harness = try ServiceHarness()
        _ = try await harness.service.execute(
            harness.arithmetic(.add, ["a": 1, "b": 1], key: "shared", fingerprint: "one")
        )

        let failure = await #expect(throws: ExecutionFailure.self) {
            try await harness.service.execute(
                harness.arithmetic(.add, ["a": 9, "b": 9], key: "shared", fingerprint: "two")
            )
        }

        #expect(failure == .idempotencyConflict(IdempotencyKey("shared")))
        #expect(failure?.code == .idempotencyKeyReused)
        #expect(failure?.classification == .application)
        #expect(await harness.repository.recordCount == 1)
    }

    @Test("converges concurrent retries on one record and discards the losers")
    func convergesRaces() async throws {
        let harness = try ServiceHarness()
        let command = harness.arithmetic(.add, ["a": 2, "b": 3], key: "race")
        let attempts = 8

        let results = await withTaskGroup(of: ExecutionResult?.self) { group in
            for _ in 0..<attempts {
                group.addTask { try? await harness.service.execute(command) }
            }
            return await group.reduce(into: [ExecutionResult?]()) { $0.append($1) }
        }.compactMap { $0 }

        let executed = results.filter { if case .executed = $0 { true } else { false } }
        #expect(results.count == attempts)
        #expect(executed.count == 1, "exactly one request may win")
        #expect(Set(results.map(\.record.id)).count == 1, "everyone must see the winner's record")
        #expect(await harness.repository.recordCount == 1)

        let names = await harness.events.eventNames
        #expect(
            names.filter { $0 == "CalculationRequested" }.count == names.count
                - names.filter { $0 == "CalculationRequested" }.count
        )
    }

    @Test("reports a storage failure while checking an idempotency key before anything starts")
    func keyLookupFailure() async throws {
        let harness = try ServiceHarness()
        await harness.repository.failNextCalls(with: .timeout)

        let failure = await #expect(throws: ExecutionFailure.self) {
            try await harness.service.execute(harness.arithmetic(.add, ["a": 1, "b": 1], key: "lookup"))
        }

        #expect(failure == .storage(.timeout))
        #expect(await harness.events.events.isEmpty)
    }

    // MARK: - Batches

    @Test("returns batch results in order and isolates failures")
    func batchOrderAndIsolation() async throws {
        let harness = try ServiceHarness()
        let commands = [
            harness.arithmetic(.add, ["a": 1, "b": 2]),
            harness.divisionByZero,
            harness.arithmetic(.add, ["a": "bad"]),
            harness.arithmetic(.multiply, ["a": 3, "b": 4]),
        ]

        let results = await harness.service.executeBatch(commands, maximumConcurrency: 4)

        #expect(results.count == 4)
        #expect(try results[0].get().record.outcome == .succeeded(.number(3)))
        #expect(try results[1].get().record.status == .failed)
        #expect(results[2].failure?.code == .validationFailed)
        #expect(try results[3].get().record.outcome == .succeeded(.number(12)))
        #expect(await harness.repository.recordCount == 3)
    }

    @Test("never runs more calculations at once than the concurrency limit")
    func batchConcurrencyLimit() async throws {
        let harness = try ServiceHarness()
        let commands = Array(repeating: harness.fixture(.hold), count: 6)

        let batch = Task { await harness.service.executeBatch(commands, maximumConcurrency: 2) }
        await harness.controls.probe.waitUntilRunning(atLeast: 2)
        for _ in 0..<200 {
            await Task.yield()
        }
        await harness.controls.gate.open()
        let results = await batch.value

        #expect(await harness.controls.probe.maximum == 2)
        #expect(results.count == 6)
        #expect(results.allSatisfy { (try? $0.get().record.status) == .succeeded })
    }

    @Test("handles an empty batch")
    func emptyBatch() async throws {
        let harness = try ServiceHarness()

        let results = await harness.service.executeBatch([], maximumConcurrency: 4)

        #expect(results.isEmpty)
    }

    @Test("treats a non-positive concurrency limit as one")
    func degenerateConcurrency() async throws {
        let harness = try ServiceHarness()

        let results = await harness.service.executeBatch([harness.addition, harness.addition], maximumConcurrency: 0)

        #expect(results.count == 2)
        #expect(results.allSatisfy { (try? $0.get()) != nil })
    }

    // MARK: - Invariants

    @Test("every requested event is followed by exactly one terminal event on every path")
    func eventAccounting() async throws {
        let harness = try ServiceHarness()
        let commands = [
            harness.addition,
            harness.divisionByZero,
            harness.fixture(.crash),
            harness.fixture(.infinity),
        ]

        _ = await harness.service.executeBatch(commands, maximumConcurrency: 1)

        let events = await harness.events.events
        let requested = events.filter { if case .requested = $0 { true } else { false } }
        let terminal = events.filter { if case .requested = $0 { false } else { true } }
        #expect(requested.count == commands.count)
        #expect(Set(terminal.map(\.calculationID)) == Set(requested.map(\.calculationID)))
        #expect(terminal.count == requested.count)
    }

    @Test("execution failures expose stable codes and classifications")
    func failureMetadata() {
        #expect(ExecutionFailure.cancelled.code == .calculationCancelled)
        #expect(ExecutionFailure.defect(reason: "x").code == .internalError)
        #expect(ExecutionFailure.rejected(.numericOverflow).code == .numericOverflow)
        #expect(ExecutionFailure.rejected(.invalidParameter("a", reason: "bad")).details.count == 1)
        #expect(ExecutionFailure.storage(.corrupted(reason: "x")).code == .storageFailure)
    }
}
