// Worked examples document an operation with concrete numbers; those literals are the data being documented.
// swiftlint:disable no_magic_numbers

extension ModuleName {
    /// Vectors and matrices.
    public static let linearAlgebra = ModuleName("linear_algebra")
}

/// Wire names of the linear algebra operations.
enum LinearAlgebraOperation: String, CaseIterable {
    case vectorAdd = "vector_add"
    case vectorSubtract = "vector_subtract"
    case vectorScale = "vector_scale"
    case vectorDot = "vector_dot"
    case vectorCross = "vector_cross"
    case vectorNorm = "vector_norm"
    case vectorNormalize = "vector_normalize"
    case matrixAdd = "matrix_add"
    case matrixMultiply = "matrix_multiply"
    case matrixTranspose = "matrix_transpose"
    case matrixDeterminant = "matrix_determinant"
    case matrixInverse = "matrix_inverse"
    case solveLinearSystem = "solve_linear_system"
}

/// Parameters of the linear algebra operations. Each name is spelled once, here.
enum LinearAlgebraParameters {
    private static let dimensions = 1...Matrix.maximumDimension

    static let firstVector = ParameterSpec.numberList("a", summary: "The first vector.")
    static let secondVector = ParameterSpec.numberList("b", summary: "The second vector.")
    static let vector = ParameterSpec.numberList("vector", summary: "The vector.")
    static let scalar = ParameterSpec.number("scalar", summary: "The number every component is multiplied by.")
    static let norm = ParameterSpec<VectorNorm>.choice(
        "norm",
        summary: "Which length to measure: euclidean, manhattan or maximum.",
        default: .euclidean
    )
    static let firstMatrix = ParameterSpec.numberMatrix(
        "a",
        summary: "The first matrix, given as a list of rows.",
        rows: dimensions,
        columns: dimensions
    )
    static let secondMatrix = ParameterSpec.numberMatrix(
        "b",
        summary: "The second matrix, given as a list of rows.",
        rows: dimensions,
        columns: dimensions
    )
    static let matrix = ParameterSpec.numberMatrix(
        "matrix",
        summary: "The matrix, given as a list of rows.",
        rows: dimensions,
        columns: dimensions
    )
    static let constants = ParameterSpec.numberList(
        "constants",
        summary: "The right-hand side of the system, one entry per row of the matrix.",
        size: dimensions
    )
}

/// Checks that depend on the shape of several parameters at once, reported against the parameter at fault.
enum LinearAlgebraShapes {
    static func matrix(
        _ rows: [[Double]],
        _ parameter: ParameterSpec<[[Double]]>
    ) throws(CalculationError) -> Matrix {
        guard let matrix = Matrix(rectangular: rows) else {
            throw .invalidParameter(parameter.name, reason: ParameterMessage.notMatrix)
        }
        return matrix
    }

    static func requireSameLength(
        _ first: [Double],
        _ second: [Double]
    ) throws(CalculationError) {
        guard first.count == second.count else {
            throw .invalidParameter(
                LinearAlgebraParameters.secondVector.name,
                reason: "must have as many components as '\(LinearAlgebraParameters.firstVector.name)' "
                    + "(\(first.count)), but has \(second.count)"
            )
        }
    }

    static func requireSameShape(
        _ first: Matrix,
        _ second: Matrix
    ) throws(CalculationError) {
        guard first.rowCount == second.rowCount, first.columnCount == second.columnCount else {
            throw .invalidParameter(
                LinearAlgebraParameters.secondMatrix.name,
                reason:
                    "must be \(first.shape) like '\(LinearAlgebraParameters.firstMatrix.name)', but is \(second.shape)"
            )
        }
    }

    static func requireConformable(
        _ first: Matrix,
        _ second: Matrix
    ) throws(CalculationError) {
        guard first.columnCount == second.rowCount else {
            throw .invalidParameter(
                LinearAlgebraParameters.secondMatrix.name,
                reason: "must have \(first.columnCount) rows to multiply a \(first.shape) matrix, "
                    + "but has \(second.rowCount)"
            )
        }
    }

