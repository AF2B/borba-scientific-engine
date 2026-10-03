import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("Conversion")
struct ConversionTests {
    private typealias P = ConversionParameters

    private func unit(_ symbol: String) throws -> MeasurementUnit {
        try #require(UnitCatalog.unit(symbol: symbol), "unknown unit \(symbol)")
    }

    private func isClose(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double = 1e-12
    ) -> Bool {
        abs(lhs - rhs) <= tolerance * max(1, abs(rhs))
    }

    @Test(
        "converts between units",
        arguments: [
            (1.0, "km", "m", 1_000.0),
            (1.0, "mi", "km", 1.609_344),
            (12.0, "in", "ft", 1.0),
            (1.0, "lb", "kg", 0.453_592_37),
            (16.0, "oz", "lb", 1.0),
            (1.0, "h", "min", 60.0),
            (1.0, "wk", "d", 7.0),
            (1.0, "ha", "m2", 10_000.0),
            (1.0, "gal", "L", 3.785_411_784),
            (4.0, "qt", "gal", 1.0),
            (60.0, "mph", "km/h", 96.560_64),
            (1.0, "kn", "km/h", 1.852),
            (1.0, "atm", "kPa", 101.325),
            (1.0, "bar", "Pa", 100_000.0),
            (1.0, "kWh", "MJ", 3.6),
            (1.0, "kcal", "cal", 1_000.0),
            (1.0, "GiB", "MiB", 1_024.0),
            (1.0, "GB", "MB", 1_000.0),
            (1.0, "B", "bit", 8.0),
            (180.0, "deg", "rad", 3.141_592_653_589_793),
            (1.0, "turn", "deg", 360.0),
            (1.0, "GHz", "MHz", 1_000.0),
        ]
    )
    func linearConversions(
        value: Double,
        source: String,
        target: String,
        expected: Double
    ) throws {
        #expect(isClose(try UnitConverter.convert(value, from: unit(source), to: unit(target)), expected))
    }

    @Test(
        "converts temperatures, whose scales have different zeros",
        arguments: [
            (100.0, "degC", "degF", 212.0),
            (0.0, "degC", "K", 273.15),
            (32.0, "degF", "degC", 0.0),
            (-40.0, "degC", "degF", -40.0),
            (0.0, "K", "degC", -273.15),
            (491.67, "degR", "degC", 0.0),
            (98.6, "degF", "degC", 37.0),
        ]
    )
    func temperatureConversions(
        value: Double,
        source: String,
        target: String,
        expected: Double
    ) throws {
        #expect(
            isClose(try UnitConverter.convert(value, from: unit(source), to: unit(target)), expected, tolerance: 1e-9)
        )
    }

    @Test("refuses temperatures below absolute zero", arguments: [(-273.16, "degC"), (-459.68, "degF"), (-1.0, "K")])
    func belowAbsoluteZero(
        value: Double,
        symbol: String
    ) throws {
        let source = try unit(symbol)
        let kelvin = try unit("K")

        #expect(throws: ConversionError.belowAbsoluteZero) {
            try UnitConverter.convert(value, from: source, to: kelvin)
        }
    }

    @Test("accepts absolute zero itself")
    func absoluteZero() throws {
        #expect(try UnitConverter.convert(-273.15, from: unit("degC"), to: unit("K")) == 0)
    }

    @Test("refuses to convert between different dimensions")
    func incompatibleDimensions() throws {
        let metre = try unit("m")
        let kilogram = try unit("kg")

        #expect(throws: ConversionError.incompatibleDimensions(from: .length, to: .mass)) {
            try UnitConverter.convert(1, from: metre, to: kilogram)
        }
    }

    @Test("round-trips through every unit of every dimension", arguments: UnitDimension.allCases)
    func roundTrips(dimension: UnitDimension) throws {
        let units = UnitCatalog.all.filter { $0.dimension == dimension }
        let base = try #require(units.first { $0.symbol == dimension.baseUnitSymbol })

        for candidate in units {
            let there = try UnitConverter.convert(42, from: candidate, to: base)
            let back = try UnitConverter.convert(there, from: base, to: candidate)

            #expect(isClose(back, 42, tolerance: 1e-9), "\(candidate.symbol) does not round-trip")
        }
    }

    @Test("the catalog is internally consistent")
    func catalogInvariants() {
        let symbols = UnitCatalog.all.map(\.symbol)

        #expect(Set(symbols).count == symbols.count, "unit symbols must be unique")
        #expect(UnitCatalog.all.allSatisfy { $0.scale > 0 })
        #expect(UnitCatalog.all.allSatisfy { !$0.name.isEmpty })
        #expect(Set(UnitCatalog.all.map(\.dimension)) == Set(UnitDimension.allCases))

        for dimension in UnitDimension.allCases {
            let base = UnitCatalog.unit(symbol: dimension.baseUnitSymbol)
            #expect(base?.dimension == dimension, "\(dimension) needs a base unit")
            #expect(base?.scale == 1 && base?.offset == 0, "the base unit of \(dimension) must be the identity")
        }
    }

    @Test("maps conversion failures to the offending parameter")
    func mapsFailures() {
        let incompatible = ConversionError.incompatibleDimensions(from: .length, to: .mass).calculationError
        let cold = ConversionError.belowAbsoluteZero.calculationError

        #expect(incompatible.code == .validationFailed)
        #expect(incompatible.details.first?.field == "to")
        #expect(cold.details.first?.field == "value")
    }

    @Test("rejects an unknown unit and lists the valid ones")
    func unknownUnitThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let error = await #expect(throws: CalculationError.self) {
            try await engine.calculate(
                .conversion,
                ConversionOperation.convert,
                [P.value.name: 1, P.source.name: "parsec", P.target.name: "m"]
            )
        }

        #expect(error?.details.first?.field == "from")
        #expect(error?.details.first?.reason.hasPrefix("must be one of: ") == true)
    }

    @Test("reports a dimension mismatch through the engine")
    func mismatchThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let result = try await engine.calculate(
            .conversion,
            ConversionOperation.convert,
            [P.value.name: 1, P.source.name: "m", P.target.name: "kg"]
        )

        #expect(result.failure?.code == .validationFailed)
    }
}
