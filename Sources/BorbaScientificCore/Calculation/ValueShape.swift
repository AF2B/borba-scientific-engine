/// One named field of an object-shaped result.
public struct FieldShape: Sendable, Equatable {
    /// Name of the field on the wire.
    public let name: String

    /// Shape of the field's value.
    public let shape: ValueShape

    /// What the field means.
    public let summary: String

    /// Creates a field description.
    ///
    /// - Parameters:
    ///   - name: Name of the field on the wire.
    ///   - shape: Shape of the field's value.
    ///   - summary: What the field means.
    public init(
        _ name: String,
        _ shape: ValueShape,
        _ summary: String
    ) {
        self.name = name
        self.shape = shape
        self.summary = summary
    }
}

/// The structure of a result value, declared by each operation for documentation and contract checks.
public indirect enum ValueShape: Sendable, Equatable {
    /// A finite number.
    case number

    /// Text.
    case text

    /// `true` or `false`.
    case boolean

    /// A list whose elements all share one shape.
    case list(of: ValueShape)

    /// An object with exactly the listed fields.
    case object([FieldShape])

    /// Whether a value has this shape.
    ///
    /// - Parameter value: The value to check.
    /// - Returns: `true` when the value is structurally compatible, including exactly the declared fields for objects.
    public func accepts(_ value: CalculationValue) -> Bool {
        switch (self, value) {
        case (.number, .number), (.text, .text), (.boolean, .boolean):
            true
        case (.list(let element), .list(let values)):
            values.allSatisfy(element.accepts)
        case (.object(let fields), .object(let values)):
            Set(fields.map(\.name)) == Set(values.keys)
                && fields.allSatisfy { values[$0.name].map($0.shape.accepts) ?? false }
        case (.number, _), (.text, _), (.boolean, _), (.list, _), (.object, _):
            false
        }
    }
}
