public import BorbaScientificCore

/// Parameters of the fixture module.
public enum FixtureParameters {
    /// A number echoed by ``FixtureOperation/echo``.
    public static let value = ParameterSpec.number("value", summary: "A number.")

    /// How long ``FixtureOperation/sleep`` waits, in seconds.
    public static let seconds = ParameterSpec.number("seconds", summary: "Seconds to sleep.", default: 0)
}

/// Operations of the fixture module.
public enum FixtureOperation: String, CaseIterable {
    case echo
    case sleep
    case infinity
    case notANumber = "not_a_number"
    case crash
    case spin
}

/// An error that is not a ``CalculationFailure``, standing in for a bug inside an operation.
public struct FixtureDefect: Error {}

/// A small module with deliberately misbehaving operations, used to exercise the engine's guarantees.
public struct FixtureModule: CalculationModule {
    /// Name of the module.
    public let name = ModuleName("fixture")

    /// Description of the module.
    public let summary = "Operations that exercise the engine."

    /// The operations of the module.
    public let operations: [OperationDefinition]

    /// Creates the module.
    ///
    /// - Parameter clock: The clock the sleeping operation waits on.
    public init(clock: any EngineClock) {
        let value = FixtureParameters.value
        let seconds = FixtureParameters.seconds

        operations = [
            OperationDefinition(
                name: FixtureOperation.echo,
                summary: "Returns its input.",
                parameters: [value],
                result: .number,
                compute: { arguments in .number(try arguments[value]) }
            ),
            OperationDefinition(
                name: FixtureOperation.sleep,
                summary: "Waits on the clock, honouring cancellation.",
                parameters: [seconds],
                result: .number,
                compute: { arguments in
                    let duration = try arguments[seconds]
                    try await clock.sleep(for: .seconds(duration))
                    return .number(duration)
                }
            ),
            OperationDefinition(
                name: FixtureOperation.infinity,
                summary: "Produces an infinite result.",
                parameters: [],
                result: .number,
                compute: { _ in .number(.infinity) }
            ),
            OperationDefinition(
                name: FixtureOperation.notANumber,
                summary: "Produces a NaN result.",
                parameters: [],
                result: .number,
                compute: { _ in .list([.number(.nan)]) }
            ),
            OperationDefinition(
                name: FixtureOperation.crash,
                summary: "Throws an error that is not a calculation failure.",
                parameters: [],
                result: .number,
                compute: { _ in throw FixtureDefect() }
            ),
            OperationDefinition(
                name: FixtureOperation.spin,
                summary: "Loops until cancelled, checking cooperatively.",
                parameters: [],
                result: .number,
                compute: { _ in
                    var iteration = 0
                    while true {
                        try Cooperation.checkpoint(iteration: iteration)
                        iteration += 1
                    }
                }
            ),
        ]
    }
}