    static func requireSquare(_ matrix: Matrix) throws(CalculationError) {
        guard matrix.isSquare else {
            throw .invalidParameter(
                LinearAlgebraParameters.matrix.name,
                reason: "must be square, but is \(matrix.shape)"
            )
        }
    }

    static func requireThreeDimensional(
        _ vector: [Double],
        _ parameter: ParameterSpec<[Double]>
    ) throws(CalculationError) {
        guard vector.count == Vectors.crossProductDimensions else {
            throw .invalidParameter(
                parameter.name,
                reason: "must have \(Vectors.crossProductDimensions) components for a cross product, "
                    + "but has \(vector.count)"
            )
        }
    }
}

/// Vector and matrix arithmetic: sums, products, norms, determinants, inverses and linear systems.
public struct LinearAlgebraModule: CalculationModule {
    /// Name of the module on the wire.
    public let name = ModuleName.linearAlgebra

    /// One-sentence description of what the module covers.
    public let summary = "Vector and matrix arithmetic: products, norms, determinants, inverses and linear systems."

    /// The operations the module offers, one per case of its operation enumeration.
    public let operations: [OperationDefinition]

    /// Creates the module.
    public init() {
        operations = LinearAlgebraOperation.allCases.map(Self.definition(for:))
    }

    private typealias P = LinearAlgebraParameters
    private typealias Shapes = LinearAlgebraShapes

    private static let vectorResult = ValueShape.list(of: .number)
    private static let matrixResult = ValueShape.list(of: .list(of: .number))

    /// Maps every operation to its definition. The switch is exhaustive, so adding an operation without a
    /// definition does not compile.
    private static func definition(for operation: LinearAlgebraOperation) -> OperationDefinition {
        switch operation {
        case .vectorAdd: vectorAdd
        case .vectorSubtract: vectorSubtract
        case .vectorScale: vectorScale
        case .vectorDot: vectorDot
        case .vectorCross: vectorCross
        case .vectorNorm: vectorNorm
        case .vectorNormalize: vectorNormalize
        case .matrixAdd: matrixAdd
        case .matrixMultiply: matrixMultiply
        case .matrixTranspose: matrixTranspose
        case .matrixDeterminant: matrixDeterminant
        case .matrixInverse: matrixInverse
        case .solveLinearSystem: solveLinearSystem
        }
    }

    private static let vectorAdd = OperationDefinition(
        name: LinearAlgebraOperation.vectorAdd,
        summary: "Adds two vectors of the same length component by component.",
        parameters: [P.firstVector, P.secondVector],
        result: vectorResult,
        examples: [
            OperationExample(
                "Adds two three-dimensional vectors.",
                with: [(P.firstVector, [1, 2, 3]), (P.secondVector, [4, 5, 6])],
                yields: [5, 7, 9]
            )
        ],
        compute: { arguments in
            let first = try arguments[P.firstVector]
            let second = try arguments[P.secondVector]
            try Shapes.requireSameLength(first, second)
            return .numbers(try Vectors.combine(first, second, subtracting: false))
        }
    )

    private static let vectorSubtract = OperationDefinition(
        name: LinearAlgebraOperation.vectorSubtract,
        summary: "Subtracts the second vector from the first, component by component.",
        parameters: [P.firstVector, P.secondVector],
        result: vectorResult,
        examples: [
            OperationExample(
                "Subtracts two three-dimensional vectors.",
                with: [(P.firstVector, [4, 5, 6]), (P.secondVector, [1, 2, 3])],
                yields: [3, 3, 3]
            )
        ],
        compute: { arguments in
            let first = try arguments[P.firstVector]
            let second = try arguments[P.secondVector]
            try Shapes.requireSameLength(first, second)
            return .numbers(try Vectors.combine(first, second, subtracting: true))
        }
    )

