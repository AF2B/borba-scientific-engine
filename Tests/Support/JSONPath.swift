public import BorbaScientificCore

/// One step of a path into a JSON document: an object key or an array index.
public enum JSONStep: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case key(String)
    case index(Int)

    /// Creates a step that names an object key.
    ///
    /// - Parameter value: The key.
    public init(stringLiteral value: String) {
        self = .key(value)
    }

    /// Creates a step that selects an array element.
    ///
    /// - Parameter value: The zero-based index.
    public init(integerLiteral value: Int) {
        self = .index(value)
    }
}

extension CalculationValue {
    /// Follows a path of keys and indexes into a JSON document.
    ///
    /// - Parameter steps: Object keys and array indexes, outermost first.
    /// - Returns: The value at the path, or `nil` when any step does not exist.
    public func at(_ steps: JSONStep...) -> CalculationValue? {
        var current: CalculationValue? = self

        for step in steps {
            switch step {
            case .key(let name):
                current = current?.fields?[name]
            case .index(let position):
                guard let elements = current?.elements, elements.indices.contains(position) else {
                    return nil
                }
                current = elements[position]
            }
        }
        return current
    }
}
