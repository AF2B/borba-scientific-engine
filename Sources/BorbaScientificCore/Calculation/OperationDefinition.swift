/// Everything the engine needs to know about one operation: how to describe it, how to validate its parameters and
/// how to compute it.
public struct OperationDefinition: Sendable {
    /// Name of the operation inside its module.
    public let name: OperationName

    /// One-sentence description of what the operation computes.
    public let summary: String

    /// The parameters the operation accepts.
    public let parameters: [any ParameterDeclaration]

    /// Structure of the result.
    public let result: ValueShape

    /// Worked examples, executed by the unit tests.
    public let examples: [OperationExample]

    let compute: @Sendable (Arguments) async throws -> CalculationValue

    /// Creates an operation.
    ///
    /// - Parameters:
    ///   - name: Name of the operation, usually a case of the module's operation enumeration.
    ///   - summary: One-sentence description of what the operation computes.
    ///   - parameters: The parameters the operation accepts, in documentation order.
    ///   - result: Structure of the result.
    ///   - examples: Worked examples that double as tests.
    ///   - compute: The business rule. It receives validated arguments and may throw any ``CalculationFailure``;
    ///     long-running loops must call ``Cooperation/checkpoint(iteration:)`` so the time budget can be enforced.
    public init(
        name: some RawRepresentable<String>,
        summary: String,
        parameters: [any ParameterDeclaration],
        result: ValueShape,
        examples: [OperationExample] = [],
        compute: @escaping @Sendable (Arguments) async throws -> CalculationValue
    ) {
        self.name = OperationName(name.rawValue)
        self.summary = summary
        self.parameters = parameters
        self.result = result
        self.examples = examples
        self.compute = compute
    }

    /// Validates raw parameters against the declarations.
    ///
    /// Every problem is collected, so a caller can fix a whole request in one round trip. Parameters that are not
    /// declared are rejected rather than silently ignored.
    ///
    /// - Parameter rawParameters: Parameters as supplied by the caller.
    /// - Returns: The validated arguments, with defaults applied.
    /// - Throws: ``ValidationError`` listing every problem.
    func bind(_ rawParameters: [String: CalculationValue]) throws(ValidationError) -> Arguments {
        var bound: [String: any Sendable] = [:]
        var issues: [ValidationIssue] = []

        for declaration in parameters {
            let name = declaration.descriptor.name
            do {
                bound[name] = try declaration.bind(rawParameters[name])
            } catch {
                issues.append(ValidationIssue(parameter: name, reason: error.reason))
            }
        }

        let declared = Set(parameters.map { $0.descriptor.name })
        for unknown in rawParameters.keys.filter({ !declared.contains($0) }).sorted() {
            issues.append(ValidationIssue(parameter: unknown, reason: "is not a parameter of this operation"))
        }

        guard issues.isEmpty else {
            throw ValidationError(issues: issues)
        }
        return Arguments(bound: bound)
    }
}