    private static let vectorScale = OperationDefinition(
        name: LinearAlgebraOperation.vectorScale,
        summary: "Multiplies every component of a vector by a number.",
        parameters: [P.vector, P.scalar],
        result: vectorResult,
        examples: [
            OperationExample("Doubles a vector.", with: [(P.vector, [1, 2, 3]), (P.scalar, 2)], yields: [2, 4, 6])
        ],
        compute: { arguments in
            .numbers(Vectors.scaled(try arguments[P.vector], by: try arguments[P.scalar]))
        }
    )

    private static let vectorDot = OperationDefinition(
        name: LinearAlgebraOperation.vectorDot,
        summary: "Computes the dot product of two vectors of the same length.",
        parameters: [P.firstVector, P.secondVector],
        result: .number,
        examples: [
            OperationExample(
                "The dot product of two three-dimensional vectors.",
                with: [(P.firstVector, [1, 2, 3]), (P.secondVector, [4, 5, 6])],
                yields: 32
            )
        ],
        compute: { arguments in
            let first = try arguments[P.firstVector]
            let second = try arguments[P.secondVector]
            try Shapes.requireSameLength(first, second)
            return .number(try Vectors.dot(first, second))
        }
    )

    private static let vectorCross = OperationDefinition(
        name: LinearAlgebraOperation.vectorCross,
        summary: "Computes the cross product of two three-dimensional vectors.",
        parameters: [P.firstVector, P.secondVector],
        result: vectorResult,
        examples: [
            OperationExample(
                "The x axis crossed with the y axis gives the z axis.",
                with: [(P.firstVector, [1, 0, 0]), (P.secondVector, [0, 1, 0])],
                yields: [0, 0, 1]
            )
        ],
        compute: { arguments in
            let first = try arguments[P.firstVector]
            let second = try arguments[P.secondVector]
            try Shapes.requireThreeDimensional(first, P.firstVector)
            try Shapes.requireThreeDimensional(second, P.secondVector)
            return .numbers(try Vectors.cross(first, second))
        }
    )

    private static let vectorNorm = OperationDefinition(
        name: LinearAlgebraOperation.vectorNorm,
        summary: "Measures the length of a vector.",
        parameters: [P.vector, P.norm],
        result: .number,
        examples: [
            OperationExample("The 3-4-5 triangle.", with: [(P.vector, [3, 4])], yields: 5),
            OperationExample(
                "The sum of absolute values.",
                with: [(P.vector, [3, -4]), (P.norm, "manhattan")],
                yields: 7
            ),
            OperationExample(
                "The largest absolute value.",
                with: [(P.vector, [3, -4]), (P.norm, "maximum")],
                yields: 4
            ),
        ],
        compute: { arguments in
            .number(Vectors.length(of: try arguments[P.vector], norm: try arguments[P.norm]))
        }
    )

    private static let vectorNormalize = OperationDefinition(
        name: LinearAlgebraOperation.vectorNormalize,
        summary: "Scales a vector to length one; the zero vector has no direction.",
        parameters: [P.vector],
        result: vectorResult,
        examples: [
            OperationExample("Normalizes the 3-4-5 triangle.", with: [(P.vector, [3, 4])], yields: [0.6, 0.8])
        ],
        compute: { arguments in
            .numbers(try Vectors.normalized(try arguments[P.vector]))
        }
    )

    private static let matrixAdd = OperationDefinition(
        name: LinearAlgebraOperation.matrixAdd,
        summary: "Adds two matrices of the same shape entry by entry.",
        parameters: [P.firstMatrix, P.secondMatrix],
        result: matrixResult,
        examples: [
            OperationExample(
                "Adds two 2x2 matrices.",
                with: [(P.firstMatrix, [[1, 2], [3, 4]]), (P.secondMatrix, [[5, 6], [7, 8]])],
                yields: [[6, 8], [10, 12]]
            )
        ],
        compute: { arguments in
            let first = try Shapes.matrix(arguments[P.firstMatrix], P.firstMatrix)
            let second = try Shapes.matrix(arguments[P.secondMatrix], P.secondMatrix)
            try Shapes.requireSameShape(first, second)
            return .matrix(try first.adding(second).rows)
        }
    )

