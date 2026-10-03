extension ErrorCode {
    /// An idempotency key was reused for a request with different content.
    public static let idempotencyKeyReused = ErrorCode("IDEMPOTENCY_KEY_REUSED")

    /// A concurrent request with the same idempotency key won the race, so this one was discarded.
    public static let duplicateSuppressed = ErrorCode("DUPLICATE_SUPPRESSED")
}

/// A request to compute something, together with how it should be traced and deduplicated.
public struct ExecuteCalculation: Sendable, Equatable {
    /// What to compute.
    public let request: CalculationRequest

    /// The client's idempotency key and the fingerprint of the request, when it supplied a key.
    public let idempotency: IdempotencyClaim?

    /// The identifiers of the HTTP exchange that asked for it.
    public let trace: TraceContext

    /// Creates the command.
    ///
    /// - Parameters:
    ///   - request: What to compute.
    ///   - idempotency: The client's idempotency key and the fingerprint of the request.
    ///   - trace: The identifiers of the HTTP exchange that asked for it.
    public init(
        request: CalculationRequest,
        idempotency: IdempotencyClaim? = nil,
        trace: TraceContext
    ) {
        self.request = request
        self.idempotency = idempotency
        self.trace = trace
    }
}

/// What executing a command produced.
public enum ExecutionResult: Sendable, Equatable {
    /// The calculation ran now and its record was stored. A failed outcome is still an executed calculation.
    case executed(CalculationRecord)

    /// The idempotency key had been used by an identical request, so the stored record is returned and nothing ran.
    case replayed(CalculationRecord)

    /// The record, whether new or replayed.
    public var record: CalculationRecord {
        switch self {
        case .executed(let record), .replayed(let record):
            record
        }
    }
}

/// Why a command could not be executed at all.
///
/// A calculation that runs and fails — a division by zero, say — is *not* an `ExecutionFailure`: it is a recorded
/// outcome. These cases are the situations in which nothing was recorded.
public enum ExecutionFailure: Error, Sendable, Equatable {
    /// The request was refused before it ran: unknown calculation or invalid parameters.
    case rejected(CalculationError)

    /// The idempotency key was already used by a request with different content.
    case idempotencyConflict(IdempotencyKey)

    /// The calculation was cancelled before it finished.
    case cancelled

    /// A defect inside the engine. The reason is for logs and error reports only.
    case defect(reason: String)

    /// The history could not be read or written.
    case storage(RepositoryError)

    /// Stable identifier of the failure.
    public var code: ErrorCode {
        switch self {
        case .rejected(let error):
            error.code
        case .idempotencyConflict:
            .idempotencyKeyReused
        case .cancelled:
            .calculationCancelled
        case .defect:
            .internalError
        case .storage(let error):
            error.code
        }
    }

    /// Explanation that is safe to show to the caller.
    public var message: String {
        switch self {
        case .rejected(let error):
            error.message
        case .idempotencyConflict:
            "The idempotency key was already used with a different request."
        case .cancelled:
            CalculationError.cancelled.message
        case .defect:
            CalculationError.internalFailure(reason: "").message
        case .storage(let error):
            error.message
        }
    }

    /// Structured context, such as the parameters that failed validation.
    public var details: [ErrorDetail] {
        switch self {
        case .rejected(let error):
            error.details
        case .idempotencyConflict, .cancelled, .defect, .storage:
            []
        }
    }

    /// How logging, metrics and error reporting should treat the failure.
    public var classification: ErrorClassification {
        switch self {
        case .rejected(let error):
            error.classification
        case .idempotencyConflict, .cancelled:
            .application
        case .defect:
            .unexpected
        case .storage(let error):
            error.classification
        }
    }
}

