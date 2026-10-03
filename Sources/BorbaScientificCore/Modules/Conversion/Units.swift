// Conversion factors are reference data: every numeric literal below is the definition of the unit it appears in
// (for example one inch is exactly 0.0254 metres), so naming each one separately would only repeat the unit's name.
// swiftlint:disable no_magic_numbers

/// A kind of physical quantity. Units convert into each other only within one dimension.
enum UnitDimension: String, CaseIterable, Sendable {
    case length
    case mass
    case temperature
    case time
    case area
    case volume
    case speed
    case pressure
    case energy
    case power
    case data
    case angle
    case frequency

    /// Symbol of the unit every other unit of the dimension is defined against.
    var baseUnitSymbol: String {
        switch self {
        case .length: "m"
        case .mass: "kg"
        case .temperature: "K"
        case .time: "s"
        case .area: "m2"
        case .volume: "m3"
        case .speed: "m/s"
        case .pressure: "Pa"
        case .energy: "J"
        case .power: "W"
        case .data: "bit"
        case .angle: "rad"
        case .frequency: "Hz"
        }
    }
}

/// A unit of measurement, defined by how it maps onto the base unit of its dimension:
/// `base = value * scale + offset`.
struct MeasurementUnit: Sendable, Equatable {
    /// Short ASCII symbol used on the wire, such as `km`.
    let symbol: String

    /// Full English name.
    let name: String

    /// The quantity the unit measures.
    let dimension: UnitDimension

    /// How many base units one of this unit is worth.
    let scale: Double

    /// Added after scaling; non-zero only for temperature scales whose zero differs from the base unit's.
    let offset: Double

    /// Converts a value in this unit to the base unit of its dimension.
    ///
    /// - Parameter value: The value in this unit.
    /// - Returns: The value in the base unit.
    func toBase(_ value: Double) -> Double {
        value * scale + offset
    }

    /// Converts a value in the base unit of the dimension to this unit.
    ///
    /// - Parameter base: The value in the base unit.
    /// - Returns: The value in this unit.
    func fromBase(_ base: Double) -> Double {
        (base - offset) / scale
    }

    fileprivate static func linear(
        _ symbol: String,
        _ name: String,
        _ dimension: UnitDimension,
        _ scale: Double
    ) -> MeasurementUnit {
        MeasurementUnit(symbol: symbol, name: name, dimension: dimension, scale: scale, offset: 0)
    }
}

/// Every unit the conversion module understands.
enum UnitCatalog {
    /// All units, grouped by dimension.
    static let all: [MeasurementUnit] =
        length + mass + temperature + time + area + volume + speed + pressure + energy + power + data + angle
        + frequency

    /// All symbols, sorted, for documentation.
    static let symbols: [String] = all.map(\.symbol).sorted()

