extension ErrorCode {
    /// The matrix has no inverse, so the requested inverse or solution does not exist.
    public static let singularMatrix = ErrorCode("SINGULAR_MATRIX")
}

/// Failures of the linear algebra module.
enum MatrixError: Error, Sendable, Equatable {
    /// The operands have shapes that do not fit the operation.
    case dimensionMismatch(left: String, right: String)

    /// The operation needs a square matrix.
    case notSquare(rows: Int, columns: Int)

    /// The matrix has no inverse.
    case singular

    /// The zero vector has no direction.
    case zeroVector

    /// The cross product exists only for three-dimensional vectors.
    case crossProductNeedsThreeDimensions(actual: Int)
}

extension MatrixError: CalculationFailure {
    /// Maps each failure to its stable, user-facing representation.
    var calculationError: CalculationError {
        switch self {
        case .dimensionMismatch(let left, let right):
            .undefined("The operands have incompatible dimensions: \(left) and \(right).")
        case .notSquare(let rows, let columns):
            .undefined("The operation needs a square matrix, but the matrix is \(rows) by \(columns).")
        case .singular:
            .domain(
                DomainFailure(
                    code: .singularMatrix,
                    message: "The matrix is singular: it has no inverse and the system has no unique solution."
                )
            )
        case .zeroVector:
            .undefined("The zero vector has no direction.")
        case .crossProductNeedsThreeDimensions(let actual):
            .undefined("The cross product needs three-dimensional vectors, but \(actual) dimensions were given.")
        }
    }
}

/// A rectangular matrix of finite numbers.
struct Matrix: Sendable, Equatable {
    /// Largest number of rows or columns the engine accepts. A product of two such matrices costs about a million
    /// multiplications, which stays far inside the time budget.
    static let maximumDimension = 100

    /// Entries whose magnitude is below this fraction of the largest entry count as zero when looking for pivots.
    static let singularityTolerance = 1e-12

    let rowCount: Int
    let columnCount: Int
    private var storage: [Double]

    /// Creates a matrix from its rows, or fails when the rows are empty or ragged.
    ///
    /// - Parameter rows: The rows; each must have the same, non-zero length.
    init?(rectangular rows: [[Double]]) {
        guard let width = rows.first?.count, width > 0, rows.allSatisfy({ $0.count == width }) else {
            return nil
        }
        self.init(rowCount: rows.count, columnCount: width, storage: rows.flatMap { $0 })
    }

    private init(
        rowCount: Int,
        columnCount: Int,
        storage: [Double]
    ) {
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.storage = storage
    }

    /// The identity matrix of a given size.
    ///
    /// - Parameter size: Number of rows and columns.
    /// - Returns: A matrix with ones on the diagonal and zeros elsewhere.
    static func identity(_ size: Int) -> Matrix {
        var matrix = Matrix(rowCount: size, columnCount: size, storage: Array(repeating: 0, count: size * size))
        for index in 0..<size {
            matrix[index, index] = 1
        }
        return matrix
    }

    /// The entry at a row and a column.
    subscript(row: Int, column: Int) -> Double {
        get { storage[row * columnCount + column] }
        set { storage[row * columnCount + column] = newValue }
    }

    /// The matrix as a list of rows.
    var rows: [[Double]] {
        (0..<rowCount).map { row in Array(storage[row * columnCount..<(row + 1) * columnCount]) }
    }

    /// A description of the shape such as `2x3`, for messages.
    var shape: String {
        "\(rowCount)x\(columnCount)"
    }

    /// Whether the matrix has as many rows as columns.
    var isSquare: Bool {
        rowCount == columnCount
    }

    /// The matrix with rows and columns exchanged.
    func transposed() -> Matrix {
        var result = Matrix(rowCount: columnCount, columnCount: rowCount, storage: storage)
        for row in 0..<rowCount {
            for column in 0..<columnCount {
                result[column, row] = self[row, column]
            }
        }
        return result
    }

    /// The entrywise sum of two matrices of the same shape.
    ///
    /// - Parameter other: The matrix to add.
    /// - Returns: The sum.
    /// - Throws: ``MatrixError/dimensionMismatch(left:right:)`` when the shapes differ.
    func adding(_ other: Matrix) throws(MatrixError) -> Matrix {
        guard rowCount == other.rowCount, columnCount == other.columnCount else {
            throw .dimensionMismatch(left: shape, right: other.shape)
        }
        return Matrix(rowCount: rowCount, columnCount: columnCount, storage: zip(storage, other.storage).map(+))
    }