/// Runs calculations and records what happened.
///
/// This is the main use case of the engine. It validates a request, runs it under a time budget, stores the outcome
/// — success or failure — publishes events about it, and makes retries safe through idempotency keys.
///
/// - **Idempotency:** a request with a key already bound to an identical request returns the stored record without
///   running again. The same key with different content is a conflict. Because calculations are pure and cheap, the
///   service does not reserve the key before computing; it computes, then stores the record and the key in one
///   transaction, and a request that loses a race simply returns the winner's record. That gives exactly-once
///   recording without in-progress states that could get stuck.
/// - **Events:** `requested` is published before the work starts and exactly one of `completed` or `failed` follows
///   once the outcome is known, whatever the path, so observers can account for every calculation.
/// - **Failures:** domain failures are recorded as results. Only requests refused before running, cancellations,
///   defects and storage failures surface as ``ExecutionFailure``.
public struct CalculationService: Sendable {
    private let engine: CalculationEngine
    private let repository: any CalculationRepository
    private let events: any EventPublisher
    private let clock: any EngineClock
    private let identifiers: any IdentifierGenerator

    /// Creates the service.
    ///
    /// - Parameters:
    ///   - engine: Validates and runs calculations.
    ///   - repository: Stores the history.
    ///   - events: Receives events about each calculation.
    ///   - clock: Provides the timestamps of records and events.
    ///   - identifiers: Creates the identifiers of records and events.
    public init(
        engine: CalculationEngine,
        repository: any CalculationRepository,
        events: any EventPublisher,
        clock: any EngineClock,
        identifiers: any IdentifierGenerator
    ) {
        self.engine = engine
        self.repository = repository
        self.events = events
        self.clock = clock
        self.identifiers = identifiers
    }

    /// Runs one calculation and records it.
    ///
    /// - Parameter command: What to compute and how to trace and deduplicate it.
    /// - Returns: The record of the calculation, newly executed or replayed from an earlier identical request.
    /// - Throws: ``ExecutionFailure`` when the request is refused, conflicts with an earlier one, is cancelled, hits a
    ///   defect, or cannot be stored.
    public func execute(_ command: ExecuteCalculation) async throws(ExecutionFailure) -> ExecutionResult {
        if let claim = command.idempotency, let replayed = try await replay(for: claim) {
            return replayed
        }

        let prepared = try prepare(command.request)
        let id = CalculationID(identifiers.next())
        await publish(.requested(requestedEvent(id, command)))

        let run = await engine.run(prepared)

        let outcome: CalculationOutcome
        do {
            outcome = try classify(run.result)
        } catch {
            await publish(
                .failed(failedEvent(id, command, code: error.code, classification: error.classification, run.duration))
            )
            throw error
        }

        let record = CalculationRecord(
            id: id,
            type: command.request.type,
            parameters: command.request.parameters,
            outcome: outcome,
            executionTime: run.duration,
            createdAt: clock.currentDate(),
            trace: command.trace
        )
        return try await store(record, command: command)
    }

    /// Runs many calculations concurrently and records each one independently.
    ///
    /// Concurrency is bounded so a large batch cannot exhaust the database connection pool. Results are returned in
    /// the order of the commands, whatever order they finish in; one failing item never affects the others.
    ///
    /// - Parameters:
    ///   - commands: The calculations to run.
    ///   - maximumConcurrency: How many calculations may be in flight at once.
    /// - Returns: One result per command, in the same order.
    public func executeBatch(
        _ commands: [ExecuteCalculation],
        maximumConcurrency: Int
    ) async -> [Result<ExecutionResult, ExecutionFailure>] {
        await withTaskGroup(of: (index: Int, result: Result<ExecutionResult, ExecutionFailure>).self) { group in
            var pending = commands.enumerated().makeIterator()
            var results = [Result<ExecutionResult, ExecutionFailure>?](repeating: nil, count: commands.count)

            func startNext() {
                guard let (index, command) = pending.next() else {
                    return
                }
                group.addTask { (index, await self.attempt(command)) }
            }

            for _ in 0..<min(max(maximumConcurrency, 1), commands.count) {
                startNext()
            }
            for await (index, result) in group {
                results[index] = result
                startNext()
            }
            return results.map { $0 ?? .failure(.cancelled) }
        }
    }

    // MARK: - Steps

