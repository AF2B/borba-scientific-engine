import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("Percentage")
struct PercentageTests {
    private typealias P = PercentageParameters

    @Test("takes a percentage of a base", arguments: [(15.0, 200.0, 30.0), (0.0, 50.0, 0.0), (150.0, 10.0, 15.0)])
    func takesPercentage(percentage: Double, base: Double, expected: Double) {
        #expect(Percentage.of(percentage, base: base) == expected)
    }

    @Test(
        "measures relative change against the magnitude of the original",
        arguments: [(80.0, 100.0, 25.0), (100.0, 75.0, -25.0), (-50.0, -25.0, 50.0), (10.0, 10.0, 0.0)]
    )
    func change(original: Double, updated: Double, expected: Double) throws {
        #expect(try Percentage.change(from: original, to: updated) == expected)
    }

    @Test("has no relative change from zero")
    func changeFromZero() {
        #expect(throws: DivisionByZeroError(operand: "original value")) {
            try Percentage.change(from: 0, to: 5)
        }
    }

    @Test("computes a symmetric difference that does not depend on argument order")
    func difference() {
        #expect(Percentage.difference(between: 90, and: 110) == 20)
        #expect(Percentage.difference(between: 110, and: 90) == 20)
        #expect(Percentage.difference(between: 0, and: 0) == 0)
    }

    @Test("applies markups and discounts")
    func markupsAndDiscounts() {
        #expect(Percentage.increase(50, byPercentage: 20) == 60)
        #expect(Percentage.decrease(80, byPercentage: 25) == 60)
    }

    @Test("recovers the original value, undoing increases and decreases")
    func original() throws {
        #expect(try Percentage.original(fromFinal: 120, afterChangeOf: 20) == 100)
        #expect(try Percentage.original(fromFinal: 60, afterChangeOf: -25) == 80)
    }

    @Test("cannot recover a value after a complete loss")
    func originalAfterTotalLoss() {
        #expect(throws: DivisionByZeroError(operand: "change factor")) {
            try Percentage.original(fromFinal: 0, afterChangeOf: -100)
        }
    }

    @Test("expresses a part as a share of a total")
    func share() throws {
        #expect(try Percentage.share(of: 30, in: 120) == 25)
        #expect(throws: DivisionByZeroError(operand: "total")) {
            try Percentage.share(of: 1, in: 0)
        }
    }

    @Test("reports a zero base through the engine")
    func zeroBaseThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let result = try await engine.calculate(
            .percentage,
            PercentageOperation.percentageChange,
            [P.originalValue.name: 0, P.updatedValue.name: 10]
        )

        #expect(result == .failure(.divisionByZero(DivisionByZeroError(operand: "original value"))))
    }
}
