import Foundation

/// Reads typed values from an environment dictionary while accumulating every problem it meets.
///
/// Reading never throws: each accessor records an issue and returns a placeholder so the loader can keep going
/// and report all problems at once through ``finish()``.
struct EnvironmentReader {
    private let values: [String: String]
    private var issues: [ConfigurationIssue] = []

    /// Creates a reader over the given variables.
    ///
    /// - Parameter values: Environment variables, typically `ProcessInfo.processInfo.environment`.
    init(values: [String: String]) {
        self.values = values
    }

    /// Returns the trimmed value, or `nil` when the variable is unset or blank.
    ///
    /// - Parameter variable: Variable to read.
    /// - Returns: The trimmed value, or `nil` when it is unset or blank.
    func optionalString(_ variable: EnvironmentVariable) -> String? {
        guard let raw = values[variable.rawValue] else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns the trimmed value and records an issue when it is missing.
    ///
    /// - Parameter variable: Variable to read.
    /// - Returns: The trimmed value, or `nil` after recording an issue.
    mutating func requiredString(_ variable: EnvironmentVariable) -> String? {
        guard let value = optionalString(variable) else {
            report(variable, reason: "is required but not set")
            return nil
        }

        return value
    }

    /// Reads an integer constrained to a range.
    ///
    /// - Parameters:
    ///   - variable: Variable to read.
    ///   - fallback: Value used when the variable is unset or invalid.
    ///   - range: Inclusive bounds of the accepted values.
    /// - Returns: The parsed integer, or `fallback` after recording an issue for an invalid value.
    mutating func integer(
        _ variable: EnvironmentVariable,
        default fallback: Int,
        within range: ClosedRange<Int>
    ) -> Int {
        guard let raw = optionalString(variable) else {
            return fallback
        }

        guard let parsed = Int(raw), range.contains(parsed) else {
            report(variable, reason: "must be an integer between \(range.lowerBound) and \(range.upperBound)")
            return fallback
        }

        return parsed
    }

    /// Reads a floating-point number constrained to a range.
    ///
    /// - Parameters:
    ///   - variable: Variable to read.
    ///   - fallback: Value used when the variable is unset or invalid.
    ///   - range: Inclusive bounds of the accepted values.
    /// - Returns: The parsed number, or `fallback` after recording an issue for an invalid value.
    mutating func decimal(
        _ variable: EnvironmentVariable,
        default fallback: Double,
        within range: ClosedRange<Double>
    ) -> Double {
        guard let raw = optionalString(variable) else {
            return fallback
        }

        guard let parsed = Double(raw), range.contains(parsed) else {
            report(variable, reason: "must be a number between \(range.lowerBound) and \(range.upperBound)")
            return fallback
        }

        return parsed
    }

    /// Reads a value from a closed set of lowercase names.
    ///
    /// - Parameters:
    ///   - variable: Variable to read.
    ///   - fallback: Value used when the variable is unset or invalid.
    /// - Returns: The matching case, or `fallback` after recording an issue for an unknown name.
    mutating func choice<Value: RawRepresentable & CaseIterable>(
        _ variable: EnvironmentVariable,
        default fallback: Value
    ) -> Value where Value.RawValue == String {
        guard let raw = optionalString(variable) else {
            return fallback
        }

        guard let parsed = Value(rawValue: raw.lowercased()) else {
            let allowed = Value.allCases.map(\.rawValue).joined(separator: ", ")
            report(variable, reason: "must be one of: \(allowed)")
            return fallback
        }

        return parsed
    }

    /// Records a problem with a variable.
    ///
    /// - Parameters:
    ///   - variable: Offending variable.
    ///   - reason: Explanation that must not echo the variable value.
    mutating func report(
        _ variable: EnvironmentVariable,
        reason: String
    ) {
        issues.append(ConfigurationIssue(variable: variable.rawValue, reason: reason))
    }

    /// Ends the read.
    ///
    /// - Throws: ``ConfigurationError/invalid(_:)`` listing every recorded issue.
    func finish() throws(ConfigurationError) {
        guard issues.isEmpty else {
            throw .invalid(issues)
        }
    }
}