    private func attempt(_ command: ExecuteCalculation) async -> Result<ExecutionResult, ExecutionFailure> {
        do {
            return .success(try await execute(command))
        } catch {
            return .failure(error)
        }
    }

    private func replay(for claim: IdempotencyClaim) async throws(ExecutionFailure) -> ExecutionResult? {
        let existing: IdempotentRecord?
        do {
            existing = try await repository.record(for: claim.key)
        } catch {
            throw .storage(error)
        }

        guard let existing else {
            return nil
        }
        return try resolve(existing, for: claim)
    }

    private func resolve(
        _ existing: IdempotentRecord,
        for claim: IdempotencyClaim
    ) throws(ExecutionFailure) -> ExecutionResult {
        guard existing.fingerprint == claim.fingerprint else {
            throw .idempotencyConflict(claim.key)
        }
        return .replayed(existing.record)
    }

    private func prepare(_ request: CalculationRequest) throws(ExecutionFailure) -> PreparedCalculation {
        do {
            return try engine.prepare(request)
        } catch {
            throw .rejected(error)
        }
    }

    private func classify(
        _ result: Result<CalculationValue, CalculationError>
    ) throws(ExecutionFailure) -> CalculationOutcome {
        switch result {
        case .success(let value):
            return .succeeded(value)
        case .failure(.cancelled):
            throw .cancelled
        case .failure(.internalFailure(let reason)):
            throw .defect(reason: reason)
        case .failure(let error):
            return .failed(RecordedFailure(error))
        }
    }

    private func store(
        _ record: CalculationRecord,
        command: ExecuteCalculation
    ) async throws(ExecutionFailure) -> ExecutionResult {
        let saved: SaveResult
        do {
            saved = try await repository.save(record, claiming: command.idempotency)
        } catch {
            let failure = ExecutionFailure.storage(error)
            await publish(
                .failed(
                    failedEvent(
                        record.id,
                        command,
                        code: failure.code,
                        classification: failure.classification,
                        record.executionTime
                    )
                )
            )
            throw failure
        }

        switch saved {
        case .created:
            await publish(terminalEvent(for: record, command: command))
            return .executed(record)
        case .duplicate(let existing):
            await publish(
                .failed(
                    failedEvent(
                        record.id,
                        command,
                        code: .duplicateSuppressed,
                        classification: .application,
                        record.executionTime
                    )
                )
            )
            guard let claim = command.idempotency else {
                throw .defect(reason: "The repository reported a duplicate for a request without an idempotency key")
            }
            return try resolve(existing, for: claim)
        }
    }

    // MARK: - Events

    private func publish(_ event: CalculationEvent) async {
        await events.publish(event)
    }

    private func requestedEvent(
        _ id: CalculationID,
        _ command: ExecuteCalculation
    ) -> CalculationRequested {
        CalculationRequested(
            eventID: identifiers.next(),
            occurredAt: clock.currentDate(),
            calculationID: id,
            type: command.request.type,
            trace: command.trace
        )
    }

    private func terminalEvent(
        for record: CalculationRecord,
        command: ExecuteCalculation
    ) -> CalculationEvent {
        switch record.outcome {
        case .succeeded:
            .completed(
                CalculationCompleted(
                    eventID: identifiers.next(),
                    occurredAt: clock.currentDate(),
                    calculationID: record.id,
                    type: record.type,
                    executionTime: record.executionTime,
                    trace: command.trace
                )
            )
        case .failed(let failure):
            .failed(
                failedEvent(
                    record.id,
                    command,
                    code: failure.code,
                    classification: .expectedDomain,
                    record.executionTime
                )
            )
        }
    }

    private func failedEvent(
        _ id: CalculationID,
        _ command: ExecuteCalculation,
        code: ErrorCode,
        classification: ErrorClassification,
        _ executionTime: Duration
    ) -> CalculationFailed {
        CalculationFailed(
            eventID: identifiers.next(),
            occurredAt: clock.currentDate(),
            calculationID: id,
            type: command.request.type,
            code: code,
            classification: classification,
            executionTime: executionTime,
            trace: command.trace
        )
    }
}
