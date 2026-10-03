import Foundation
import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("Scientific")
struct ScientificTests {
    private typealias P = ScientificParameters

    private func isClose(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double = 1e-12
    ) -> Bool {
        abs(lhs - rhs) <= tolerance * max(1, abs(rhs))
    }

    @Test(
        "evaluates trigonometric functions in either unit",
        arguments: [
            (30.0, AngleUnit.degrees, 0.5, 0.866_025_403_784_438_6),
            (0.0, .radians, 0.0, 1.0),
            (Double.pi / 2, .radians, 1.0, 0.0),
            (180.0, .degrees, 0.0, -1.0),
        ]
    )
    func sineAndCosine(
        angle: Double,
        unit: AngleUnit,
        sine: Double,
        cosine: Double
    ) {
        #expect(isClose(Scientific.sine(angle, in: unit), sine))
        #expect(isClose(Scientific.cosine(angle, in: unit), cosine))
    }

    @Test("converts between angle units")
    func angleUnits() {
        #expect(isClose(AngleUnit.degrees.toRadians(180), .pi))
        #expect(isClose(AngleUnit.degrees.fromRadians(.pi / 2), 90))
        #expect(AngleUnit.radians.toRadians(1.5) == 1.5)
    }

    @Test("computes tangents away from the singularities")
    func tangent() throws {
        #expect(isClose(try Scientific.tangent(45, in: .degrees), 1))
        #expect(isClose(try Scientific.tangent(-45, in: .degrees), -1))
    }

