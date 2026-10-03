import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("Arithmetic")
struct ArithmeticTests {
    private typealias P = ArithmeticParameters

    @Test(
        "divides and reports a zero divisor",
        arguments: [(7.0, 2.0, 3.5), (-9.0, 3.0, -3.0), (0.0, 5.0, 0.0)]
    )
    func divides(dividend: Double, divisor: Double, expected: Double) throws {
        #expect(try Arithmetic.divide(dividend, by: divisor) == expected)
    }

    @Test("rejects a zero divisor, including negative zero", arguments: [0.0, -0.0])
    func rejectsZeroDivisor(divisor: Double) {
        #expect(throws: ArithmeticError.divisionByZero(operand: .divisor)) {
            try Arithmetic.divide(1, by: divisor)
        }
        #expect(throws: ArithmeticError.divisionByZero(operand: .divisor)) {
            try Arithmetic.remainder(of: 1, dividedBy: divisor)
        }
    }

    @Test(
        "the remainder takes the sign of the dividend",
        arguments: [(7.0, 3.0, 1.0), (-7.0, 3.0, -1.0), (7.0, -3.0, 1.0), (-7.0, -3.0, -1.0), (5.5, 2.0, 1.5)]
    )
    func remainder(dividend: Double, divisor: Double, expected: Double) throws {
        #expect(try Arithmetic.remainder(of: dividend, dividedBy: divisor) == expected)
    }

    @Test(
        "raises numbers to powers",
        arguments: [(2.0, 10.0, 1_024.0), (2.0, -2.0, 0.25), (-2.0, 3.0, -8.0), (9.0, 0.5, 3.0), (0.0, 0.0, 1.0)]
    )
    func power(base: Double, exponent: Double, expected: Double) throws {
        #expect(try Arithmetic.power(of: base, raisedTo: exponent) == expected)
    }

    @Test("has no real result for a negative base with a fractional exponent")
    func negativeBaseWithFractionalExponent() {
        #expect(throws: ArithmeticError.negativeBaseWithFractionalExponent) {
            try Arithmetic.power(of: -8, raisedTo: 1.0 / 3.0)
        }
    }

    @Test("refuses to raise zero to a negative power")
    func zeroToNegativePower() {
        #expect(throws: ArithmeticError.divisionByZero(operand: .base)) {
            try Arithmetic.power(of: 0, raisedTo: -1)
        }
    }

    @Test("sums long and badly scaled lists accurately")
    func compensatedSum() {
        let tenths = Array(repeating: 0.1, count: 10)

        #expect(tenths.reduce(0, +) != 1.0, "the naive sum accumulates error, which is what compensation fixes")
        #expect(Arithmetic.sum(of: tenths) == 1.0)
        #expect(Arithmetic.sum(of: [1e100, 1.0, -1e100]) == 1.0)
    }

    @Test("multiplies lists, treating the empty product as one")
    func product() {
        #expect(Arithmetic.product(of: [2, 3, 4]) == 24)
        #expect(Arithmetic.product(of: []) == 1)
    }

    @Test(
        "finds greatest common divisors",
        arguments: [(48, 18, 6), (-48, 18, 6), (17, 5, 1), (0, 9, 9), (0, 0, 0), (7, 0, 7)]
    )
    func greatestCommonDivisor(first: Int, second: Int, expected: Int) {
        #expect(Arithmetic.greatestCommonDivisor(first, second) == expected)
    }

    @Test(
        "finds least common multiples",
        arguments: [(4, 6, 12), (-4, 6, 12), (21, 6, 42), (0, 5, 0), (7, 1, 7)]
    )
    func leastCommonMultiple(first: Int, second: Int, expected: Int) throws {
        #expect(try Arithmetic.leastCommonMultiple(first, second) == expected)
    }

    @Test("reports a least common multiple too large to be exact")
    func leastCommonMultipleOverflow() {
        let nearLimit = Arithmetic.largestExactInteger - 1

        #expect(throws: ArithmeticError.integerOverflow) {
            try Arithmetic.leastCommonMultiple(nearLimit, nearLimit - 1)
        }
    }

    @Test(
        "computes factorials",
        arguments: [(0, 1.0), (1, 1.0), (5, 120.0), (10, 3_628_800.0), (20, 2_432_902_008_176_640_000.0)]
    )
    func factorial(number: Int, expected: Double) {
        #expect(Arithmetic.factorial(of: number) == expected)
    }

    @Test("the largest supported factorial is finite and the next one would overflow")
    func factorialLimit() {
        #expect(Arithmetic.factorial(of: Arithmetic.largestFactorialArgument).isFinite)
        #expect(Arithmetic.factorial(of: Arithmetic.largestFactorialArgument + 1).isInfinite)
    }

    @Test(
        "rounds with the requested strategy",
        arguments: [
            (2.675, 2, RoundingStrategy.nearestAway, 2.68),
            (2.675, 2, .nearestEven, 2.68),
            (2.5, 0, .nearestAway, 3.0),
            (2.5, 0, .nearestEven, 2.0),
            (3.5, 0, .nearestEven, 4.0),
            (-2.5, 0, .nearestAway, -3.0),
            (-1.2, 0, .floor, -2.0),
            (1.2, 0, .ceiling, 2.0),
            (-1.9, 0, .towardZero, -1.0),
            (1.9, 0, .towardZero, 1.0),
            (1_234.0, -2, .nearestAway, 1_200.0),
        ]
    )
    func rounds(
        value: Double,
        decimals: Int,
        strategy: RoundingStrategy,
        expected: Double
    ) {
        #expect(Arithmetic.rounded(value, decimals: decimals, strategy: strategy) == expected)
    }

    @Test("maps arithmetic failures to stable error codes")
    func mapsFailures() {
        #expect(ArithmeticError.divisionByZero(operand: .divisor).calculationError.code == .divisionByZero)
        #expect(ArithmeticError.negativeBaseWithFractionalExponent.calculationError.code == .undefinedResult)
        #expect(ArithmeticError.integerOverflow.calculationError.code == .numericOverflow)
    }

    @Test("reports a zero divisor through the engine as an expected domain failure")
    func divisionByZeroThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let result = try await engine.calculate(
            .arithmetic,
            ArithmeticOperation.divide,
            [P.dividend.name: 1, P.divisor.name: 0]
        )

        #expect(result == .failure(.divisionByZero(DivisionByZeroError(operand: "divisor"))))
        #expect(result.failure?.classification == .expectedDomain)
    }

    @Test("reports a result that does not fit in a number as an overflow")
    func overflowThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let result = try await engine.calculate(
            .arithmetic,
            ArithmeticOperation.power,
            [P.base.name: 10, P.exponent.name: 400]
        )

        #expect(result == .failure(.numericOverflow))
    }

    @Test("rejects non-integer arguments for integer operations")
    func integerValidationThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let error = await #expect(throws: CalculationError.self) {
            try await engine.calculate(
                .arithmetic,
                ArithmeticOperation.greatestCommonDivisor,
                [P.firstInteger.name: 4.5, P.secondInteger.name: 6]
            )
        }

        #expect(error?.details == [ErrorDetail(field: "a", reason: "must be a whole number")])
    }
}

extension Result {
    /// The failure, when there is one, so tests can inspect it without a `switch`.
    var failure: Failure? {
        guard case .failure(let error) = self else {
            return nil
        }
        return error
    }
}
