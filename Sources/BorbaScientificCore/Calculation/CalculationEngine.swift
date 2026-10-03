/// What a caller asks the engine to compute.
public struct CalculationRequest: Sendable, Equatable {
    /// Which calculation to run.
    public let type: CalculationType

    /// Raw parameters by wire name, validated against the operation's declarations before anything runs.
    public let parameters: [String: CalculationValue]

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - type: Which calculation to run.
    ///   - parameters: Raw parameters by wire name.
    public init(
        type: CalculationType,
        parameters: [String: CalculationValue]
    ) {
        self.type = type
        self.parameters = parameters
    }
}

/// A request that has been resolved and validated and is ready to run.
///
/// Splitting preparation from execution lets callers reject bad requests before they record anything, and gives
/// the execution step a clean place to enforce the time budget.
public struct PreparedCalculation: Sendable {
    /// Which calculation will run.
    public let type: CalculationType

    let definition: OperationDefinition
    let arguments: Arguments

    func perform() async -> Result<CalculationValue, CalculationError> {
        do {
            let value = try await definition.compute(arguments)

            if let offender = value.firstNonFiniteNumber {
                return .failure(offender.isNaN ? .undefined("The result is not a number.") : .numericOverflow)
            }
            return .success(value)
        } catch {
            return .failure(CalculationError(escaping: error))
        }
    }
}

/// The outcome of running a prepared calculation, with how long it took.
public struct CalculationRun: Sendable {
    /// The computed value, or why there is none.
    public let result: Result<CalculationValue, CalculationError>

    /// Time spent computing, measured on the engine's monotonic clock.
    public let duration: Duration
}

/// Validates and runs calculations under a time budget.
///
/// The engine knows nothing about HTTP, persistence or events: it turns a ``CalculationRequest`` into a
/// ``CalculationRun``. Failures that the caller can cause are values, never thrown from ``run(_:)``.
public struct CalculationEngine: Sendable {
    private let registry: ModuleRegistry
    private let clock: any EngineClock
    private let timeout: Duration

    /// Creates an engine.
    ///
    /// - Parameters:
    ///   - registry: The modules that can be run.
    ///   - clock: Time source for measuring and for the time budget.
    ///   - timeout: Longest a single calculation may run before it is cancelled.
    public init(
        registry: ModuleRegistry,
        clock: any EngineClock,
        timeout: Duration
    ) {
        self.registry = registry
        self.clock = clock
        self.timeout = timeout
    }

    /// The registry the engine runs calculations from.
    public var modules: ModuleRegistry {
        registry
    }

    /// Resolves the operation and validates the parameters, without running anything.
    ///
    /// - Parameter request: What the caller asked for.
    /// - Returns: A calculation ready to run.
    /// - Throws: ``CalculationError/unsupportedOperation(_:)`` or ``CalculationError/validation(_:)``.
    public func prepare(_ request: CalculationRequest) throws(CalculationError) -> PreparedCalculation {
        let definition: OperationDefinition
        do {
            definition = try registry.definition(for: request.type)
        } catch {
            throw .unsupportedOperation(error)
        }

        do {
            let arguments = try definition.bind(request.parameters)
            return PreparedCalculation(type: request.type, definition: definition, arguments: arguments)
        } catch {
            throw .validation(error)
        }
    }

    /// Runs a prepared calculation, cancelling it when the time budget is exhausted.
    ///
    /// The budget is enforced cooperatively: code that never yields (a loop without
    /// ``Cooperation/checkpoint(iteration:)``) cannot be interrupted and delays the return until it finishes.
    ///
    /// - Parameter prepared: The calculation to run.
    /// - Returns: The result and how long it took. Cancellation of the calling task yields
    ///   ``CalculationError/cancelled``.
    public func run(_ prepared: PreparedCalculation) async -> CalculationRun {
        let startedAt = clock.uptime()
        let result = await withinTimeBudget { await prepared.perform() }

        return CalculationRun(result: result, duration: clock.uptime() - startedAt)
    }

    /// Prepares and runs a request in one step.
    ///
    /// - Parameter request: What the caller asked for.
    /// - Returns: The result and how long it took.
    /// - Throws: ``CalculationError/unsupportedOperation(_:)`` or ``CalculationError/validation(_:)`` when the
    ///   request is rejected before running.
    public func execute(_ request: CalculationRequest) async throws(CalculationError) -> CalculationRun {
        await run(try prepare(request))
    }

    /// Races the work against a watchdog that fires when the time budget is spent.
    ///
    /// - Parameter work: The computation to run.
    /// - Returns: The work's result, or ``CalculationError/timedOut(limit:)`` when the watchdog won the race.
    private func withinTimeBudget(
        _ work: @escaping @Sendable () async -> Result<CalculationValue, CalculationError>
    ) async -> Result<CalculationValue, CalculationError> {
        let clock = clock
        let timeout = timeout

        return await withTaskGroup(of: Result<CalculationValue, CalculationError>?.self) { group in
            group.addTask { await work() }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                    return .failure(.timedOut(limit: timeout))
                } catch {
                    // The watchdog was cancelled because the work finished first.
                    return nil
                }
            }

            var outcome: Result<CalculationValue, CalculationError> = .failure(.cancelled)
            for await finished in group {
                if let finished {
                    outcome = finished
                    group.cancelAll()
                    break
                }
            }
            return outcome
        }
    }
}