    private static let bySymbol: [String: MeasurementUnit] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.symbol, $0) }
    )

    /// Finds a unit by its wire symbol.
    ///
    /// - Parameter symbol: The symbol, for example `km`. Symbols are case-sensitive.
    /// - Returns: The unit, or `nil` when the symbol is unknown.
    static func unit(symbol: String) -> MeasurementUnit? {
        bySymbol[symbol]
    }

    private static let length: [MeasurementUnit] = [
        .linear("m", "metre", .length, 1),
        .linear("km", "kilometre", .length, 1_000),
        .linear("cm", "centimetre", .length, 0.01),
        .linear("mm", "millimetre", .length, 0.001),
        .linear("um", "micrometre", .length, 1e-6),
        .linear("nm", "nanometre", .length, 1e-9),
        .linear("in", "inch", .length, 0.0254),
        .linear("ft", "foot", .length, 0.3048),
        .linear("yd", "yard", .length, 0.9144),
        .linear("mi", "mile", .length, 1_609.344),
        .linear("nmi", "nautical mile", .length, 1_852),
    ]

    private static let mass: [MeasurementUnit] = [
        .linear("kg", "kilogram", .mass, 1),
        .linear("g", "gram", .mass, 0.001),
        .linear("mg", "milligram", .mass, 1e-6),
        .linear("ug", "microgram", .mass, 1e-9),
        .linear("t", "tonne", .mass, 1_000),
        .linear("lb", "pound", .mass, 0.453_592_37),
        .linear("oz", "ounce", .mass, 0.028_349_523_125),
        .linear("st", "stone", .mass, 6.350_293_18),
    ]

    private static let temperature: [MeasurementUnit] = [
        .linear("K", "kelvin", .temperature, 1),
        MeasurementUnit(symbol: "degC", name: "degree Celsius", dimension: .temperature, scale: 1, offset: 273.15),
        MeasurementUnit(
            symbol: "degF",
            name: "degree Fahrenheit",
            dimension: .temperature,
            scale: 5.0 / 9.0,
            offset: 459.67 * 5.0 / 9.0
        ),
        .linear("degR", "degree Rankine", .temperature, 5.0 / 9.0),
    ]

    private static let time: [MeasurementUnit] = [
        .linear("s", "second", .time, 1),
        .linear("ms", "millisecond", .time, 0.001),
        .linear("us", "microsecond", .time, 1e-6),
        .linear("ns", "nanosecond", .time, 1e-9),
        .linear("min", "minute", .time, 60),
        .linear("h", "hour", .time, 3_600),
        .linear("d", "day", .time, 86_400),
        .linear("wk", "week", .time, 604_800),
        .linear("yr", "Julian year", .time, 31_557_600),
    ]

    private static let area: [MeasurementUnit] = [
        .linear("m2", "square metre", .area, 1),
        .linear("km2", "square kilometre", .area, 1e6),
        .linear("cm2", "square centimetre", .area, 1e-4),
        .linear("mm2", "square millimetre", .area, 1e-6),
        .linear("ha", "hectare", .area, 10_000),
        .linear("in2", "square inch", .area, 0.000_645_16),
        .linear("ft2", "square foot", .area, 0.092_903_04),
        .linear("yd2", "square yard", .area, 0.836_127_36),
        .linear("ac", "acre", .area, 4_046.856_422_4),
        .linear("mi2", "square mile", .area, 2_589_988.110_336),
    ]

    private static let volume: [MeasurementUnit] = [
        .linear("m3", "cubic metre", .volume, 1),
        .linear("L", "litre", .volume, 0.001),
        .linear("mL", "millilitre", .volume, 1e-6),
        .linear("cm3", "cubic centimetre", .volume, 1e-6),
        .linear("in3", "cubic inch", .volume, 1.638_706_4e-5),
        .linear("ft3", "cubic foot", .volume, 0.028_316_846_592),
        .linear("gal", "US gallon", .volume, 0.003_785_411_784),
        .linear("qt", "US quart", .volume, 0.000_946_352_946),
        .linear("pt", "US pint", .volume, 0.000_473_176_473),
        .linear("cup", "US cup", .volume, 0.000_236_588_236_5),
        .linear("floz", "US fluid ounce", .volume, 2.957_352_956_25e-5),
        .linear("tbsp", "US tablespoon", .volume, 1.478_676_478_125e-5),
        .linear("tsp", "US teaspoon", .volume, 4.928_921_593_75e-6),
    ]

    private static let speed: [MeasurementUnit] = [
        .linear("m/s", "metre per second", .speed, 1),
        .linear("km/h", "kilometre per hour", .speed, 1.0 / 3.6),
        .linear("mph", "mile per hour", .speed, 0.447_04),
        .linear("kn", "knot", .speed, 1_852.0 / 3_600.0),
        .linear("ft/s", "foot per second", .speed, 0.3048),
    ]

    private static let pressure: [MeasurementUnit] = [
        .linear("Pa", "pascal", .pressure, 1),
        .linear("kPa", "kilopascal", .pressure, 1_000),
        .linear("MPa", "megapascal", .pressure, 1e6),
        .linear("bar", "bar", .pressure, 100_000),
        .linear("mbar", "millibar", .pressure, 100),
        .linear("atm", "standard atmosphere", .pressure, 101_325),
        .linear("psi", "pound per square inch", .pressure, 6_894.757_293_168),
        .linear("mmHg", "millimetre of mercury", .pressure, 133.322_387_415),
        .linear("torr", "torr", .pressure, 101_325.0 / 760.0),
    ]

    private static let energy: [MeasurementUnit] = [
        .linear("J", "joule", .energy, 1),
        .linear("kJ", "kilojoule", .energy, 1_000),
        .linear("MJ", "megajoule", .energy, 1e6),
        .linear("cal", "thermochemical calorie", .energy, 4.184),
        .linear("kcal", "kilocalorie", .energy, 4_184),
        .linear("Wh", "watt hour", .energy, 3_600),
        .linear("kWh", "kilowatt hour", .energy, 3_600_000),
        .linear("eV", "electronvolt", .energy, 1.602_176_634e-19),
        .linear("BTU", "British thermal unit", .energy, 1_055.055_852_62),
    ]

    private static let power: [MeasurementUnit] = [
        .linear("W", "watt", .power, 1),
        .linear("kW", "kilowatt", .power, 1_000),
        .linear("MW", "megawatt", .power, 1e6),
        .linear("hp", "mechanical horsepower", .power, 745.699_871_582_270_2),
    ]

    private static let data: [MeasurementUnit] = [
        .linear("bit", "bit", .data, 1),
        .linear("B", "byte", .data, 8),
        .linear("kB", "kilobyte", .data, 8_000),
        .linear("MB", "megabyte", .data, 8e6),
        .linear("GB", "gigabyte", .data, 8e9),
        .linear("TB", "terabyte", .data, 8e12),
        .linear("KiB", "kibibyte", .data, 8 * 1_024),
        .linear("MiB", "mebibyte", .data, 8 * 1_048_576),
        .linear("GiB", "gibibyte", .data, 8 * 1_073_741_824),
        .linear("TiB", "tebibyte", .data, 8 * 1_099_511_627_776),
    ]

    private static let angle: [MeasurementUnit] = [
        .linear("rad", "radian", .angle, 1),
        .linear("deg", "degree", .angle, .pi / 180),
        .linear("grad", "gradian", .angle, .pi / 200),
        .linear("turn", "full turn", .angle, 2 * .pi),
    ]

    private static let frequency: [MeasurementUnit] = [
        .linear("Hz", "hertz", .frequency, 1),
        .linear("kHz", "kilohertz", .frequency, 1_000),
        .linear("MHz", "megahertz", .frequency, 1e6),
        .linear("GHz", "gigahertz", .frequency, 1e9),
    ]
}

// swiftlint:enable no_magic_numbers
