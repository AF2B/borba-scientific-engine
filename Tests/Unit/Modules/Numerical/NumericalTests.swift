import Foundation
import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("Numerical")
struct NumericalTests {
    private typealias P = NumericalParameters

    private func function(
        _ source: String,
        variable: String = "x",
        variables: [String: Double] = [:],
        unit: AngleUnit = .radians
    ) async throws -> UnivariateFunction {
        let compiled = try await ParsingExpressionCompiler().compile(source)

        return UnivariateFunction(
            expression: compiled,
            context: try ExpressionVariables.context(from: variables, angleUnit: unit),
            variable: variable
        )
    }

    private func isClose(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double = 1e-9
    ) -> Bool {
        abs(lhs - rhs) <= tolerance * max(1, abs(rhs))
    }

    // MARK: - Integration

    @Test("integrates exactly what Simpson's rule integrates exactly")
    func simpsonIsExactForCubics() async throws {
        let cubic = try await function("x^3 - 2*x^2 + x")

        let value = try NumericalMethods.integrate(cubic, from: 0, to: 3, intervals: 2, method: .simpson)

        #expect(isClose(value, 81.0 / 4.0 - 18 + 4.5, tolerance: 1e-12))
    }

    @Test("approximates smooth integrals with both rules", arguments: IntegrationMethod.allCases)
    func smoothIntegrals(method: IntegrationMethod) async throws {
        let sine = try await function("sin(x)")

        let value = try NumericalMethods.integrate(sine, from: 0, to: .pi, intervals: 10_000, method: method)

        #expect(isClose(value, 2, tolerance: 1e-7))
    }

    @Test("halving the step quarters the trapezoid error and sixteenths the Simpson error")
    func convergenceOrder() async throws {
        let exponential = try await function("exp(x)")
        let exact = M_E - 1

        func error(
            _ method: IntegrationMethod,
            _ intervals: Int
        ) throws -> Double {
            abs(
                try NumericalMethods.integrate(exponential, from: 0, to: 1, intervals: intervals, method: method)
                    - exact
            )
        }

        let trapezoidRatio = try error(.trapezoid, 20) / error(.trapezoid, 40)
        let simpsonRatio = try error(.simpson, 20) / error(.simpson, 40)

        #expect(abs(trapezoidRatio - 4) < 0.1)
        #expect(abs(simpsonRatio - 16) < 0.5)
    }

    @Test("negates the integral when the bounds are reversed and vanishes on an empty interval")
    func orientation() async throws {
        let square = try await function("x^2")

        let forward = try NumericalMethods.integrate(square, from: 0, to: 3, intervals: 100, method: .simpson)
        let backward = try NumericalMethods.integrate(square, from: 3, to: 0, intervals: 100, method: .simpson)
        let empty = try NumericalMethods.integrate(square, from: 2, to: 2, intervals: 100, method: .simpson)

        #expect(isClose(forward, 9))
        #expect(isClose(backward, -9))
        #expect(empty == 0)
    }