    /// The matrix product.
    ///
    /// - Parameter other: The right factor; it must have as many rows as this matrix has columns.
    /// - Returns: The product, with this matrix's rows and the other's columns.
    /// - Throws: ``MatrixError/dimensionMismatch(left:right:)`` when the inner dimensions differ.
    func multiplied(by other: Matrix) throws(MatrixError) -> Matrix {
        guard columnCount == other.rowCount else {
            throw .dimensionMismatch(left: shape, right: other.shape)
        }

        var result = Matrix(
            rowCount: rowCount,
            columnCount: other.columnCount,
            storage: Array(repeating: 0, count: rowCount * other.columnCount)
        )
        for row in 0..<rowCount {
            for column in 0..<other.columnCount {
                var sum = CompensatedSum()
                for inner in 0..<columnCount {
                    sum.add(self[row, inner] * other[inner, column])
                }
                result[row, column] = sum.value
            }
        }
        return result
    }

    /// The largest absolute value of any entry, which sets the scale for deciding what counts as zero.
    var largestMagnitude: Double {
        storage.reduce(0) { Swift.max($0, abs($1)) }
    }
}

/// An LU factorization with partial pivoting, which solves the determinant, the inverse and linear systems.
struct LUFactorization: Sendable {
    private var factors: Matrix
    private var permutation: [Int]
    private var swaps = 0

    /// Whether a pivot vanished, meaning the matrix has no inverse.
    private(set) var isSingular = false

    /// Factors a square matrix.
    ///
    /// - Parameter matrix: The matrix to factor.
    /// - Throws: ``MatrixError/notSquare(rows:columns:)`` when the matrix is not square.
    init(_ matrix: Matrix) throws(MatrixError) {
        guard matrix.isSquare else {
            throw .notSquare(rows: matrix.rowCount, columns: matrix.columnCount)
        }

        factors = matrix
        permutation = Array(0..<matrix.rowCount)

        let threshold = Matrix.singularityTolerance * max(matrix.largestMagnitude, 1)
        let size = matrix.rowCount

        for column in 0..<size {
            let pivotRow = (column..<size).max { abs(factors[$0, column]) < abs(factors[$1, column]) } ?? column
            guard abs(factors[pivotRow, column]) > threshold else {
                isSingular = true
                return
            }

            if pivotRow != column {
                swapRows(pivotRow, column)
                swaps += 1
            }
            for row in (column + 1)..<size {
                let multiplier = factors[row, column] / factors[column, column]
                factors[row, column] = multiplier
                for inner in (column + 1)..<size {
                    factors[row, inner] -= multiplier * factors[column, inner]
                }
            }
        }
    }

    /// The determinant, which is zero for a singular matrix.
    var determinant: Double {
        guard !isSingular else {
            return 0
        }
        let sign = swaps.isMultiple(of: 2) ? 1.0 : -1.0
        return (0..<factors.rowCount).reduce(sign) { $0 * factors[$1, $1] }
    }

    /// Solves `A x = b` for `x`.
    ///
    /// - Parameter constants: The right-hand side `b`, with one entry per row.
    /// - Returns: The solution `x`.
    /// - Throws: ``MatrixError/singular`` when the matrix has no inverse and
    ///   ``MatrixError/dimensionMismatch(left:right:)`` when `b` has the wrong length.
    func solve(_ constants: [Double]) throws(MatrixError) -> [Double] {
        guard !isSingular else {
            throw .singular
        }
        let size = factors.rowCount
        guard constants.count == size else {
            throw .dimensionMismatch(left: factors.shape, right: "\(constants.count)")
        }

        var solution = permutation.map { constants[$0] }
        for row in 0..<size {
            for column in 0..<row {
                solution[row] -= factors[row, column] * solution[column]
            }
        }
        for row in stride(from: size - 1, through: 0, by: -1) {
            for column in (row + 1)..<size {
                solution[row] -= factors[row, column] * solution[column]
            }
            solution[row] /= factors[row, row]
        }
        return solution
    }

    /// The inverse matrix.
    ///
    /// - Returns: `A^-1`.
    /// - Throws: ``MatrixError/singular`` when the matrix has no inverse.
    func inverse() throws(MatrixError) -> Matrix {
        let size = factors.rowCount
        var result = Matrix.identity(size)

        for column in 0..<size {
            let unit = (0..<size).map { $0 == column ? 1.0 : 0.0 }
            let solved = try solve(unit)
            for row in 0..<size {
                result[row, column] = solved[row]
            }
        }
        return result
    }

    private mutating func swapRows(
        _ first: Int,
        _ second: Int
    ) {
        for column in 0..<factors.columnCount {
            let held = factors[first, column]
            factors[first, column] = factors[second, column]
            factors[second, column] = held
        }
        permutation.swapAt(first, second)
    }
}
