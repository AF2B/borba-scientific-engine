public import Foundation

/// Limits applied to every list-like parameter unless an operation narrows them further.
public enum ParameterLimits {
    /// Largest accepted list, matrix row count or map size.
    public static let maximumCollectionSize = 100_000

    /// Longest accepted free text.
    public static let maximumTextLength = 1_000
}

// MARK: - Reading raw values

/// Conversions from raw input to Swift values, shared by the parameter factories.
enum ParameterReading {
    static func number(from raw: CalculationValue) throws(ParameterRejection) -> Double {
        guard case .number(let value) = raw else {
            throw ParameterRejection(reason: ParameterMessage.notNumber)
        }
        guard value.isFinite else {
            throw ParameterRejection(reason: ParameterMessage.notFinite)
        }
        return value
    }

    static func integer(from raw: CalculationValue) throws(ParameterRejection) -> Int {
        let value = try number(from: raw)
        guard value.rounded() == value, let integer = Int(exactly: value) else {
            throw ParameterRejection(reason: ParameterMessage.notWholeNumber)
        }
        return integer
    }

    static func decimal(from raw: CalculationValue) throws(ParameterRejection) -> Decimal {
        switch raw {
        case .number(let value):
            guard value.isFinite, let decimal = Decimal(string: String(value), locale: nil) else {
                throw ParameterRejection(reason: ParameterMessage.notFinite)
            }
            return decimal
        case .text(let text):
            guard let decimal = Decimal(string: text, locale: nil) else {
                throw ParameterRejection(reason: ParameterMessage.notDecimal)
            }
            return decimal
        case .null, .boolean, .list, .object:
            throw ParameterRejection(reason: ParameterMessage.notDecimal)
        }
    }

    static func elements(
        of raw: CalculationValue,
        size: ClosedRange<Int>
    ) throws(ParameterRejection) -> [CalculationValue] {
        guard case .list(let elements) = raw else {
            throw ParameterRejection(reason: ParameterMessage.notList)
        }
        guard size.contains(elements.count) else {
            throw ParameterRejection(reason: ParameterMessage.size(size, noun: "elements"))
        }
        return elements
    }

    static func numberMap(
        from raw: CalculationValue,
        size: ClosedRange<Int>
    ) throws(ParameterRejection) -> [String: Double] {
        guard case .object(let entries) = raw else {
            throw ParameterRejection(reason: ParameterMessage.notMap)
        }
        guard size.contains(entries.count) else {
            throw ParameterRejection(reason: ParameterMessage.size(size, noun: "entries"))
        }

        var result: [String: Double] = [:]
        for (key, entry) in entries {
            do {
                result[key] = try number(from: entry)
            } catch {
                throw ParameterRejection(reason: "entry '\(key)' \(error.reason)")
            }
        }
        return result
    }

    static func list<Element>(
        from raw: CalculationValue,
        size: ClosedRange<Int>,
        element read: (CalculationValue) throws(ParameterRejection) -> Element
    ) throws(ParameterRejection) -> [Element] {
        var result: [Element] = []
        for (index, item) in try elements(of: raw, size: size).enumerated() {
            do {
                result.append(try read(item))
            } catch {
                throw ParameterRejection(reason: ParameterMessage.element(at: index, reason: error.reason))
            }
        }
        return result
    }
}

// MARK: - Scalars

extension ParameterSpec where Value == Double {
    /// Declares a finite number.
    ///
    /// - Parameters:
    ///   - name: Name of the parameter on the wire.
    ///   - summary: What the parameter means.
    ///   - bounds: Accepted interval.
    ///   - fallback: Value used when the caller omits the parameter; the parameter is required when `nil`.
    /// - Returns: The parameter declaration.
    public static func number(
        _ name: String,
        summary: String,
        bounds: NumberBounds = .unbounded,
        default fallback: Double? = nil
    ) -> ParameterSpec<Double> {
        ParameterSpec(
            name: name,
            summary: summary,
            kind: .number(bounds),
            fallback: fallback.map { ($0, .number($0)) },
            extract: { (raw) throws(ParameterRejection) in
                try bounds.validated(ParameterReading.number(from: raw))
            }
        )
    }
}

