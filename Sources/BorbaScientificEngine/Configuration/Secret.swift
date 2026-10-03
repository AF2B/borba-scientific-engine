/// A sensitive string that never appears in logs, error messages or string interpolation.
///
/// The wrapped value is only reachable through ``reveal()``, which makes every use of the plain text explicit
/// and easy to audit.
public struct Secret: Sendable, Equatable {
    private static let placeholder = "<redacted>"

    private let value: String

    /// Wraps a sensitive value.
    ///
    /// - Parameter value: The plain-text secret.
    public init(_ value: String) {
        self.value = value
    }

    /// Returns the plain-text secret. Callers must never log or persist the result.
    public func reveal() -> String {
        value
    }
}

extension Secret: CustomStringConvertible, CustomDebugStringConvertible {
    /// A fixed placeholder; the wrapped value is never rendered.
    public var description: String { Self.placeholder }

    /// A fixed placeholder; the wrapped value is never rendered.
    public var debugDescription: String { Self.placeholder }
}