    private static let matrixMultiply = OperationDefinition(
        name: LinearAlgebraOperation.matrixMultiply,
        summary: "Multiplies two matrices; the first must have as many columns as the second has rows.",
        parameters: [P.firstMatrix, P.secondMatrix],
        result: matrixResult,
        examples: [
            OperationExample(
                "Multiplies two 2x2 matrices.",
                with: [(P.firstMatrix, [[1, 2], [3, 4]]), (P.secondMatrix, [[5, 6], [7, 8]])],
                yields: [[19, 22], [43, 50]]
            )
        ],
        compute: { arguments in
            let first = try Shapes.matrix(arguments[P.firstMatrix], P.firstMatrix)
            let second = try Shapes.matrix(arguments[P.secondMatrix], P.secondMatrix)
            try Shapes.requireConformable(first, second)
            return .matrix(try first.multiplied(by: second).rows)
        }
    )

    private static let matrixTranspose = OperationDefinition(
        name: LinearAlgebraOperation.matrixTranspose,
        summary: "Exchanges the rows and columns of a matrix.",
        parameters: [P.matrix],
        result: matrixResult,
        examples: [
            OperationExample(
                "Transposes a 2x3 matrix.",
                with: [(P.matrix, [[1, 2, 3], [4, 5, 6]])],
                yields: [[1, 4], [2, 5], [3, 6]]
            )
        ],
        compute: { arguments in
            .matrix(try Shapes.matrix(arguments[P.matrix], P.matrix).transposed().rows)
        }
    )

    private static let matrixDeterminant = OperationDefinition(
        name: LinearAlgebraOperation.matrixDeterminant,
        summary: "Computes the determinant of a square matrix; it is zero when the matrix has no inverse.",
        parameters: [P.matrix],
        result: .number,
        examples: [OperationExample("A 2x2 determinant.", with: [(P.matrix, [[1, 2], [3, 4]])], yields: -2)],
        compute: { arguments in
            let matrix = try Shapes.matrix(arguments[P.matrix], P.matrix)
            try Shapes.requireSquare(matrix)
            return .number(try LUFactorization(matrix).determinant)
        }
    )

    private static let matrixInverse = OperationDefinition(
        name: LinearAlgebraOperation.matrixInverse,
        summary: "Computes the inverse of a square matrix; a singular matrix has none.",
        parameters: [P.matrix],
        result: matrixResult,
        examples: [
            OperationExample(
                "The inverse of a 2x2 matrix.",
                with: [(P.matrix, [[4, 7], [2, 6]])],
                yields: [[0.6, -0.7], [-0.2, 0.4]]
            )
        ],
        compute: { arguments in
            let matrix = try Shapes.matrix(arguments[P.matrix], P.matrix)
            try Shapes.requireSquare(matrix)
            return .matrix(try LUFactorization(matrix).inverse().rows)
        }
    )

    private static let solveLinearSystem = OperationDefinition(
        name: LinearAlgebraOperation.solveLinearSystem,
        summary: "Solves the system A x = b for x; the matrix must be square and not singular.",
        parameters: [P.matrix, P.constants],
        result: vectorResult,
        examples: [
            OperationExample(
                "Two equations in two unknowns.",
                with: [(P.matrix, [[2, 1], [1, 3]]), (P.constants, [3, 5])],
                yields: [0.8, 1.4]
            )
        ],
        compute: { arguments in
            let matrix = try Shapes.matrix(arguments[P.matrix], P.matrix)
            let constants = try arguments[P.constants]
            try Shapes.requireSquare(matrix)
            guard constants.count == matrix.rowCount else {
                throw CalculationError.invalidParameter(
                    P.constants.name,
                    reason: "must have one entry per row of '\(P.matrix.name)' (\(matrix.rowCount)), "
                        + "but has \(constants.count)"
                )
            }
            return .numbers(try LUFactorization(matrix).solve(constants))
        }
    )
}

// swiftlint:enable no_magic_numbers