extension ParameterSpec where Value == Int {
    /// Declares a whole number.
    ///
    /// - Parameters:
    ///   - name: Name of the parameter on the wire.
    ///   - summary: What the parameter means.
    ///   - range: Accepted inclusive range.
    ///   - fallback: Value used when the caller omits the parameter; the parameter is required when `nil`.
    /// - Returns: The parameter declaration.
    public static func integer(
        _ name: String,
        summary: String,
        range: ClosedRange<Int>,
        default fallback: Int? = nil
    ) -> ParameterSpec<Int> {
        ParameterSpec(
            name: name,
            summary: summary,
            kind: .integer(range),
            fallback: fallback.map { ($0, .number(Double($0))) },
            extract: { (raw) throws(ParameterRejection) in
                let value = try ParameterReading.integer(from: raw)
                guard range.contains(value) else {
                    throw ParameterRejection(
                        reason: "must be between \(range.lowerBound) and \(range.upperBound)"
                    )
                }
                return value
            }
        )
    }
}

extension ParameterSpec where Value == Decimal {
    /// Declares a decimal amount, accepted as a JSON number or as numeric text such as `"1234.56"`.
    ///
    /// Text is the way to pass amounts that must not pass through binary floating point.
    ///
    /// - Parameters:
    ///   - name: Name of the parameter on the wire.
    ///   - summary: What the parameter means.
    ///   - bounds: Accepted interval.
    ///   - fallback: Value used when the caller omits the parameter; the parameter is required when `nil`.
    /// - Returns: The parameter declaration.
    public static func decimal(
        _ name: String,
        summary: String,
        bounds: NumberBounds = .unbounded,
        default fallback: Decimal? = nil
    ) -> ParameterSpec<Decimal> {
        ParameterSpec(
            name: name,
            summary: summary,
            kind: .decimal(bounds),
            fallback: fallback.map { ($0, .number($0.nearestDouble)) },
            extract: { (raw) throws(ParameterRejection) in
                let value = try ParameterReading.decimal(from: raw)
                _ = try bounds.validated(value.nearestDouble)
                return value
            }
        )
    }
}

extension ParameterSpec where Value == Bool {
    /// Declares a boolean flag.
    ///
    /// - Parameters:
    ///   - name: Name of the parameter on the wire.
    ///   - summary: What the parameter means.
    ///   - fallback: Value used when the caller omits the parameter; the parameter is required when `nil`.
    /// - Returns: The parameter declaration.
    public static func boolean(
        _ name: String,
        summary: String,
        default fallback: Bool? = nil
    ) -> ParameterSpec<Bool> {
        ParameterSpec(
            name: name,
            summary: summary,
            kind: .boolean,
            fallback: fallback.map { ($0, .boolean($0)) },
            extract: { (raw) throws(ParameterRejection) in
                guard case .boolean(let value) = raw else {
                    throw ParameterRejection(reason: ParameterMessage.notBoolean)
                }
                return value
            }
        )
    }
}

extension ParameterSpec where Value == String {
    /// Declares free text.
    ///
    /// - Parameters:
    ///   - name: Name of the parameter on the wire.
    ///   - summary: What the parameter means.
    ///   - maximumLength: Longest accepted text, in characters.
    ///   - fallback: Value used when the caller omits the parameter; the parameter is required when `nil`.
    /// - Returns: The parameter declaration.
    public static func text(
        _ name: String,
        summary: String,
        maximumLength: Int = ParameterLimits.maximumTextLength,
        default fallback: String? = nil
    ) -> ParameterSpec<String> {
        ParameterSpec(
            name: name,
            summary: summary,
            kind: .text(maximumLength: maximumLength),
            fallback: fallback.map { ($0, .text($0)) },
            extract: { (raw) throws(ParameterRejection) in
                guard case .text(let value) = raw else {
                    throw ParameterRejection(reason: ParameterMessage.notText)
                }
                guard value.count <= maximumLength else {
                    throw ParameterRejection(reason: ParameterMessage.tooLong(maximum: maximumLength))
                }
                return value
            }
        )
    }
}

extension ParameterSpec where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
    /// Declares a choice among the cases of a string-backed enumeration.
    ///
    /// - Parameters:
    ///   - name: Name of the parameter on the wire.
    ///   - summary: What the parameter means.
    ///   - fallback: Case used when the caller omits the parameter; the parameter is required when `nil`.
    /// - Returns: The parameter declaration.
    public static func choice(
        _ name: String,
        summary: String,
        default fallback: Value? = nil
    ) -> ParameterSpec<Value> {
        let allowed = Value.allCases.map(\.rawValue)

        return ParameterSpec(
            name: name,
            summary: summary,
            kind: .choice(allowed),
            fallback: fallback.map { ($0, .text($0.rawValue)) },
            extract: { (raw) throws(ParameterRejection) in
                guard case .text(let text) = raw, let value = Value(rawValue: text) else {
                    throw ParameterRejection(reason: ParameterMessage.unknownChoice(allowed: allowed))
                }
                return value
            }
        )
    }
}

