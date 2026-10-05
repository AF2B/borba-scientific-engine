/// What a name looks like: a lowercase letter, then lowercase letters, digits and underscores, in at most
/// ``maximumLength`` characters. Every module and operation of the engine has such a name.
public enum NameSyntax {
    /// The longest name.
    public static let maximumLength = 64

    private static let underscore = UInt8(ascii: "_")
    private static let lowercaseLetters = UInt8(ascii: "a")...UInt8(ascii: "z")
    private static let digits = UInt8(ascii: "0")...UInt8(ascii: "9")

    /// Whether a text has the form of a name.
    ///
    /// - Parameter text: The text to check.
    /// - Returns: `true` when it is a name.
    public static func isValid(_ text: String) -> Bool {
        let bytes = text.utf8
        guard (1...maximumLength).contains(bytes.count), let first = bytes.first, lowercaseLetters.contains(first)
        else {
            return false
        }
        return bytes.allSatisfy { lowercaseLetters.contains($0) || digits.contains($0) || $0 == underscore }
    }
}

/// A case-sensitive identifier written in lowercase words separated by underscores, such as `compound_interest`.
///
/// The `Namespace` type parameter is a phantom: it keeps module names and operation names from being mixed up
/// at compile time without duplicating the wrapper.
public struct Name<Namespace>: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    /// The identifier exactly as it appears on the wire.
    public let rawValue: String

    /// Wraps a raw identifier.
    ///
    /// - Parameter rawValue: The identifier as it appears on the wire.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Wraps a raw identifier that someone else chose, only when it has the form of a name (see ``NameSyntax``); the
    /// initializer fails otherwise.
    ///
    /// - Parameter rawValue: The text to wrap.
    public init?(validating rawValue: String) {
        guard NameSyntax.isValid(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Decodes an identifier from a single JSON string.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A decoding error when the value is not a string.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the identifier as a single JSON string.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An encoding error raised by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Orders identifiers alphabetically so catalogs are listed deterministically.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The raw identifier.
    public var description: String {
        rawValue
    }
}

/// Phantom namespace of ``ModuleName``.
public enum ModuleNamespace {}

/// Phantom namespace of ``OperationName``.
public enum OperationNamespace {}

/// Identifies a calculation module, for example `statistics`.
public typealias ModuleName = Name<ModuleNamespace>

/// Identifies an operation inside a module, for example `mean`. Only unique within its module.
public typealias OperationName = Name<OperationNamespace>

/// Fully qualified identity of a calculation: the module and the operation it belongs to.
public struct CalculationType: Hashable, Sendable, Comparable, CustomStringConvertible {
    private static let separator = "."

    /// Module that owns the operation.
    public let module: ModuleName

    /// Operation inside the module.
    public let operation: OperationName

    /// Creates a calculation type.
    ///
    /// - Parameters:
    ///   - module: Module that owns the operation.
    ///   - operation: Operation inside the module.
    public init(
        module: ModuleName,
        operation: OperationName
    ) {
        self.module = module
        self.operation = operation
    }

    /// Orders by module, then by operation.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.module, lhs.operation) < (rhs.module, rhs.operation)
    }

    /// The qualified form used in logs, metrics and storage, such as `statistics.mean`.
    public var description: String {
        module.rawValue + Self.separator + operation.rawValue
    }
}
