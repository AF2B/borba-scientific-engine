import BorbaScientificCore

/// One end of a numeric constraint.
struct BoundResource: Encodable, Sendable, Equatable {
    /// The limit.
    let value: Double

    /// Whether the limit itself is accepted.
    let inclusive: Bool

    /// Creates a bound.
    ///
    /// - Parameters:
    ///   - value: The limit.
    ///   - inclusive: Whether the limit itself is accepted.
    init(
        value: Double,
        inclusive: Bool
    ) {
        self.value = value
        self.inclusive = inclusive
    }

    /// Presents a limit of a number bound.
    ///
    /// - Parameter limit: The limit to present.
    init(_ limit: NumberBounds.Limit) {
        self.init(value: limit.value, inclusive: limit.isInclusive)
    }
}

/// A range of whole numbers, such as the allowed length of a list.
struct SizeRangeResource: Encodable, Sendable, Equatable {
    /// Smallest accepted size.
    let min: Int

    /// Largest accepted size.
    let max: Int

    init(_ range: ClosedRange<Int>) {
        min = range.lowerBound
        max = range.upperBound
    }
}

/// What a parameter accepts, in wire terms.
///
/// `minimum` and `maximum` bound the value itself, or each element for list parameters. Constraints that do not apply
/// to a parameter's type are omitted.
struct ParameterConstraintsResource: Encodable, Sendable, Equatable {
    var minimum: BoundResource?
    var maximum: BoundResource?
    var items: SizeRangeResource?
    var rows: SizeRangeResource?
    var columns: SizeRangeResource?
    var maxLength: Int?
    var choices: [String]?

    enum CodingKeys: String, CodingKey {
        case minimum
        case maximum
        case items
        case rows
        case columns
        case maxLength = "max_length"
        case choices
    }

    /// Whether the parameter has no constraint worth listing.
    var isEmpty: Bool {
        self == ParameterConstraintsResource()
    }

    init(
        minimum: BoundResource? = nil,
        maximum: BoundResource? = nil,
        items: SizeRangeResource? = nil,
        rows: SizeRangeResource? = nil,
        columns: SizeRangeResource? = nil,
        maxLength: Int? = nil,
        choices: [String]? = nil
    ) {
        self.minimum = minimum
        self.maximum = maximum
        self.items = items
        self.rows = rows
        self.columns = columns
        self.maxLength = maxLength
        self.choices = choices
    }

    init(bounds: NumberBounds) {
        self.init(minimum: bounds.lower.map(BoundResource.init), maximum: bounds.upper.map(BoundResource.init))
    }
}

/// The JSON type a parameter is written as.
enum ParameterTypeName: String, Encodable, Sendable {
    case number
    case integer
    case decimal
    case boolean
    case text
    case choice
    case numberList = "number_list"
    case decimalList = "decimal_list"
    case numberMatrix = "number_matrix"
    case numberMap = "number_map"
}

/// One parameter of an operation, as the metadata endpoint describes it.
struct ParameterResource: Encodable, Sendable, Equatable {
    /// Name of the parameter on the wire.
    let name: String

    /// What the parameter means.
    let summary: String

    /// How the value is written.
    let type: ParameterTypeName

    /// Whether the caller must supply the parameter.
    let required: Bool

    /// The value used when an optional parameter is omitted.
    let defaultValue: CalculationValue?

    /// What the parameter accepts; omitted when it accepts anything of its type.
    let constraints: ParameterConstraintsResource?

    enum CodingKeys: String, CodingKey {
        case name
        case summary
        case type
        case required
        case defaultValue = "default"
        case constraints
    }

    /// Presents a parameter.
    ///
    /// - Parameter descriptor: The parameter's descriptor.
    init(_ descriptor: ParameterDescriptor) {
        name = descriptor.name
        summary = descriptor.summary

        let (type, constraints) = Self.describe(descriptor.kind)
        self.type = type
        self.constraints = constraints.isEmpty ? nil : constraints

        switch descriptor.requirement {
        case .required:
            required = true
            defaultValue = nil
        case .optional(let value):
            required = false
            defaultValue = value
        }
    }

