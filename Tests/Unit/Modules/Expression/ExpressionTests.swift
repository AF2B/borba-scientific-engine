import Foundation
import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("Expression")
struct ExpressionTests {
    private typealias P = ExpressionParameters

    private func evaluate(
        _ source: String,
        variables: [String: Double] = [:],
        unit: AngleUnit = .radians
    ) throws -> Double {
        let root = try ExpressionParser.parse(source)
        return try root.evaluate(in: EvaluationContext(variables: variables, angleUnit: unit))
    }

    private func isClose(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double = 1e-12
    ) -> Bool {
        abs(lhs - rhs) <= tolerance * max(1, abs(rhs))
    }

    private func failure(of source: String) -> InvalidExpressionError? {
        do {
            _ = try ExpressionParser.parse(source)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Evaluation

    @Test(
        "respects operator precedence and associativity",
        arguments: [
            ("1 + 2 * 3", 7.0),
            ("(1 + 2) * 3", 9.0),
            ("10 - 4 - 3", 3.0),
            ("100 / 10 / 5", 2.0),
            ("2 ^ 3 ^ 2", 512.0),
            ("-2 ^ 2", -4.0),
            ("(-2) ^ 2", 4.0),
            ("2 ^ -1", 0.5),
            ("--3", 3.0),
            ("+-+3", -3.0),
            ("7 % 4 * 2", 6.0),
            ("2 * 3 % 4", 2.0),
            ("1e3 + .5", 1_000.5),
            ("1.5E-1 * 2", 0.3),
        ]
    )
    func precedence(
        source: String,
        expected: Double
    ) throws {
        #expect(isClose(try evaluate(source), expected))
    }

    @Test("reads variables and the constants pi, e and tau")
    func variablesAndConstants() throws {
        #expect(isClose(try evaluate("x * y + z", variables: ["x": 2, "y": 3, "z": 4]), 10))
        #expect(isClose(try evaluate("pi"), .pi))
        #expect(isClose(try evaluate("e"), M_E))
        #expect(isClose(try evaluate("tau / pi"), 2))
        #expect(isClose(try evaluate("_under_score1 + 1", variables: ["_under_score1": 4]), 5))
    }

    @Test(
        "evaluates the function library",
        arguments: [
            ("sin(0)", 0.0), ("cos(0)", 1.0), ("tan(0)", 0.0), ("atan(1) * 4", Double.pi),
            ("atan2(1, 1) * 4", Double.pi),
            ("asin(1) * 2", Double.pi), ("acos(-1)", Double.pi), ("sinh(0)", 0.0), ("cosh(0)", 1.0), ("tanh(0)", 0.0),
            ("sqrt(16)", 4.0), ("cbrt(-8)", -2.0), ("exp(0)", 1.0), ("ln(e)", 1.0), ("log(1000)", 3.0),
            ("log2(8)", 3.0),
            ("abs(-3.5)", 3.5), ("floor(-1.5)", -2.0), ("ceil(1.2)", 2.0), ("round(2.5)", 3.0), ("round(-2.5)", -3.0),
            ("trunc(-1.9)", -1.0), ("sign(-7)", -1.0), ("sign(0)", 0.0), ("sign(3)", 1.0), ("min(3, 1, 2)", 1.0),
            ("max(3, 1, 2)", 3.0), ("max(5)", 5.0), ("pow(2, 10)", 1_024.0), ("hypot(3, 4)", 5.0),
        ]
    )
    func functions(
        source: String,
        expected: Double
    ) throws {
        #expect(isClose(try evaluate(source), expected))
    }

    @Test("trigonometry follows the angle unit", arguments: [AngleUnit.radians, AngleUnit.degrees])
    func angleUnits(unit: AngleUnit) throws {
        let quarterTurn = unit == .radians ? Double.pi / 2 : 90

        #expect(isClose(try evaluate("sin(\(quarterTurn))", unit: unit), 1))
        #expect(isClose(try evaluate("cos(\(quarterTurn))", unit: unit), 0, tolerance: 1e-9))
        #expect(isClose(try evaluate("asin(1)", unit: unit), quarterTurn))
    }

    @Test("reports a division by zero")
    func divisionByZero() {
        for source in ["1 / 0", "1 / (2 - 2)", "5 % 0"] {
            #expect(throws: CalculationError.divisionByZero(DivisionByZeroError(operand: "divisor"))) {
                try evaluate(source)
            }
        }
    }

    @Test(
        "reports arguments outside a function's domain as undefined",
        arguments: [
            "sqrt(-1)", "ln(0)", "ln(-2)", "log(0)", "log2(-1)", "asin(2)", "acos(-2)", "tan(pi / 2)", "(-8) ^ 0.5",
        ]
    )
    func domains(source: String) {
        let error = #expect(throws: CalculationError.self) {
            try evaluate(source)
        }

        #expect(error?.code == .undefinedResult)
    }

    @Test("reports an undefined variable")
    func undefinedVariable() {
        let error = #expect(throws: CalculationError.self) {
            try evaluate("x + 1")
        }

