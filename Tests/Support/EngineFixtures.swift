public import BorbaScientificCore

extension CalculationEngine {
    /// An engine over every built-in module, running on a frozen clock so a time budget never fires by accident.
    ///
    /// - Parameters:
    ///   - clock: The clock the engine measures and enforces its time budget with.
    ///   - timeout: The time budget of a single calculation.
    /// - Returns: The engine.
    public static func standard(
        clock: any EngineClock = ManualClock(),
        timeout: Duration = .seconds(30)
    ) -> CalculationEngine {
        CalculationEngine(registry: .standard(), clock: clock, timeout: timeout)
    }

    /// Prepares and runs a calculation, returning only its outcome.
    ///
    /// - Parameters:
    ///   - module: The module that owns the operation.
    ///   - operation: The operation, usually a case of the module's operation enumeration.
    ///   - parameters: Raw parameters by wire name.
    /// - Returns: The computed value or the failure.
    /// - Throws: ``CalculationError`` when the request is rejected before it runs.
    public func calculate(
        _ module: ModuleName,
        _ operation: some RawRepresentable<String>,
        _ parameters: [String: CalculationValue] = [:]
    ) async throws(CalculationError) -> Result<CalculationValue, CalculationError> {
        let type = CalculationType(module: module, operation: OperationName(operation.rawValue))

        return try await execute(CalculationRequest(type: type, parameters: parameters)).result
    }
}