    @Test("reports a singularity inside the interval")
    func singularity() async throws {
        let reciprocal = try await function("1 / x")

        #expect(throws: CalculationError.divisionByZero(DivisionByZeroError(operand: "divisor"))) {
            try NumericalMethods.integrate(reciprocal, from: -1, to: 1, intervals: 2, method: .simpson)
        }
    }

    @Test("reports a function that is not finite where it is sampled")
    func nonFiniteIntegrand() async throws {
        let logarithm = try await function("ln(x)")

        #expect(throws: CalculationError.self) {
            try NumericalMethods.integrate(logarithm, from: 0, to: 1, intervals: 10, method: .trapezoid)
        }
    }

    @Test("integrates with variables, constants and a custom variable name")
    func variablesAndNames() async throws {
        let scaled = try await function("a * sin(t) + pi - pi", variable: "t", variables: ["a": 3])

        let value = try NumericalMethods.integrate(scaled, from: 0, to: .pi, intervals: 1_000, method: .simpson)

        #expect(isClose(value, 6, tolerance: 1e-9))
    }

    @Test("rejects an odd number of intervals for Simpson's rule through the engine")
    func oddIntervals() async throws {
        let engine = CalculationEngine.standard()

        let result = try await engine.calculate(
            .numerical,
            NumericalOperation.integrate,
            [P.expression.name: "x", P.lower.name: 0, P.upper.name: 1, P.intervals.name: 5]
        )
        #expect(
            result.failure?.details == [ErrorDetail(field: "intervals", reason: "must be even for the simpson method")]
        )
    }

    // MARK: - Differentiation

    @Test(
        "differentiates with a central difference",
        arguments: [
            ("x^3", 2.0, 12.0), ("sin(x)", 0.0, 1.0), ("exp(x)", 1.0, M_E), ("1 / x", 2.0, -0.25), ("x^2", -3.0, -6.0),
        ]
    )
    func derivatives(
        source: String,
        point: Double,
        expected: Double
    ) async throws {
        let function = try await function(source)

        let slope = try NumericalMethods.differentiate(function, at: point, step: NumericalMethods.defaultStep)

        #expect(isClose(slope, expected, tolerance: 1e-6))
    }

    // MARK: - Root finding

    @Test("bisection finds the root of a function that changes sign")
    func bisection() async throws {
        let function = try await function("x^2 - 2")

        let result = try NumericalMethods.findRoot(
            of: function,
            over: 0...2,
            method: .bisection,
            tolerance: 1e-12,
            maximumIterations: 100
        )

        #expect(isClose(result.root, 2.0.squareRoot(), tolerance: 1e-11))
        #expect(abs(result.residual) < 1e-10)
    }

    @Test("Newton's method converges in a few steps near a simple root")
    func newton() async throws {
        let function = try await function("cos(x) - x")

        let result = try NumericalMethods.findRoot(
            of: function,
            over: 0...1,
            method: .newton,
            tolerance: 1e-12,
            maximumIterations: 100
        )

        #expect(isClose(result.root, 0.739_085_133_215_160_6, tolerance: 1e-11))
        #expect(result.iterations < 10)
    }

    @Test("returns an endpoint that is already a root without iterating")
    func endpointRoots() async throws {
        let function = try await function("x - 1")

        let lowerRoot = try NumericalMethods.findRoot(
            of: function,
            over: 1...5,
            method: .bisection,
            tolerance: 1e-9,
            maximumIterations: 50
        )
        let upperRoot = try NumericalMethods.findRoot(
            of: function,
            over: -3...1,
            method: .bisection,
            tolerance: 1e-9,
            maximumIterations: 50
        )

        #expect(lowerRoot == RootSearchResult(root: 1, iterations: 0, residual: 0))
        #expect(upperRoot == RootSearchResult(root: 1, iterations: 0, residual: 0))
    }

    @Test("refuses an interval that does not bracket a root")
    func noBracket() async throws {
        let function = try await function("x^2 + 1")

        let error = #expect(throws: CalculationError.self) {
            try NumericalMethods.findRoot(
                of: function,
                over: -1...1,
                method: .bisection,
                tolerance: 1e-9,
                maximumIterations: 50
            )
        }

        #expect(error?.code == .undefinedResult)
        #expect(error?.message.contains("bracket") == true)
    }

    @Test("reports non-convergence when the iteration budget is too small")
    func noConvergence() async throws {
        let function = try await function("x^2 - 2")

        let error = #expect(throws: CalculationError.self) {
            try NumericalMethods.findRoot(
                of: function,
                over: 0...2,
                method: .bisection,
                tolerance: 1e-15,
                maximumIterations: 5
            )
        }

        #expect(error == .didNotConverge(iterations: 5))
        #expect(error?.code == .noConvergence)
    }

    @Test("Newton's method reports leaving the interval instead of returning a wrong root")
    func newtonLeavesTheInterval() async throws {
        let function = try await function("cbrt(x)")

        #expect(throws: CalculationError.self) {
            try NumericalMethods.findRoot(
                of: function,
                over: -1...3,
                method: .newton,
                tolerance: 1e-9,
                maximumIterations: 50
            )
        }
    }

    @Test("validates the interval and the variables through the engine")
    func validationThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let reversed = try await engine.calculate(
            .numerical,
            NumericalOperation.findRoot,
            [P.expression.name: "x", P.lower.name: 2, P.upper.name: 1]
        )
        let undefined = try await engine.calculate(
            .numerical,
            NumericalOperation.derivative,
            [P.expression.name: "x + y", P.point.name: 0]
        )
        let clash = try await engine.calculate(
            .numerical,
            NumericalOperation.derivative,
            [P.expression.name: "x", P.point.name: 0, P.variables.name: ["x": 1]]
        )
        let reserved = try await engine.calculate(
            .numerical,
            NumericalOperation.derivative,
            [P.expression.name: "pi", P.point.name: 0, P.variable.name: "pi"]
        )

        #expect(reversed.failure?.details == [ErrorDetail(field: "upper", reason: "must be greater than 'lower'")])
        #expect(undefined.failure?.details == [ErrorDetail(field: "variables", reason: "must define: y")])
        #expect(clash.failure?.details.first?.field == "variables")
        #expect(reserved.failure?.details.first?.field == "variable")
    }

    // MARK: - Cancellation

    @Test("stops a huge integration promptly when the task is cancelled")
    func cancellation() async throws {
        let engine = CalculationEngine.standard()
        let request = CalculationRequest(
            type: CalculationType(module: .numerical, operation: OperationName(NumericalOperation.integrate.rawValue)),
            parameters: [
                P.expression.name: "sin(x) * cos(x) + sqrt(x)",
                P.lower.name: 0,
                P.upper.name: 10,
                P.intervals.name: .number(Double(NumericalMethods.maximumIntervals)),
            ]
        )
        let prepared = try engine.prepare(request)

        let run = Task { await engine.run(prepared) }
        run.cancel()
        let outcome = await run.value

        #expect(outcome.result == .failure(.cancelled))
    }
}