    @Test(
        "reports the tangent as undefined at odd multiples of a quarter turn",
        arguments: [(90.0, AngleUnit.degrees), (-90.0, .degrees), (270.0, .degrees), (Double.pi / 2, .radians)]
    )
    func tangentSingularities(
        angle: Double,
        unit: AngleUnit
    ) {
        #expect(throws: ScientificError.tangentUndefined) {
            try Scientific.tangent(angle, in: unit)
        }
    }

    @Test(
        "resolves the quadrant with the two-argument arctangent",
        arguments: [(1.0, 1.0, 45.0), (1.0, -1.0, 135.0), (-1.0, -1.0, -135.0), (-1.0, 1.0, -45.0), (0.0, -1.0, 180.0)]
    )
    func arctangent(
        y: Double,
        x: Double,
        expectedDegrees: Double
    ) throws {
        #expect(isClose(try Scientific.arctangent(y: y, x: x, in: .degrees), expectedDegrees))
    }

    @Test("has no direction for the origin")
    func arctangentOfOrigin() {
        #expect(throws: ScientificError.arctangentOfOrigin) {
            try Scientific.arctangent(y: 0, x: 0, in: .radians)
        }
    }

    @Test("computes logarithms to any valid base")
    func logarithms() throws {
        #expect(isClose(try Scientific.logarithm(of: 1_000, base: 10), 3))
        #expect(isClose(try Scientific.logarithm(of: 8, base: 2), 3))
        #expect(isClose(try Scientific.logarithm(of: 0.25, base: 2), -2))
    }

    @Test("refuses a logarithm to base one")
    func logarithmBaseOne() {
        #expect(throws: ScientificError.logarithmBaseOne) {
            try Scientific.logarithm(of: 5, base: 1)
        }
    }

    @Test(
        "computes real roots of any degree",
        arguments: [(32.0, 5, 2.0), (-27.0, 3, -3.0), (16.0, 4, 2.0), (0.0, 2, 0.0), (-32.0, 5, -2.0)]
    )
    func roots(
        value: Double,
        degree: Int,
        expected: Double
    ) throws {
        #expect(isClose(try Scientific.root(of: value, degree: degree), expected))
    }

    @Test("has no real even root of a negative number")
    func evenRootOfNegative() {
        #expect(throws: ScientificError.evenRootOfNegative(degree: 4)) {
            try Scientific.root(of: -16, degree: 4)
        }
    }

    @Test(
        "counts combinations",
        arguments: [(5, 2, 10.0), (52, 5, 2_598_960.0), (10, 0, 1.0), (10, 10, 1.0), (6, 3, 20.0)]
    )
    func combinations(
        population: Int,
        selected: Int,
        expected: Double
    ) throws {
        #expect(try Scientific.combinations(of: population, choosing: selected) == expected)
        #expect(try Scientific.combinations(of: population, choosing: population - selected) == expected)
    }

    @Test("counts permutations", arguments: [(5, 2, 20.0), (5, 5, 120.0), (10, 0, 1.0), (4, 1, 4.0)])
    func permutations(
        population: Int,
        selected: Int,
        expected: Double
    ) throws {
        #expect(try Scientific.permutations(of: population, choosing: selected) == expected)
    }

    @Test("refuses to select more items than exist")
    func selectionLargerThanPopulation() {
        #expect(throws: ScientificError.selectionLargerThanPopulation(selected: 6, population: 5)) {
            try Scientific.combinations(of: 5, choosing: 6)
        }
        #expect(throws: ScientificError.selectionLargerThanPopulation(selected: 6, population: 5)) {
            try Scientific.permutations(of: 5, choosing: 6)
        }
    }

    @Test("keeps the largest supported combination finite")
    func largestCombination() throws {
        let value = try Scientific.combinations(
            of: Scientific.largestPopulation,
            choosing: Scientific.largestPopulation / 2
        )

        #expect(value.isFinite && value > 1e299)
    }

    @Test("reports permutations that overflow through the engine")
    func permutationOverflowThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let result = try await engine.calculate(
            .scientific,
            ScientificOperation.permutations,
            [P.population.name: 1_000, P.selected.name: 1_000]
        )

        #expect(result == .failure(.numericOverflow))
    }

    @Test("rejects values outside the domain of a function through the engine")
    func domainsThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let squareRoot = await #expect(throws: CalculationError.self) {
            try await engine.calculate(.scientific, ScientificOperation.squareRoot, [P.nonNegativeValue.name: -1])
        }
        let arcsine = await #expect(throws: CalculationError.self) {
            try await engine.calculate(.scientific, ScientificOperation.arcsine, [P.sineValue.name: 2])
        }
        let logarithm = await #expect(throws: CalculationError.self) {
            try await engine.calculate(.scientific, ScientificOperation.naturalLogarithm, [P.positiveValue.name: 0])
        }

        #expect(squareRoot?.details == [ErrorDetail(field: "value", reason: "must be at least 0")])
        #expect(arcsine?.details == [ErrorDetail(field: "value", reason: "must be at most 1")])
        #expect(logarithm?.details == [ErrorDetail(field: "value", reason: "must be greater than 0")])
    }

    @Test("maps scientific failures to stable error codes")
    func mapsFailures() {
        #expect(ScientificError.tangentUndefined.calculationError.code == .undefinedResult)
        #expect(ScientificError.evenRootOfNegative(degree: 2).calculationError.code == .undefinedResult)
        #expect(ScientificError.arctangentOfOrigin.calculationError.code == .undefinedResult)
        #expect(ScientificError.logarithmBaseOne.calculationError.code == .validationFailed)
        #expect(
            ScientificError.selectionLargerThanPopulation(selected: 2, population: 1).calculationError.code
                == .validationFailed
        )
    }

    @Test("describes every constant with a unit and a source", arguments: PhysicalConstant.allCases)
    func constantsAreDescribed(constant: PhysicalConstant) {
        let definition = constant.definition

        #expect(definition.value > 0)
        #expect(!definition.unit.isEmpty)
        #expect(!definition.source.isEmpty)
        #expect(definition.uncertainty >= 0)
        #expect(definition.uncertainty < definition.value)
    }

    @Test("derived constants are consistent with the defining ones")
    func constantsAreConsistent() {
        let planck = PhysicalConstant.planckConstant.definition.value
        let reducedPlanck = PhysicalConstant.reducedPlanckConstant.definition.value
        let boltzmann = PhysicalConstant.boltzmannConstant.definition.value
        let avogadro = PhysicalConstant.avogadroConstant.definition.value
        let gas = PhysicalConstant.molarGasConstant.definition.value
        let light = PhysicalConstant.speedOfLight.definition.value
        let stefan = PhysicalConstant.stefanBoltzmannConstant.definition.value

        #expect(isClose(reducedPlanck, planck / (2 * .pi), tolerance: 1e-14))
        #expect(isClose(gas, avogadro * boltzmann, tolerance: 1e-14))
        #expect(
            isClose(
                stefan,
                pow(Double.pi, 2) * pow(boltzmann, 4) / (60 * pow(reducedPlanck, 3) * pow(light, 2)),
                tolerance: 1e-12
            )
        )
    }

    @Test("marks measured constants with their uncertainty and exact ones with none")
    func constantUncertainty() {
        #expect(PhysicalConstant.speedOfLight.definition.uncertainty == 0)
        #expect(PhysicalConstant.gravitationalConstant.definition.uncertainty > 0)
        #expect(PhysicalConstant.gravitationalConstant.definition.source == "CODATA 2022")
    }
}