// MARK: - Collections

extension ParameterSpec where Value == [Double] {
    /// Declares a list of finite numbers.
    ///
    /// - Parameters:
    ///   - name: Name of the parameter on the wire.
    ///   - summary: What the parameter means.
    ///   - size: Accepted number of elements.
    ///   - elements: Interval every element must lie in.
    ///   - fallback: Value used when the caller omits the parameter; the parameter is required when `nil`.
    /// - Returns: The parameter declaration.
    public static func numberList(
        _ name: String,
        summary: String,
        size: ClosedRange<Int> = 1...ParameterLimits.maximumCollectionSize,
        elements: NumberBounds = .unbounded,
        default fallback: [Double]? = nil
    ) -> ParameterSpec<[Double]> {
        ParameterSpec(
            name: name,
            summary: summary,
            kind: .numberList(size: size, elements: elements),
            fallback: fallback.map { ($0, .numbers($0)) },
            extract: { (raw) throws(ParameterRejection) in
                try ParameterReading.list(from: raw, size: size) { (item) throws(ParameterRejection) in
                    try elements.validated(ParameterReading.number(from: item))
                }
            }
        )
    }
}

extension ParameterSpec where Value == [Decimal] {
    /// Declares a list of decimal amounts, each a JSON number or numeric text.
    ///
    /// - Parameters:
    ///   - name: Name of the parameter on the wire.
    ///   - summary: What the parameter means.
    ///   - size: Accepted number of elements.
    /// - Returns: The parameter declaration.
    public static func decimalList(
        _ name: String,
        summary: String,
        size: ClosedRange<Int> = 1...ParameterLimits.maximumCollectionSize
    ) -> ParameterSpec<[Decimal]> {
        ParameterSpec(
            name: name,
            summary: summary,
            kind: .decimalList(size: size),
            extract: { (raw) throws(ParameterRejection) in
                try ParameterReading.list(from: raw, size: size) { (item) throws(ParameterRejection) in
                    try ParameterReading.decimal(from: item)
                }
            }
        )
    }
}

extension ParameterSpec where Value == [[Double]] {
    /// Declares a rectangular matrix of finite numbers, given as a list of rows.
    ///
    /// - Parameters:
    ///   - name: Name of the parameter on the wire.
    ///   - summary: What the parameter means.
    ///   - rows: Accepted number of rows.
    ///   - columns: Accepted number of columns.
    /// - Returns: The parameter declaration.
    public static func numberMatrix(
        _ name: String,
        summary: String,
        rows: ClosedRange<Int>,
        columns: ClosedRange<Int>
    ) -> ParameterSpec<[[Double]]> {
        ParameterSpec(
            name: name,
            summary: summary,
            kind: .numberMatrix(rows: rows, columns: columns),
            extract: { (raw) throws(ParameterRejection) in
                let matrix = try ParameterReading.list(from: raw, size: rows) { (row) throws(ParameterRejection) in
                    try ParameterReading.list(from: row, size: columns) { (item) throws(ParameterRejection) in
                        try ParameterReading.number(from: item)
                    }
                }
                guard Set(matrix.map(\.count)).count == 1 else {
                    throw ParameterRejection(reason: ParameterMessage.notMatrix)
                }
                return matrix
            }
        )
    }
}

extension ParameterSpec where Value == [String: Double] {
    /// Declares a map from names to finite numbers, such as the variables of an expression.
    ///
    /// - Parameters:
    ///   - name: Name of the parameter on the wire.
    ///   - summary: What the parameter means.
    ///   - size: Accepted number of entries.
    ///   - fallback: Value used when the caller omits the parameter; the parameter is required when `nil`.
    /// - Returns: The parameter declaration.
    public static func numberMap(
        _ name: String,
        summary: String,
        size: ClosedRange<Int>,
        default fallback: [String: Double]? = nil
    ) -> ParameterSpec<[String: Double]> {
        ParameterSpec(
            name: name,
            summary: summary,
            kind: .numberMap(size: size),
            fallback: fallback.map { ($0, .object($0.mapValues(CalculationValue.number))) },
            extract: { (raw) throws(ParameterRejection) in
                try ParameterReading.numberMap(from: raw, size: size)
            }
        )
    }
}