    private static func describe(_ kind: ParameterKind) -> (ParameterTypeName, ParameterConstraintsResource) {
        switch kind {
        case .number(let bounds):
            (.number, ParameterConstraintsResource(bounds: bounds))
        case .decimal(let bounds):
            (.decimal, ParameterConstraintsResource(bounds: bounds))
        case .integer(let range):
            (
                .integer,
                ParameterConstraintsResource(
                    minimum: BoundResource(value: Double(range.lowerBound), inclusive: true),
                    maximum: BoundResource(value: Double(range.upperBound), inclusive: true)
                )
            )
        case .boolean:
            (.boolean, ParameterConstraintsResource())
        case .text(let maximumLength):
            (.text, ParameterConstraintsResource(maxLength: maximumLength))
        case .choice(let choices):
            (.choice, ParameterConstraintsResource(choices: choices))
        case .numberList(let size, let elements):
            (
                .numberList,
                ParameterConstraintsResource(
                    minimum: elements.lower.map(BoundResource.init),
                    maximum: elements.upper.map(BoundResource.init),
                    items: SizeRangeResource(size)
                )
            )
        case .decimalList(let size):
            (.decimalList, ParameterConstraintsResource(items: SizeRangeResource(size)))
        case .numberMatrix(let rows, let columns):
            (
                .numberMatrix,
                ParameterConstraintsResource(rows: SizeRangeResource(rows), columns: SizeRangeResource(columns))
            )
        case .numberMap(let size):
            (.numberMap, ParameterConstraintsResource(items: SizeRangeResource(size)))
        }
    }
}

/// The structure of a result value, in wire terms.
///
/// Written as `{"type": "number"}`, `{"type": "list", "items": {…}}` or
/// `{"type": "object", "fields": [{"name": …, "summary": …, "shape": {…}}]}`.
indirect enum ShapeResource: Encodable, Sendable, Equatable {
    /// One named field of an object.
    struct Field: Encodable, Sendable, Equatable {
        let name: String
        let summary: String
        let shape: ShapeResource
    }

    case number
    case text
    case boolean
    case list(items: ShapeResource)
    case object(fields: [Field])

    private enum CodingKeys: String, CodingKey {
        case type
        case items
        case fields
    }

    private enum TypeName: String {
        case number
        case text
        case boolean
        case list
        case object
    }

    /// Presents a result shape.
    ///
    /// - Parameter shape: The shape to present.
    init(_ shape: ValueShape) {
        switch shape {
        case .number:
            self = .number
        case .text:
            self = .text
        case .boolean:
            self = .boolean
        case .list(let element):
            self = .list(items: ShapeResource(element))
        case .object(let fields):
            self = .object(
                fields: fields.map { Field(name: $0.name, summary: $0.summary, shape: ShapeResource($0.shape)) }
            )
        }
    }

    /// Writes the shape as JSON.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An encoding error raised by the encoder.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .number:
            try container.encode(TypeName.number.rawValue, forKey: .type)
        case .text:
            try container.encode(TypeName.text.rawValue, forKey: .type)
        case .boolean:
            try container.encode(TypeName.boolean.rawValue, forKey: .type)
        case .list(let items):
            try container.encode(TypeName.list.rawValue, forKey: .type)
            try container.encode(items, forKey: .items)
        case .object(let fields):
            try container.encode(TypeName.object.rawValue, forKey: .type)
            try container.encode(fields, forKey: .fields)
        }
    }
}

/// A worked example of an operation.
struct ExampleResource: Encodable, Sendable, Equatable {
    /// What the example demonstrates.
    let summary: String

    /// The parameters of the example request.
    let parameters: [String: CalculationValue]

    /// The result the example request produces.
    let result: CalculationValue

    init(_ example: OperationExample) {
        summary = example.summary
        parameters = example.parameters
        result = example.result
    }
}

/// Everything a client needs to call one operation: the response of `GET /api/v1/types/{module}/{operation}`.
struct OperationMetadataResource: Encodable, Sendable, Equatable {
    /// The qualified name, such as `statistics.mean`.
    let type: String

    /// Name of the module.
    let module: String

    /// Name of the operation inside the module.
    let operation: String

    /// One-sentence description of what the operation computes.
    let summary: String

    /// The parameters the operation accepts, in documentation order.
    let parameters: [ParameterResource]

    /// Structure of the result.
    let result: ShapeResource

    /// Worked examples, executed by the engine's own tests so they cannot drift from the implementation.
    let examples: [ExampleResource]

    /// Presents an operation.
    ///
    /// - Parameter descriptor: The operation's descriptor.
    init(_ descriptor: OperationDescriptor) {
        type = descriptor.type.description
        module = descriptor.type.module.rawValue
        operation = descriptor.type.operation.rawValue
        summary = descriptor.summary
        parameters = descriptor.parameters.map(ParameterResource.init)
        result = ShapeResource(descriptor.result)
        examples = descriptor.examples.map(ExampleResource.init)
    }
}
