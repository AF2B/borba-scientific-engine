/// Which length a vector norm measures.
enum VectorNorm: String, CaseIterable, Sendable {
    /// The straight-line distance: the square root of the sum of squares.
    case euclidean

    /// The sum of the absolute values of the components.
    case manhattan

    /// The largest absolute value of any component.
    case maximum
}

/// Operations on vectors, which are plain lists of numbers.
enum Vectors {
    /// The number of dimensions the cross product is defined for.
    static let crossProductDimensions = 3

    /// Adds or subtracts vectors of equal length component by component.
    ///
    /// - Parameters:
    ///   - lhs: The first vector.
    ///   - rhs: The second vector.
    ///   - subtracting: Whether to subtract `rhs` instead of adding it.
    /// - Returns: The combined vector.
    /// - Throws: ``MatrixError/dimensionMismatch(left:right:)`` when the lengths differ.
    static func combine(
        _ lhs: [Double],
        _ rhs: [Double],
        subtracting: Bool
    ) throws(MatrixError) -> [Double] {
        try requireSameLength(lhs, rhs)
        return zip(lhs, rhs).map { subtracting ? $0 - $1 : $0 + $1 }
    }

    /// Multiplies every component by a number.
    ///
    /// - Parameters:
    ///   - vector: The vector to scale.
    ///   - factor: The number to multiply by.
    /// - Returns: The scaled vector.
    static func scaled(
        _ vector: [Double],
        by factor: Double
    ) -> [Double] {
        vector.map { $0 * factor }
    }

    /// The dot product, accumulated with compensation.
    ///
    /// - Parameters:
    ///   - lhs: The first vector.
    ///   - rhs: The second vector.
    /// - Returns: The sum of the products of matching components.
    /// - Throws: ``MatrixError/dimensionMismatch(left:right:)`` when the lengths differ.
    static func dot(
        _ lhs: [Double],
        _ rhs: [Double]
    ) throws(MatrixError) -> Double {
        try requireSameLength(lhs, rhs)
        return CompensatedSum.total(of: zip(lhs, rhs).map { $0 * $1 })
    }

    /// The cross product of two three-dimensional vectors: a vector perpendicular to both.
    ///
    /// - Parameters:
    ///   - lhs: The first vector.
    ///   - rhs: The second vector.
    /// - Returns: The perpendicular vector.
    /// - Throws: ``MatrixError/crossProductNeedsThreeDimensions(actual:)`` unless both vectors have three components.
    static func cross(
        _ lhs: [Double],
        _ rhs: [Double]
    ) throws(MatrixError) -> [Double] {
        guard lhs.count == crossProductDimensions else {
            throw .crossProductNeedsThreeDimensions(actual: lhs.count)
        }
        guard rhs.count == crossProductDimensions else {
            throw .crossProductNeedsThreeDimensions(actual: rhs.count)
        }
        return [
            lhs[1] * rhs[2] - lhs[2] * rhs[1],
            lhs[2] * rhs[0] - lhs[0] * rhs[2],
            lhs[0] * rhs[1] - lhs[1] * rhs[0],
        ]
    }

    /// The length of a vector.
    ///
    /// - Parameters:
    ///   - vector: The vector to measure.
    ///   - norm: Which length to compute.
    /// - Returns: The norm.
    static func length(
        of vector: [Double],
        norm: VectorNorm
    ) -> Double {
        switch norm {
        case .euclidean:
            // Scaling by the largest component keeps the squares from overflowing or vanishing.
            let largest = vector.reduce(0) { Swift.max($0, abs($1)) }
            guard largest > 0 else {
                return 0
            }
            return largest * CompensatedSum.total(of: vector.map { ($0 / largest) * ($0 / largest) }).squareRoot()
        case .manhattan:
            return CompensatedSum.total(of: vector.map(abs))
        case .maximum:
            return vector.reduce(0) { Swift.max($0, abs($1)) }
        }
    }

    /// The vector scaled to length one.
    ///
    /// - Parameter vector: The vector to normalize.
    /// - Returns: The unit vector pointing the same way.
    /// - Throws: ``MatrixError/zeroVector`` for the zero vector, which has no direction.
    static func normalized(_ vector: [Double]) throws(MatrixError) -> [Double] {
        let magnitude = length(of: vector, norm: .euclidean)
        guard magnitude > 0 else {
            throw .zeroVector
        }
        return vector.map { $0 / magnitude }
    }

    private static func requireSameLength(
        _ lhs: [Double],
        _ rhs: [Double]
    ) throws(MatrixError) {
        guard lhs.count == rhs.count else {
            throw .dimensionMismatch(left: "\(lhs.count)", right: "\(rhs.count)")
        }
    }
}
