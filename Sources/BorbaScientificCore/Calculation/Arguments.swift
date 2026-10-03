/// The validated parameters of one calculation, read through the same typed declarations that validated them.
///
/// By the time an operation receives its `Arguments`, every required parameter is present, every optional one has
/// its default applied and every value satisfies its constraints, so operations contain business rules only.
public struct Arguments: Sendable {
    private let bound: [String: any Sendable]

    init(bound: [String: any Sendable]) {
        self.bound = bound
    }

    /// Reads a validated parameter.
    ///
    /// - Parameter parameter: The declaration the operation lists in its parameters.
    /// - Returns: The typed value.
    /// - Throws: ``CalculationError/internalFailure(reason:)`` when the operation reads a parameter it did not
    ///   declare. That is a programming error, which the unit tests of every operation catch.
    public subscript<Value: Sendable>(_ parameter: ParameterSpec<Value>) -> Value {
        get throws(CalculationError) {
            guard let value = bound[parameter.name] as? Value else {
                throw .internalFailure(reason: "Parameter '\(parameter.name)' is read but not declared")
            }
            return value
        }
    }
}
