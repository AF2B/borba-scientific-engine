/// A worked example of an operation: documentation that the unit tests execute, so it can never drift from the
/// implementation.
public struct OperationExample: Sendable, Equatable {
    /// Relative tolerance used when comparing floating-point results with the documented ones.
    public static let tolerance = 1e-9

    /// What the example demonstrates.
    public let summary: String

    /// Parameters of the example request, by wire name.
    public let parameters: [String: CalculationValue]

    /// The result the example request produces.
    public let result: CalculationValue

    /// Creates an example.
    ///
    /// - Parameters:
    ///   - summary: What the example demonstrates.
    ///   - arguments: The parameter declarations paired with the values the example supplies.
    ///   - result: The result the example request produces.
    public init(
        _ summary: String,
        with arguments: [(parameter: any ParameterDeclaration, value: CalculationValue)],
        yields result: CalculationValue
    ) {
        self.summary = summary
        self.parameters = Dictionary(
            arguments.map { ($0.parameter.descriptor.name, $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.result = result
    }

    /// Whether an actual result matches the documented one, allowing for floating-point rounding.
    ///
    /// - Parameter actual: The result the engine produced.
    /// - Returns: `true` when both have the same structure and numbers agree within ``tolerance``.
    public func isSatisfied(by actual: CalculationValue) -> Bool {
        Self.matches(expected: result, actual: actual)
    }

    private static func matches(
        expected: CalculationValue,
        actual: CalculationValue
    ) -> Bool {
        switch (expected, actual) {
        case (.number(let lhs), .number(let rhs)):
            abs(lhs - rhs) <= tolerance * max(1, abs(lhs))
        case (.list(let lhs), .list(let rhs)):
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { matches(expected: $0, actual: $1) }
        case (.object(let lhs), .object(let rhs)):
            Set(lhs.keys) == Set(rhs.keys)
                && lhs.allSatisfy { key, value in rhs[key].map { matches(expected: value, actual: $0) } ?? false }
        default:
            expected == actual
        }
    }

    /// Compares the documented fields only, so metadata comparisons ignore the closure-free parts that matter.
    public static func == (lhs: OperationExample, rhs: OperationExample) -> Bool {
        lhs.summary == rhs.summary && lhs.parameters == rhs.parameters && lhs.result == rhs.result
    }
}
