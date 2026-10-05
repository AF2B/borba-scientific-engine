import BorbaScientificCore
import Foundation
import Testing

/// Parameters are input, and input is hostile. Every operation is run with each of its example's parameters replaced, one
/// at a time, by values chosen to break arithmetic and parsing: the extremes of floating point, the edges of integer
/// ranges, empty and oversized collections, ragged matrices, deeply nested or malicious text, and values of the wrong
/// type. Whatever the value, the operation must come back, in bounded time, with a value or a typed failure.
///
/// A trap is a crash of the whole service, and an operation that ignores its time budget is a way to stop the service
/// from answering anyone, so both are failures here and neither is a corner case.
@Suite("Hostile input", .timeLimit(.minutes(3)))
struct HostileInputTests {
    private static let timeBudget = Duration.seconds(2)

    /// Far longer than the budget: an operation this slow did not honour it.
    private static let slowLimit = Duration.seconds(5)

    /// A sweep that runs fewer cases than this stopped covering the operations it is meant to.
    private static let minimumCases = 2_000

    @Test("every operation survives every hostile parameter, in bounded time")
    func everyOperationSurvives() async throws {
        let registry = ModuleRegistry.standard()
        let engine = CalculationEngine(registry: registry, clock: SystemClock(), timeout: Self.timeBudget)
        var executed = 0
        var slow: [String] = []

        for module in registry.modules {
            for operation in module.operations {
                guard let example = operation.examples.first else {
                    continue
                }

                for (name, original) in example.parameters.sorted(by: { $0.key < $1.key }) {
                    for hostile in HostileValues.replacements(for: original) {
                        var parameters = example.parameters
                        parameters[name] = hostile.value

                        let started = ContinuousClock.now
                        _ = try? await engine.execute(CalculationRequest(type: operation.type, parameters: parameters))
                        let elapsed = ContinuousClock.now - started

                        executed += 1
                        if elapsed > Self.slowLimit {
                            slow.append("\(operation.type) with \(name) = \(hostile.label) took \(elapsed)")
                        }
                    }
                }
            }
        }

        #expect(slow.isEmpty, "operations that outlasted their time budget: \(slow)")
        #expect(executed >= Self.minimumCases, "only \(executed) cases ran")
    }
}

/// What a parameter can be replaced with to break the code that reads it.
enum HostileValues {
    struct Replacement {
        let label: String
        let value: CalculationValue
    }

    private static let matrixDimensionLimit = 100
    private static let nestingDepth = 70

    /// The extremes of floating point, the edges of what an integer holds, and the values arithmetic dislikes. JSON cannot
    /// carry the last three, but a module must not depend on that.
    private static let numbers: [Double] = [
        0, -0.0, 1, -1, 0.5, -0.5, 2, 10, 100, 1_000, 1_000_000,
        1e-300, .leastNonzeroMagnitude, 1e15, 1e16, 9_007_199_254_740_994, 4_294_967_296, 2_147_483_648,
        9.223372036854776e18, -9.223372036854776e18, 1.8446744073709552e19,
        1e300, -1e300, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        .infinity, -.infinity, .nan,
    ]

    private static let texts: [String] = [
        "",
        " ",
        "x",
        "1/0",
        "0/0",
        "9^9^9^9^9",
        "sqrt(-1)",
        "ln(0)",
        "tan(pi/2)",
        "sin(",
        ")",
        "1e999",
        "1..2",
        "((((",
        "\u{0}",
        "line\nbreak",
        "tab\tseparated",
        "quote\"and'apostrophe\\",
        "'; DROP TABLE calculations; --",
        "{{7*7}} ${7*7} <script>alert(1)</script>",
        "𝔘𝔫𝔦𝔠𝔬𝔡𝔢 ✓ 日本語 مرحبا",
        "\u{202E}reversed",
    ]

    /// Values that are not what the parameter is declared to be, whatever it is declared to be.
    private static let typeConfusions: [Replacement] = [
        Replacement(label: "null", value: .null),
        Replacement(label: "true", value: .boolean(true)),
        Replacement(label: "a number", value: .number(1)),
        Replacement(label: "numeric text", value: .text("1")),
        Replacement(label: "empty list", value: .list([])),
        Replacement(label: "empty object", value: .object([:])),
        Replacement(label: "a list of lists of lists", value: .list([.matrix([[1]])])),
        Replacement(label: "an object", value: .fields(["a": 1, "b": .text("x")])),
    ]

