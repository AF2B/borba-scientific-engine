import BorbaScientificCore
import Logging
import TestSupport
import Testing

@testable import BorbaScientificEngine

/// A repository that fails as scripted and counts how often it is called.
private actor ScriptedRepository: CalculationRepository {
    private var failures: [RepositoryError]
    private(set) var calls = 0

    init(failures: [RepositoryError]) {
        self.failures = failures
    }

    private func next() -> RepositoryError? {
        calls += 1
        return failures.isEmpty ? nil : failures.removeFirst()
    }

    func save(
        _ record: CalculationRecord,
        claiming claim: IdempotencyClaim?
    ) async throws(RepositoryError) -> SaveResult {
        if let failure = next() {
            throw failure
        }
        return .created
    }

    func record(for key: IdempotencyKey) async throws(RepositoryError) -> IdempotentRecord? {
        if let failure = next() {
            throw failure
        }
        return nil
    }

    func find(id: CalculationID) async throws(RepositoryError) -> CalculationRecord? {
        if let failure = next() {
            throw failure
        }
        return RecordFixtures.record(sequence: 1)
    }

    func list(
        matching filter: HistoryFilter,
        page: PageRequest
    ) async throws(RepositoryError) -> Page<CalculationRecord> {
        if let failure = next() {
            throw failure
        }
        return Page(items: [], nextCursor: nil)
    }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {
    private let policy = RetryPolicy.standard

    @Test("grows the longest wait geometrically and caps it")
    func ceilings() {
        #expect(policy.ceiling(afterAttempt: 1) == .milliseconds(50))
        #expect(policy.ceiling(afterAttempt: 2) == .milliseconds(200))
        #expect(policy.ceiling(afterAttempt: 3) == .milliseconds(800))
        #expect(policy.ceiling(afterAttempt: 4) == .seconds(1))
        #expect(policy.ceiling(afterAttempt: 10) == .seconds(1))
    }

    @Test("waits a random fraction of the ceiling, never outside it")
    func jitter() {
        #expect(policy.delay(afterAttempt: 2, fraction: 0.5) == .milliseconds(100))
        #expect(policy.delay(afterAttempt: 2, fraction: 0) == .zero)
        #expect(policy.delay(afterAttempt: 2, fraction: 1) == .milliseconds(200))
        #expect(policy.delay(afterAttempt: 2, fraction: 7) == .milliseconds(200))
        #expect(policy.delay(afterAttempt: 2, fraction: -3) == .zero)
    }

    @Test("retries only a store that cannot be reached")
    func retryableErrors() {
        #expect(policy.shouldRetry(.unavailable(reason: "refused")))
        #expect(!policy.shouldRetry(.timeout))
        #expect(!policy.shouldRetry(.integrity(reason: "constraint")))
        #expect(!policy.shouldRetry(.corrupted(reason: "bad row")))
        #expect(!policy.shouldRetry(.unexpected(reason: "?")))
    }
}

@Suite("RetryingCalculationRepository", .timeLimit(.minutes(1)))
struct RetryingCalculationRepositoryTests {
    private static let unavailable = RepositoryError.unavailable(reason: "connection refused")
    private static let idempotencyClaim = IdempotencyClaim(
        key: IdempotencyKey("key-1"),
        fingerprint: RequestFingerprint("sha256:abc")
    )

    private func decorate(
        _ base: ScriptedRepository,
        clock: any EngineClock = RecordingSleepClock(),
        fraction: Double = 1
    ) -> RetryingCalculationRepository {
        RetryingCalculationRepository(
            base: base,
            policy: .standard,
            clock: clock,
            logger: Logger(label: "test"),
            randomFraction: { fraction }
        )
    }

    private static func failure(of repository: RetryingCalculationRepository) async -> RepositoryError? {
        do {
            _ = try await repository.find(id: RecordFixtures.id(1))
            return nil
        } catch {
            return error
        }
    }

    @Test("succeeds when a retry gets through, waiting the policy's delays in between")
    func retriesReads() async throws {
        let base = ScriptedRepository(failures: [Self.unavailable, Self.unavailable])
        let clock = RecordingSleepClock()

        let record = try await decorate(base, clock: clock).find(id: RecordFixtures.id(1))

        #expect(record != nil)
        #expect(await base.calls == 3)
        #expect(clock.sleeps == [.milliseconds(50), .milliseconds(200)])
    }

    @Test("uses the jitter it is given")
    func appliesJitter() async throws {
        let base = ScriptedRepository(failures: [Self.unavailable])
        let clock = RecordingSleepClock()

        _ = try await decorate(base, clock: clock, fraction: 0.5).list(matching: HistoryFilter(), page: PageRequest())

        #expect(clock.sleeps == [.milliseconds(25)])
    }

    @Test("gives up after the last attempt and reports the last failure")
    func givesUp() async {
        let base = ScriptedRepository(failures: Array(repeating: Self.unavailable, count: 5))

        let error = await #expect(throws: RepositoryError.self) {
            try await decorate(base).record(for: IdempotencyKey("key"))
        }

        #expect(error == Self.unavailable)
        #expect(await base.calls == RetryPolicy.standard.maximumAttempts)
    }

    @Test(
        "does not retry failures that repeating cannot fix",
        arguments: [
            RepositoryError.timeout,
            .integrity(reason: "constraint"),
            .corrupted(reason: "bad row"),
            .unexpected(reason: "?"),
        ]
    )
    func doesNotRetryOtherFailures(failure: RepositoryError) async {
        let base = ScriptedRepository(failures: [failure, failure, failure])

        await #expect(throws: RepositoryError.self) {
            try await decorate(base).find(id: RecordFixtures.id(1))
        }

        #expect(await base.calls == 1)
    }

    @Test("attempts a save without an idempotency claim only once, because repeating it could store it twice")
    func doesNotRetryUnsafeSaves() async {
        let base = ScriptedRepository(failures: [Self.unavailable])

        await #expect(throws: RepositoryError.self) {
            try await decorate(base).save(RecordFixtures.record(sequence: 1), claiming: nil)
        }

        #expect(await base.calls == 1)
    }

    @Test("retries a save that carries an idempotency claim, because a repeat returns the stored record")
    func retriesIdempotentSaves() async throws {
        let base = ScriptedRepository(failures: [Self.unavailable])

        let result = try await decorate(base).save(RecordFixtures.record(sequence: 1), claiming: Self.idempotencyClaim)

        #expect(result == .created)
        #expect(await base.calls == 2)
    }

    @Test("stops waiting when the task is cancelled and reports the failure it had")
    func stopsWhenCancelled() async {
        let base = ScriptedRepository(failures: [Self.unavailable, Self.unavailable])
        let clock = ManualClock()
        let repository = decorate(base, clock: clock)

        let task = Task { await Self.failure(of: repository) }
        await clock.waitUntilSleeping()
        task.cancel()

        #expect(await task.value == Self.unavailable)
        #expect(await base.calls == 1, "no further attempt after cancellation")
    }
}
