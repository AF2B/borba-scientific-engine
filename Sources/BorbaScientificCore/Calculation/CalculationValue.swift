/// A JSON-shaped value: the common currency between the transport layer and the calculation modules.
///
/// Parameters arrive as values of this type and results leave as values of this type. Modules convert to and
/// from their own strongly typed domain models at the edge, so the rest of the engine never needs to know what
/// a particular operation computes.
public enum CalculationValue: Sendable, Equatable {
    case null
    case boolean(Bool)
    case number(Double)
    case text(String)
    case list([CalculationValue])
    case object([String: CalculationValue])
}

// MARK: - Convenience constructors

extension CalculationValue {
    /// Builds a list of numbers.
    ///
    /// - Parameter values: The numbers to wrap.
    /// - Returns: A list value holding one number per element.
    public static func numbers(_ values: [Double]) -> CalculationValue {
        .list(values.map(CalculationValue.number))
    }

    /// Builds a list of lists of numbers.
    ///
    /// - Parameter rows: The rows of the matrix.
    /// - Returns: A list value holding one list of numbers per row.
    public static func matrix(_ rows: [[Double]]) -> CalculationValue {
        .list(rows.map(CalculationValue.numbers))
    }

    /// Builds an object from key and value pairs.
    ///
    /// - Parameter fields: Pairs to store; later pairs replace earlier ones with the same key.
    /// - Returns: An object value.
    public static func fields(_ fields: KeyValuePairs<String, CalculationValue>) -> CalculationValue {
        .object(Dictionary(fields.map { ($0.key, $0.value) }, uniquingKeysWith: { _, latest in latest }))
    }
}

// MARK: - Inspection

extension CalculationValue {
    /// The number held by this value, if it is one.
    public var number: Double? {
        guard case .number(let value) = self else {
            return nil
        }
        return value
    }

    /// The text held by this value, if it is one.
    public var text: String? {
        guard case .text(let value) = self else {
            return nil
        }
        return value
    }

    /// The elements held by this value, if it is a list.
    public var elements: [CalculationValue]? {
        guard case .list(let values) = self else {
            return nil
        }
        return values
    }

    /// The fields held by this value, if it is an object.
    public var fields: [String: CalculationValue]? {
        guard case .object(let values) = self else {
            return nil
        }
        return values
    }

    /// The first infinite or NaN number found in the value or anything nested in it.
    public var firstNonFiniteNumber: Double? {
        switch self {
        case .number(let value):
            value.isFinite ? nil : value
        case .list(let values):
            values.lazy.compactMap(\.firstNonFiniteNumber).first
        case .object(let values):
            values.values.lazy.compactMap(\.firstNonFiniteNumber).first
        case .null, .boolean, .text:
            nil
        }
    }
}

// MARK: - Codable

extension CalculationValue: Codable {
    /// Why a text is refused when it holds a NUL character, so that the layer that reports the failure can say so.
    public static let nulCharacterDescription = "Text must not contain NUL characters."

    private static let nulByte: UInt8 = 0

    /// Decodes any JSON value.
    ///
    /// The cases are tried from the most common to the least: parameters are overwhelmingly numbers, and every attempt that
    /// does not fit costs an error, so numbers are tried first, then booleans and text. A list is first tried as a list of
    /// numbers, which JSON decoders read in one pass; only a list that is not purely numeric is read element by element.
    ///
    /// Text and the names of fields never hold a NUL character. JSON can write one, but PostgreSQL cannot store it in text
    /// or in JSON, and the values of a request are stored with the calculation they belong to, so a NUL that got in would
    /// surface as a failure of the database. It is refused where it enters.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A decoding error when the value is not valid JSON of a supported shape, or holds a NUL character.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(String.self) {
            self = .text(try Self.withoutNUL(value, in: container))
        } else if let numbers = try? container.decode([Double].self) {
            self = .list(numbers.map(CalculationValue.number))
        } else {
            self = try Self.decodeStructure(from: container)
        }
    }

    /// A list or an object, whichever the container holds.
    ///
    /// Only the failure to be a list leads to reading an object. Anything else that went wrong inside is the caller's to see:
    /// swallowing it would report a NUL deep in a list as a list that is not an object.
    private static func decodeStructure(from container: any SingleValueDecodingContainer) throws -> CalculationValue {
        do {
            return .list(try container.decode([CalculationValue].self))
        } catch DecodingError.typeMismatch {
            let fields = try container.decode([String: CalculationValue].self)
            for name in fields.keys {
                _ = try withoutNUL(name, in: container)
            }
            return .object(fields)
        }
    }

    private static func withoutNUL(
        _ text: String,
        in container: any SingleValueDecodingContainer
    ) throws -> String {
        guard !text.utf8.contains(nulByte) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: nulCharacterDescription)
        }
        return text
    }

    /// Encodes the value as plain JSON.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An encoding error, for example when a number is not finite.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .boolean(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .text(let value):
            try container.encode(value)
        case .list(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }
}

// MARK: - Literals

extension CalculationValue: ExpressibleByNilLiteral {
    /// Creates ``null``.
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension CalculationValue: ExpressibleByBooleanLiteral {
    /// Creates a ``boolean(_:)`` value.
    public init(booleanLiteral value: Bool) {
        self = .boolean(value)
    }
}

extension CalculationValue: ExpressibleByIntegerLiteral {
    /// Creates a ``number(_:)`` value.
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension CalculationValue: ExpressibleByFloatLiteral {
    /// Creates a ``number(_:)`` value.
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension CalculationValue: ExpressibleByStringLiteral {
    /// Creates a ``text(_:)`` value.
    public init(stringLiteral value: String) {
        self = .text(value)
    }
}

extension CalculationValue: ExpressibleByArrayLiteral {
    /// Creates a ``list(_:)`` value.
    public init(arrayLiteral elements: CalculationValue...) {
        self = .list(elements)
    }
}

extension CalculationValue: ExpressibleByDictionaryLiteral {
    /// Creates an ``object(_:)`` value.
    public init(dictionaryLiteral elements: (String, CalculationValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, latest in latest }))
    }
}