    /// Every replacement to try for a parameter whose example value is `original`.
    ///
    /// - Parameter original: The value the operation's example gives the parameter, whose shape decides what is tried.
    /// - Returns: The replacements, each labelled for the report.
    static func replacements(for original: CalculationValue) -> [Replacement] {
        var all = typeConfusions

        switch original {
        case .number:
            all += numbers.map { Replacement(label: "\($0)", value: .number($0)) }
        case .text:
            all += texts.map { Replacement(label: "text \($0.debugDescription)", value: .text($0)) }
            all += expressions
        case .list:
            all += vectors + matrices
        case .boolean:
            all += [Replacement(label: "false", value: .boolean(false))]
        case .object, .null:
            break
        }

        return all
    }

    private static var expressions: [Replacement] {
        [
            Replacement(label: "an expression nested \(nestingDepth) deep", value: .text(nested("(", ")", "1"))),
            Replacement(label: "a chain of negations", value: .text(String(repeating: "-", count: nestingDepth) + "1")),
            Replacement(
                label: "a text as long as the limit allows",
                value: .text(String(repeating: "1+", count: ParameterLimits.maximumTextLength / 2) + "1")
            ),
            Replacement(
                label: "a text one longer than the limit",
                value: .text(String(repeating: "x", count: ParameterLimits.maximumTextLength + 1))
            ),
        ]
    }

    private static var vectors: [Replacement] {
        let atTheLimit = [Double](repeating: 1, count: ParameterLimits.maximumCollectionSize)
        let overTheLimit = [Double](repeating: 1, count: ParameterLimits.maximumCollectionSize + 1)

        var vectors = [
            Replacement(label: "a list of one", value: .numbers([1])),
            Replacement(label: "a list of two equal numbers", value: .numbers([7, 7])),
            Replacement(label: "two numbers that overflow a sum", value: .numbers([1e308, 1e308])),
            Replacement(label: "numbers that cancel exactly", value: .numbers([1e308, -1e308])),
            Replacement(
                label: "a list with the extremes",
                value: .numbers([.greatestFiniteMagnitude, .leastNonzeroMagnitude, 0, -0.0])
            ),
            Replacement(label: "a list with a NaN", value: .numbers([1, .nan, 3])),
            Replacement(label: "a list with an infinity", value: .numbers([1, .infinity, 3])),
            Replacement(label: "a list at the size limit", value: .numbers(atTheLimit)),
            Replacement(label: "a list one over the size limit", value: .numbers(overTheLimit)),
            Replacement(label: "a list of text", value: .list([.text("a"), .text("b")])),
            Replacement(label: "a list with a hole", value: .list([.number(1), .null, .number(3)])),
        ]
        vectors += numbers.map { Replacement(label: "a list holding \($0)", value: .numbers([$0, $0, $0])) }
        return vectors
    }

    private static var matrices: [Replacement] {
        let square = { (size: Int, value: Double) in
            CalculationValue.matrix([[Double]](repeating: [Double](repeating: value, count: size), count: size))
        }

        return [
            Replacement(label: "a matrix with no rows", value: .matrix([])),
            Replacement(label: "a matrix with an empty row", value: .matrix([[]])),
            Replacement(label: "a ragged matrix", value: .matrix([[1, 2], [3]])),
            Replacement(label: "a matrix of one", value: .matrix([[1]])),
            Replacement(label: "a singular matrix", value: .matrix([[1, 2], [2, 4]])),
            Replacement(label: "a matrix of zeros", value: square(3, 0)),
            Replacement(label: "a matrix of the largest numbers", value: square(3, .greatestFiniteMagnitude)),
            Replacement(label: "a matrix of the smallest numbers", value: square(3, .leastNonzeroMagnitude)),
            Replacement(label: "a matrix of NaN", value: square(2, .nan)),
            Replacement(label: "a matrix at the dimension limit", value: square(matrixDimensionLimit, 1)),
            Replacement(label: "a matrix one over the dimension limit", value: square(matrixDimensionLimit + 1, 1)),
            Replacement(
                label: "a column of one hundred thousand",
                value: .matrix([[Double]](repeating: [1], count: 100_000))
            ),
        ]
    }

    private static func nested(_ open: String, _ close: String, _ innermost: String) -> String {
        String(repeating: open, count: nestingDepth) + innermost + String(repeating: close, count: nestingDepth)
    }
}
