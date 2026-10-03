/// The reason a single parameter value was rejected. Never escapes the validation step: it is turned into a
/// ``ValidationIssue`` that names the parameter.
public struct ParameterRejection: Error, Sendable, Equatable {
    /// Why the value was rejected, phrased so it can be shown to the caller.
    public let reason: String

    /// Creates a rejection.
    ///
    /// - Parameter reason: Why the value was rejected.
    public init(reason: String) {
        self.reason = reason
    }
}

/// The shape of values a parameter accepts, together with its constraints. Used for documentation and metadata.
public enum ParameterKind: Sendable, Equatable {
    /// A finite number within bounds.
    case number(NumberBounds)

    /// A whole number within an inclusive range.
    case integer(ClosedRange<Int>)

    /// A decimal amount, written as a number or as numeric text, within bounds.
    case decimal(NumberBounds)

    /// `true` or `false`.
    case boolean

    /// Free text up to a maximum length.
    case text(maximumLength: Int)

    /// One of a closed set of names.
    case choice([String])

    /// A list of finite numbers.
    case numberList(size: ClosedRange<Int>, elements: NumberBounds)

    /// A list of decimal amounts.
    case decimalList(size: ClosedRange<Int>)

    /// A rectangular matrix of finite numbers.
    case numberMatrix(rows: ClosedRange<Int>, columns: ClosedRange<Int>)

    /// A map from names to finite numbers.
    case numberMap(size: ClosedRange<Int>)
}

/// Whether a parameter must be supplied.
public enum ParameterRequirement: Sendable, Equatable {
    /// The caller must supply a value.
    case required

    /// The caller may omit the value, in which case `defaultValue` applies.
    case optional(defaultValue: CalculationValue)
}

/// Documentation-level description of a parameter.
public struct ParameterDescriptor: Sendable, Equatable {
    /// Name of the parameter on the wire.
    public let name: String

    /// What the parameter means.
    public let summary: String

    /// Accepted shape and constraints.
    public let kind: ParameterKind

    /// Whether the parameter must be supplied.
    public let requirement: ParameterRequirement
}

/// A parameter declaration that can validate raw input, independently of the type of value it produces.
///
/// This type-erased view lets an operation hold its parameters in one list while each ``ParameterSpec`` keeps
/// its own strongly typed value.
public protocol ParameterDeclaration: Sendable {
    /// Documentation-level description of the parameter.
    var descriptor: ParameterDescriptor { get }

    /// Validates the raw input for this parameter.
    ///
    /// - Parameter raw: The value supplied by the caller, or `nil` when it was omitted.
    /// - Returns: The typed value, boxed so declarations of different types can share one list.
    /// - Throws: ``ParameterRejection`` when the value is missing without a default, or violates a constraint.
    func bind(_ raw: CalculationValue?) throws(ParameterRejection) -> any Sendable
}

/// A typed parameter: its wire name, its documentation, and the rule that turns raw input into a `Value`.
///
/// Operations declare their parameters as `ParameterSpec` constants and read the validated values back through
/// ``Arguments``. Because the same constant is used to declare and to read a parameter, the name is spelled exactly
/// once and the type of the value is checked by the compiler.
public struct ParameterSpec<Value: Sendable>: ParameterDeclaration {
    /// Documentation-level description of the parameter.
    public let descriptor: ParameterDescriptor

    private let fallback: Value?
    private let extract: @Sendable (CalculationValue) throws(ParameterRejection) -> Value

    /// Name of the parameter on the wire.
    public var name: String {
        descriptor.name
    }

    /// Creates a parameter.
    ///
    /// - Parameters:
    ///   - name: Name of the parameter on the wire.
    ///   - summary: What the parameter means.
    ///   - kind: Accepted shape and constraints, for documentation.
    ///   - fallback: The value used when the caller omits the parameter, with its documented representation. A
    ///     parameter without a fallback is required.
    ///   - extract: Validates a supplied value and converts it to `Value`.
    public init(
        name: String,
        summary: String,
        kind: ParameterKind,
        fallback: (value: Value, display: CalculationValue)? = nil,
        extract: @escaping @Sendable (CalculationValue) throws(ParameterRejection) -> Value
    ) {
        self.descriptor = ParameterDescriptor(
            name: name,
            summary: summary,
            kind: kind,
            requirement: fallback.map { .optional(defaultValue: $0.display) } ?? .required
        )
        self.fallback = fallback?.value
        self.extract = extract
    }

    /// Validates the raw input for this parameter.
    ///
    /// - Parameter raw: The value supplied by the caller, or `nil` when it was omitted. An explicit JSON `null` is
    ///   treated as omitted.
    /// - Returns: The typed value, or the fallback when the parameter was omitted.
    /// - Throws: ``ParameterRejection`` when the value is missing without a default, or violates a constraint.
    public func bind(_ raw: CalculationValue?) throws(ParameterRejection) -> any Sendable {
        guard let raw, raw != .null else {
            guard let fallback else {
                throw ParameterRejection(reason: ParameterMessage.required)
            }
            return fallback
        }

        return try extract(raw)
    }
}

/// Wording shared by the parameter factories.
enum ParameterMessage {
    static let required = "is required"
    static let notNumber = "must be a number"
    static let notWholeNumber = "must be a whole number"
    static let notFinite = "must be a finite number"
    static let notBoolean = "must be true or false"
    static let notText = "must be text"
    static let notList = "must be a list"
    static let notMatrix = "must be a list of equally long lists of numbers"
    static let notMap = "must be an object whose values are numbers"
    static let notDecimal = "must be a number or numeric text"

    static func tooLong(maximum: Int) -> String {
        "must be at most \(maximum) characters long"
    }

    static func unknownChoice(allowed: [String]) -> String {
        "must be one of: \(allowed.joined(separator: ", "))"
    }

    static func size(_ range: ClosedRange<Int>, noun: String) -> String {
        "must contain between \(range.lowerBound) and \(range.upperBound) \(noun)"
    }

    static func element(at index: Int, reason: String) -> String {
        "element \(index) \(reason)"
    }
}
