// Worked examples document an operation with concrete numbers; those literals are the data being documented.
// swiftlint:disable no_magic_numbers

extension ModuleName {
    /// Unit conversion.
    public static let conversion = ModuleName("conversion")
}

/// Failures of the conversion module.
enum ConversionError: Error, Sendable, Equatable {
    /// The two units measure different quantities.
    case incompatibleDimensions(from: UnitDimension, to: UnitDimension)

    /// A temperature below absolute zero cannot exist.
    case belowAbsoluteZero
}

extension ConversionError: CalculationFailure {
    /// Maps each failure to its stable, user-facing representation.
    var calculationError: CalculationError {
        switch self {
        case .incompatibleDimensions(let source, let target):
            .invalidParameter(
                ConversionParameters.target.name,
                reason: "must measure the same quantity as '\(ConversionParameters.source.name)', "
                    + "but \(source) cannot be converted to \(target)"
            )
        case .belowAbsoluteZero:
            .invalidParameter(ConversionParameters.value.name, reason: "is below absolute zero")
        }
    }
}

/// Converts values between units of the same dimension.
enum UnitConverter {
    /// Converts a value from one unit to another.
    ///
    /// - Parameters:
    ///   - value: The value to convert.
    ///   - source: The unit the value is expressed in.
    ///   - target: The unit to convert to.
    /// - Returns: The value in the target unit.
    /// - Throws: ``ConversionError/incompatibleDimensions(from:to:)`` when the units measure different quantities,
    ///   and ``ConversionError/belowAbsoluteZero`` for a temperature that cannot exist.
    static func convert(
        _ value: Double,
        from source: MeasurementUnit,
        to target: MeasurementUnit
    ) throws(ConversionError) -> Double {
        guard source.dimension == target.dimension else {
            throw .incompatibleDimensions(from: source.dimension, to: target.dimension)
        }

        let base = source.toBase(value)
        guard source.dimension != .temperature || base >= 0 else {
            throw .belowAbsoluteZero
        }
        return target.fromBase(base)
    }
}

/// Parameters of the conversion operation. Each name is spelled once, here.
enum ConversionParameters {
    static let value = ParameterSpec.number("value", summary: "The quantity to convert.")
    static let source = unit("from", summary: "The unit the value is expressed in, such as km, lb, degC or GiB.")
    static let target = unit("to", summary: "The unit to convert to; it must measure the same quantity as 'from'.")

    private static func unit(
        _ name: String,
        summary: String
    ) -> ParameterSpec<MeasurementUnit> {
        ParameterSpec(
            name: name,
            summary: summary,
            kind: .choice(UnitCatalog.symbols),
            extract: { (raw) throws(ParameterRejection) in
                guard case .text(let symbol) = raw, let unit = UnitCatalog.unit(symbol: symbol) else {
                    throw ParameterRejection(reason: ParameterMessage.unknownChoice(allowed: UnitCatalog.symbols))
                }
                return unit
            }
        )
    }
}

/// Wire names of the conversion operations.
enum ConversionOperation: String, CaseIterable {
    case convert
}

/// Converts quantities between units of length, mass, temperature, time, area, volume, speed, pressure, energy,
/// power, data size, angle and frequency.
public struct ConversionModule: CalculationModule {
    /// Name of the module on the wire.
    public let name = ModuleName.conversion

    /// One-sentence description of what the module covers.
    public let summary = "Unit conversion across thirteen dimensions, from length and mass to data size and angle."

    /// The operations the module offers, one per case of its operation enumeration.
    public let operations: [OperationDefinition]

    /// Creates the module.
    public init() {
        operations = ConversionOperation.allCases.map(Self.definition(for:))
    }

    private typealias P = ConversionParameters

    /// Maps every operation to its definition. The switch is exhaustive, so adding an operation without a
    /// definition does not compile.
    private static func definition(for operation: ConversionOperation) -> OperationDefinition {
        switch operation {
        case .convert: convert
        }
    }

    private static let convert = OperationDefinition(
        name: ConversionOperation.convert,
        summary: "Converts a value between two units of the same dimension.",
        parameters: [P.value, P.source, P.target],
        result: .number,
        examples: [
            OperationExample(
                "Kilometres to metres.",
                with: [(P.value, 1), (P.source, "km"), (P.target, "m")],
                yields: 1_000
            ),
            OperationExample(
                "Water boils at 100 degrees Celsius.",
                with: [(P.value, 100), (P.source, "degC"), (P.target, "degF")],
                yields: 212
            ),
            OperationExample(
                "A mile in kilometres.",
                with: [(P.value, 1), (P.source, "mi"), (P.target, "km")],
                yields: 1.609_344
            ),
            OperationExample(
                "A gibibyte in bytes.",
                with: [(P.value, 1), (P.source, "GiB"), (P.target, "B")],
                yields: 1_073_741_824
            ),
            OperationExample(
                "A speed limit in kilometres per hour.",
                with: [(P.value, 60), (P.source, "mph"), (P.target, "km/h")],
                yields: 96.560_64
            ),
            OperationExample(
                "A half turn in radians.",
                with: [(P.value, 180), (P.source, "deg"), (P.target, "rad")],
                yields: 3.141_592_653_589_793
            ),
        ],
        compute: { arguments in
            .number(
                try UnitConverter.convert(arguments[P.value], from: arguments[P.source], to: arguments[P.target])
            )
        }
    )
}

// swiftlint:enable no_magic_numbers
