import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("CalculationEngine")
struct CalculationEngineTests {
    private static let timeLimit = Duration.seconds(2)
    private static let moduleName = ModuleName("fixture")

    private func makeEngine(clock: ManualClock) throws -> CalculationEngine {
        CalculationEngine(
            registry: try ModuleRegistry(modules: [FixtureModule(clock: clock)]),
            clock: clock,
            timeout: Self.timeLimit
        )
    }

    private func request(
        _ operation: FixtureOperation,
        _ parameters: [String: CalculationValue] = [:]
    ) -> CalculationRequest {
        CalculationRequest(
            type: CalculationType(module: Self.moduleName, operation: OperationName(operation.rawValue)),
            parameters: parameters
        )
    }

    @Test("runs a valid request and returns its value")
    func runsValidRequest() async throws {
        let engine = try makeEngine(clock: ManualClock())

        let run = try await engine.execute(request(.echo, [FixtureParameters.value.name: 3]))

        #expect(run.result == .success(.number(3)))
    }

    @Test("rejects an unknown module before running anything")
    func rejectsUnknownModule() async throws {
        let engine = try makeEngine(clock: ManualClock())
        let unknown = CalculationType(module: ModuleName("missing"), operation: OperationName("echo"))

        let error = #expect(throws: CalculationError.self) {
            try engine.prepare(CalculationRequest(type: unknown, parameters: [:]))
        }

        #expect(error == .unsupportedOperation(UnsupportedOperationError(type: unknown)))
    }

    @Test("rejects an unknown operation of a known module")
    func rejectsUnknownOperation() async throws {
        let engine = try makeEngine(clock: ManualClock())
        let unknown = CalculationType(module: Self.moduleName, operation: OperationName("missing"))

        #expect(throws: CalculationError.unsupportedOperation(UnsupportedOperationError(type: unknown))) {
            try engine.prepare(CalculationRequest(type: unknown, parameters: [:]))
        }
    }

    @Test("reports every validation problem in one response")
    func reportsEveryIssue() async throws {
        let engine = try makeEngine(clock: ManualClock())

        let error = #expect(throws: CalculationError.self) {
            try engine.prepare(request(.echo, ["extra": 1, "another": 2]))
        }

        guard case .validation(let validation)? = error else {
            Issue.record("Expected a validation error, got \(String(describing: error))")
            return
        }
        #expect(validation.issues.map(\.parameter) == ["value", "another", "extra"])
        #expect(error?.code == .validationFailed)
        #expect(error?.classification == .expectedDomain)
    }

    @Test("measures the duration on the engine clock")
    func measuresDuration() async throws {
        let clock = ManualClock()
        let engine = try makeEngine(clock: clock)
        let prepared = try engine.prepare(request(.sleep, [FixtureParameters.seconds.name: 1]))

        let run = Task { await engine.run(prepared) }
        await clock.waitUntilSleeping(count: 2)
        clock.advance(by: .seconds(1))
        let outcome = await run.value

        #expect(outcome.result == .success(.number(1)))
        #expect(outcome.duration == .seconds(1))
    }

    @Test("stops a calculation that exhausts its time budget")
    func enforcesTimeBudget() async throws {
        let clock = ManualClock()
        let engine = try makeEngine(clock: clock)
        let prepared = try engine.prepare(request(.sleep, [FixtureParameters.seconds.name: 10]))

        let run = Task { await engine.run(prepared) }
        await clock.waitUntilSleeping(count: 2)
        clock.advance(by: Self.timeLimit)
        let outcome = await run.value

        #expect(outcome.result == .failure(.timedOut(limit: Self.timeLimit)))
        #expect(outcome.duration == Self.timeLimit)
        #expect(CalculationError.timedOut(limit: Self.timeLimit).code == .calculationTimeout)
    }

    @Test("propagates cancellation into running calculations")
    func propagatesCancellation() async throws {
        let engine = try makeEngine(clock: ManualClock())
        let prepared = try engine.prepare(request(.spin))

        let run = Task { await engine.run(prepared) }
        run.cancel()
        let outcome = await run.value

        #expect(outcome.result == .failure(.cancelled))
    }

    @Test("reports unexpected errors as defects without leaking details")
    func reportsDefects() async throws {
        let engine = try makeEngine(clock: ManualClock())

        let run = try await engine.execute(request(.crash))

        guard case .failure(let error) = run.result else {
            Issue.record("Expected a failure")
            return
        }
        #expect(error.code == .internalError)
        #expect(error.classification == .unexpected)
        #expect(error.message == "An unexpected error occurred.")
    }

    @Test("rejects results that are not finite numbers")
    func rejectsNonFiniteResults() async throws {
        let engine = try makeEngine(clock: ManualClock())

        let overflow = try await engine.execute(request(.infinity))
        let undefined = try await engine.execute(request(.notANumber))

        #expect(overflow.result == .failure(.numericOverflow))
        #expect(undefined.result == .failure(.undefined("The result is not a number.")))
    }
}