        #expect(error?.details == [ErrorDetail(field: "expression", reason: "uses the undefined variable 'x'")])
    }

    // MARK: - Parsing errors

    @Test(
        "locates syntax errors",
        arguments: [
            ("", InvalidExpressionError(reason: .empty, position: nil)),
            ("   ", InvalidExpressionError(reason: .empty, position: nil)),
            ("2 +", InvalidExpressionError(reason: .unexpectedEnd, position: 3)),
            ("2 + * 3", InvalidExpressionError(reason: .unexpectedToken("*"), position: 4)),
            ("(1 + 2", InvalidExpressionError(reason: .unbalancedParenthesis, position: 0)),
            ("1 + 2)", InvalidExpressionError(reason: .unexpectedToken(")"), position: 5)),
            ("()", InvalidExpressionError(reason: .unexpectedToken(")"), position: 1)),
            ("2 $ 3", InvalidExpressionError(reason: .unexpectedCharacter("$"), position: 2)),
            ("2x", InvalidExpressionError(reason: .unexpectedToken("x"), position: 1)),
            ("1 2", InvalidExpressionError(reason: .unexpectedToken("2"), position: 2)),
            ("1.2.3", InvalidExpressionError(reason: .unexpectedToken(".3"), position: 3)),
            ("2e", InvalidExpressionError(reason: .malformedNumber("2e"), position: 0)),
            ("1e+", InvalidExpressionError(reason: .malformedNumber("1e+"), position: 0)),
            (".", InvalidExpressionError(reason: .malformedNumber("."), position: 0)),
            ("1e999", InvalidExpressionError(reason: .malformedNumber("1e999"), position: 0)),
            ("foo(1)", InvalidExpressionError(reason: .unknownFunction("foo"), position: 0)),
            (
                "sin(1, 2)",
                InvalidExpressionError(
                    reason: .wrongArgumentCount(function: "sin", expected: "1 argument", actual: 2),
                    position: 0
                )
            ),
            (
                "max()",
                InvalidExpressionError(
                    reason: .wrongArgumentCount(function: "max", expected: "at least 1 argument", actual: 0),
                    position: 0
                )
            ),
            ("sin(1", InvalidExpressionError(reason: .unbalancedParenthesis, position: 3)),
            ("é + 1", InvalidExpressionError(reason: .unexpectedCharacter("é"), position: 0)),
        ]
    )
    func syntaxErrors(
        source: String,
        expected: InvalidExpressionError
    ) {
        #expect(failure(of: source) == expected)
    }

    @Test("explains errors with their position")
    func explanations() {
        #expect(
            InvalidExpressionError(reason: .unexpectedToken(")"), position: 5).explanation
                == "unexpected ')' at position 5"
        )
        #expect(InvalidExpressionError(reason: .empty, position: nil).explanation == "the expression is empty")
        #expect(
            InvalidExpressionError(reason: .unknownFunction("foo"), position: 0).explanation
                == "unknown function 'foo' at position 0"
        )
    }

    @Test("maps expression errors to the stable INVALID_EXPRESSION code")
    func mapsToStableCode() {
        let error = InvalidExpressionError(reason: .unexpectedEnd, position: 3).calculationError

        #expect(error.code == ErrorCode("INVALID_EXPRESSION"))
        #expect(error.message == "The provided expression is invalid.")
        #expect(
            error.details == [
                ErrorDetail(field: "expression", reason: "the expression ends unexpectedly at position 3")
            ]
        )
        #expect(error.classification == .expectedDomain)
    }

    // MARK: - Limits

    @Test("rejects expressions that are too long")
    func tooLong() {
        let source = String(repeating: "1+", count: Tokenizer.maximumLength) + "1"

        #expect(failure(of: source)?.reason == .tooLong(maximum: Tokenizer.maximumLength))
    }

    @Test("accepts the longest permitted flat expression and evaluates it")
    func longestFlatExpression() throws {
        let terms = (Tokenizer.maximumLength + 1) / 2
        let source = Array(repeating: "1", count: terms).joined(separator: "+")

        #expect(source.count <= Tokenizer.maximumLength)
        #expect(try evaluate(source) == Double(terms))
    }

    @Test("rejects pathological nesting instead of exhausting the stack")
    func nestingLimit() {
        let depth = ExpressionParser.maximumNesting + 1

        let parentheses = String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth)
        let negations = String(repeating: "-", count: depth * 2) + "1"
        let powers = Array(repeating: "2", count: depth * 2).joined(separator: "^")

        #expect(failure(of: parentheses)?.reason == .tooDeeplyNested(maximum: ExpressionParser.maximumNesting))
        #expect(failure(of: negations)?.reason == .tooDeeplyNested(maximum: ExpressionParser.maximumNesting))
        #expect(failure(of: powers)?.reason == .tooDeeplyNested(maximum: ExpressionParser.maximumNesting))
    }

    @Test("accepts nesting up to the limit")
    func nestingAtTheLimit() throws {
        let depth = ExpressionParser.maximumNesting - 1
        let source = String(repeating: "(", count: depth) + "7" + String(repeating: ")", count: depth)

        #expect(try evaluate(source) == 7)
    }

    // MARK: - Variables

    @Test("collects the variables an expression reads, excluding constants")
    func variableNames() throws {
        let root = try ExpressionParser.parse("a * sin(b + pi) + max(c, a, e)")

        #expect(root.variableNames == ["a", "b", "c"])
    }

    @Test("rejects variable names that cannot be written or are reserved")
    func variableNameValidation() async throws {
        let engine = CalculationEngine.standard()

        for (name, expectedReason) in [
            ("pi", "entry 'pi' is a built-in constant or function and cannot be redefined"),
            ("sin", "entry 'sin' is a built-in constant or function and cannot be redefined"),
            ("2x", "entry '2x' is not a valid variable name"),
            ("a-b", "entry 'a-b' is not a valid variable name"),
        ] {
            let result = try await engine.calculate(
                .expression,
                ExpressionOperation.evaluate,
                [P.expression.name: "1", P.variables.name: [name: 1]]
            )
            #expect(result.failure?.details == [ErrorDetail(field: "variables", reason: expectedReason)])
        }
    }

    @Test("lists every undefined variable at once")
    func undefinedVariablesThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let result = try await engine.calculate(
            .expression,
            ExpressionOperation.evaluate,
            [P.expression.name: "a + b + c", P.variables.name: ["b": 1]]
        )

        #expect(result.failure?.details == [ErrorDetail(field: "variables", reason: "must define: a, c")])
    }

    @Test("reports syntax errors through the engine with the failing expression field")
    func syntaxErrorThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let result = try await engine.calculate(
            .expression,
            ExpressionOperation.evaluate,
            [P.expression.name: "2 + * 3"]
        )

        #expect(result.failure?.code == ErrorCode("INVALID_EXPRESSION"))
        #expect(result.failure?.details == [ErrorDetail(field: "expression", reason: "unexpected '*' at position 4")])
    }

    // MARK: - Cache

    @Test("caches compiled expressions and counts hits and misses")
    func cacheHits() async throws {
        let cache = CachingExpressionCompiler(capacity: 4)

        _ = try await cache.compile("1 + 2")
        _ = try await cache.compile("1 + 2")
        _ = try await cache.compile("3 * 4")
        _ = try await cache.compile("1 + 2")

        #expect(await cache.hitCount == 2)
        #expect(await cache.missCount == 2)
        #expect(await cache.entryCount == 2)
    }

    @Test("evicts the least recently used expression when full")
    func cacheEviction() async throws {
        let cache = CachingExpressionCompiler(capacity: 2)

        _ = try await cache.compile("1")
        _ = try await cache.compile("2")
        _ = try await cache.compile("1")  // refreshes "1", so "2" is now the oldest
        _ = try await cache.compile("3")  // evicts "2"
        let missesBefore = await cache.missCount
        _ = try await cache.compile("1")  // still cached
        _ = try await cache.compile("2")  // was evicted, so it misses

        #expect(await cache.entryCount == 2)
        #expect(await cache.missCount == missesBefore + 1)
    }

    @Test("never caches failures and never lets the cache change an outcome")
    func cacheFailures() async throws {
        let cache = CachingExpressionCompiler(capacity: 4)

        for _ in 0..<2 {
            let error = await #expect(throws: InvalidExpressionError.self) {
                try await cache.compile("1 +")
            }
            #expect(error?.reason == .unexpectedEnd)
        }

        #expect(await cache.entryCount == 0)
        #expect(await cache.hitCount == 0)
        #expect(await cache.missCount == 2)
    }

    @Test("a cached expression evaluates exactly like a freshly parsed one")
    func cacheIsTransparent() async throws {
        let cache = CachingExpressionCompiler()
        let fresh = try await ParsingExpressionCompiler().compile("a * (b + 1) ^ 2")

        _ = try await cache.compile("a * (b + 1) ^ 2")
        let cached = try await cache.compile("a * (b + 1) ^ 2")

        #expect(cached == fresh)
    }

    @Test("serves many concurrent requests for the same formulas consistently")
    func cacheUnderConcurrency() async throws {
        let cache = CachingExpressionCompiler(capacity: 8)
        let sources = (0..<20).map { "x + \($0)" }

        let evaluations = await withTaskGroup(of: Double?.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let compiled = try? await cache.compile(sources[index % sources.count])
                    return try? compiled?.evaluate(in: EvaluationContext(variables: ["x": 1]))
                }
            }
            return await group.reduce(into: [Double?]()) { $0.append($1) }
        }

        #expect(evaluations.count == 200)
        #expect(evaluations.allSatisfy { $0 != nil })
        #expect(await cache.entryCount <= 8)
        #expect(await cache.hitCount + cache.missCount >= 200)
    }
}
