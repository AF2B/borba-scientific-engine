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
    case hold
}

/// A counting gate that suspends callers until it is opened.
public actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a closed gate.
    public init() {}

    /// Suspends until the gate is opened; returns immediately when it already is.
    public func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Opens the gate for everyone, now and in the future.
    public func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

/// Counts how many operations run at the same time, and the most that ever did.
public actor ConcurrencyProbe {
    /// How many operations are running right now.
    public private(set) var current = 0

    /// The most operations that ever ran at the same time.
    public private(set) var maximum = 0

    /// Creates a probe with nothing running.
    public init() {}

    /// Records that an operation started.
    public func enter() {
        current += 1
        maximum = Swift.max(maximum, current)
    }

    /// Records that an operation finished.
    public func leave() {
        current -= 1
    }

    /// Suspends until at least the given number of operations are running.
    ///
    /// - Parameter count: How many operations to wait for.
    public func waitUntilRunning(atLeast count: Int) async {
        while current < count {
            await Task.yield()
        }
    }
}

/// What the ``FixtureOperation/hold`` operation reports to and waits on.
public struct FixtureControls: Sendable {
    /// Counts concurrent runs of the `hold` operation.
    public let probe: ConcurrencyProbe

    /// The `hold` operation suspends here until the gate is opened.
    public let gate: Gate

    /// Creates fresh controls.
    public init() {
        probe = ConcurrencyProbe()
        gate = Gate()
    }
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
    /// - Parameters:
    ///   - clock: The clock the sleeping operation waits on.
    ///   - controls: What the `hold` operation reports to and waits on.
    public init(
        clock: any EngineClock,
        controls: FixtureControls = FixtureControls()
    ) {
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
                name: FixtureOperation.hold,
                summary: "Counts itself and waits for a gate to open.",
                parameters: [],
                result: .number,
                compute: { _ in
                    await controls.probe.enter()
                    await controls.gate.wait()
                    await controls.probe.leave()
                    return 1
                }
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
