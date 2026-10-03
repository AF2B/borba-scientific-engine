import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("Linear algebra")
struct LinearAlgebraTests {
    private typealias P = LinearAlgebraParameters

    private func matrix(_ rows: [[Double]]) throws -> Matrix {
        try #require(Matrix(rectangular: rows), "invalid matrix")
    }

    private func isClose(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double = 1e-9
    ) -> Bool {
        abs(lhs - rhs) <= tolerance * max(1, abs(rhs))
    }

    private func isClose(
        _ lhs: Matrix,
        _ rhs: Matrix,
        tolerance: Double = 1e-9
    ) -> Bool {
        lhs.rowCount == rhs.rowCount && lhs.columnCount == rhs.columnCount
            && zip(lhs.rows.joined(), rhs.rows.joined()).allSatisfy { isClose($0, $1, tolerance: tolerance) }
    }

    /// A reproducible matrix with entries in -5...5, made well conditioned by a dominant diagonal.
    private func randomMatrix(
        size: Int,
        seed: UInt64
    ) throws -> Matrix {
        var random = SeededRandom(seed: seed)
        let rows = (0..<size).map { row in
            (0..<size).map { column in
                Double.random(in: -5...5, using: &random) + (row == column ? 12 : 0)
            }
        }
        return try matrix(rows)
    }

    // MARK: - Vectors

    @Test("adds, subtracts and scales vectors")
    func vectorArithmetic() throws {
        #expect(try Vectors.combine([1, 2, 3], [4, 5, 6], subtracting: false) == [5, 7, 9])
        #expect(try Vectors.combine([4, 5, 6], [1, 2, 3], subtracting: true) == [3, 3, 3])
        #expect(Vectors.scaled([1, -2, 3], by: -2) == [-2, 4, -6])
    }

    @Test("computes dot products and detects mismatched lengths")
    func dotProduct() throws {
        #expect(try Vectors.dot([1, 2, 3], [4, 5, 6]) == 32)
        #expect(throws: MatrixError.dimensionMismatch(left: "2", right: "3")) {
            try Vectors.dot([1, 2], [1, 2, 3])
        }
    }

    @Test("the cross product is perpendicular to both operands and anticommutative")
    func crossProduct() throws {
        let first: [Double] = [2, -1, 3]
        let second: [Double] = [4, 0, -2]

        let product = try Vectors.cross(first, second)
        let reversed = try Vectors.cross(second, first)

        #expect(try Vectors.dot(product, first) == 0)
        #expect(try Vectors.dot(product, second) == 0)
        #expect(product == Vectors.scaled(reversed, by: -1))
        #expect(try Vectors.cross([1, 0, 0], [0, 1, 0]) == [0, 0, 1])
    }

    @Test("the cross product needs three dimensions")
    func crossProductDimensions() {
        #expect(throws: MatrixError.crossProductNeedsThreeDimensions(actual: 2)) {
            try Vectors.cross([1, 2], [3, 4, 5])
        }
    }

    @Test(
        "measures vector lengths",
        arguments: [
            ([3.0, 4.0], VectorNorm.euclidean, 5.0), ([3.0, -4.0], .manhattan, 7.0), ([3.0, -4.0], .maximum, 4.0),
            ([0.0, 0.0], .euclidean, 0.0), ([-2.0], .euclidean, 2.0),
        ]
    )
    func norms(
        vector: [Double],
        norm: VectorNorm,
        expected: Double
    ) {
        #expect(isClose(Vectors.length(of: vector, norm: norm), expected))
    }

    @Test("the Euclidean norm does not overflow or underflow on extreme components")
    func normRobustness() {
        #expect(isClose(Vectors.length(of: [3e200, 4e200], norm: .euclidean), 5e200))
        #expect(isClose(Vectors.length(of: [3e-200, 4e-200], norm: .euclidean), 5e-200))
    }

    @Test("normalizes to unit length and refuses the zero vector")
    func normalization() throws {
        let unit = try Vectors.normalized([3, 4])

        #expect(isClose(unit[0], 0.6) && isClose(unit[1], 0.8))
        #expect(isClose(Vectors.length(of: unit, norm: .euclidean), 1))
        #expect(throws: MatrixError.zeroVector) { try Vectors.normalized([0, 0, 0]) }
    }

    // MARK: - Matrices

    @Test("rejects ragged and empty matrices")
    func rectangularity() {
        #expect(Matrix(rectangular: [[1, 2], [3]]) == nil)
        #expect(Matrix(rectangular: []) == nil)
        #expect(Matrix(rectangular: [[]]) == nil)
    }

    @Test("transposing twice restores the matrix and the product transposes in reverse order")
    func transposition() throws {
        let first = try matrix([[1, 2, 3], [4, 5, 6]])
        let second = try matrix([[7, 8], [9, 10], [11, 12]])

        #expect(first.transposed().transposed() == first)
        #expect(
            try first.multiplied(by: second).transposed() == second.transposed().multiplied(by: first.transposed())
        )
        #expect(first.transposed().shape == "3x2")
    }

    @Test("multiplies matrices and honours the identity")
    func multiplication() throws {
        let first = try matrix([[1, 2], [3, 4]])
        let second = try matrix([[5, 6], [7, 8]])

        #expect(try first.multiplied(by: second).rows == [[19, 22], [43, 50]])
        #expect(try first.multiplied(by: .identity(2)) == first)
        #expect(try Matrix.identity(2).multiplied(by: first) == first)
    }

    @Test("multiplication is associative")
    func associativity() throws {
        let first = try randomMatrix(size: 4, seed: 1)
        let second = try randomMatrix(size: 4, seed: 2)
        let third = try randomMatrix(size: 4, seed: 3)

        let left = try first.multiplied(by: second).multiplied(by: third)
        let right = try first.multiplied(by: second.multiplied(by: third))

        #expect(isClose(left, right, tolerance: 1e-9))
    }

    @Test("detects incompatible shapes")
    func shapeMismatches() throws {
        let wide = try matrix([[1, 2, 3]])
        let tall = try matrix([[1], [2]])

        #expect(throws: MatrixError.dimensionMismatch(left: "1x3", right: "2x1")) { try wide.multiplied(by: tall) }
        #expect(throws: MatrixError.dimensionMismatch(left: "1x3", right: "2x1")) { try wide.adding(tall) }
    }

    @Test("computes determinants")
    func determinants() throws {
        #expect(isClose(try LUFactorization(matrix([[1, 2], [3, 4]])).determinant, -2))
        #expect(isClose(try LUFactorization(matrix([[6, 1, 1], [4, -2, 5], [2, 8, 7]])).determinant, -306))
        #expect(isClose(try LUFactorization(.identity(5)).determinant, 1))
        #expect(isClose(try LUFactorization(matrix([[5]])).determinant, 5))
    }

    @Test("the determinant of a product is the product of the determinants")
    func determinantMultiplicativity() throws {
        let first = try randomMatrix(size: 5, seed: 11)
        let second = try randomMatrix(size: 5, seed: 12)

        let product = try LUFactorization(first.multiplied(by: second)).determinant
        let separate = try LUFactorization(first).determinant * LUFactorization(second).determinant

        #expect(isClose(product, separate, tolerance: 1e-9))
    }

    @Test("a singular matrix has determinant zero and no inverse")
    func singularMatrices() throws {
        let singular = try matrix([[1, 2], [2, 4]])
        let factorization = try LUFactorization(singular)

        #expect(factorization.isSingular)
        #expect(factorization.determinant == 0)
        #expect(throws: MatrixError.singular) { try factorization.inverse() }
        #expect(throws: MatrixError.singular) { try factorization.solve([1, 1]) }
        #expect(throws: MatrixError.notSquare(rows: 1, columns: 2)) { try LUFactorization(matrix([[1, 2]])) }
    }

    @Test("a matrix times its inverse is the identity", arguments: [1, 2, 3, 5, 8])
    func inverses(size: Int) throws {
        let matrix = try randomMatrix(size: size, seed: UInt64(size))

        let inverse = try LUFactorization(matrix).inverse()

        #expect(isClose(try matrix.multiplied(by: inverse), .identity(size), tolerance: 1e-9))
        #expect(isClose(try inverse.multiplied(by: matrix), .identity(size), tolerance: 1e-9))
    }

    @Test("solves linear systems exactly where a solution is known")
    func solving() throws {
        let solution = try LUFactorization(matrix([[2, 1], [1, 3]])).solve([3, 5])

        #expect(isClose(solution[0], 0.8) && isClose(solution[1], 1.4))
    }

    @Test("a solution satisfies the system it solves", arguments: [2, 4, 7])
    func solutionResidual(size: Int) throws {
        let system = try randomMatrix(size: size, seed: UInt64(100 + size))
        var random = SeededRandom(seed: UInt64(size))
        let constants = (0..<size).map { _ in Double.random(in: -10...10, using: &random) }

        let solution = try LUFactorization(system).solve(constants)
        let reproduced = try system.multiplied(by: matrix(solution.map { [$0] })).rows.map { $0[0] }

        for (actual, expected) in zip(reproduced, constants) {
            #expect(isClose(actual, expected, tolerance: 1e-9))
        }
    }

    @Test("pivoting handles a zero on the diagonal")
    func pivoting() throws {
        let solution = try LUFactorization(matrix([[0, 1], [1, 0]])).solve([2, 3])

        #expect(solution == [3, 2])
    }

    // MARK: - Through the engine

    @Test("names the offending parameter when shapes do not fit")
    func shapeErrorsThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let addition = try await engine.calculate(
            .linearAlgebra,
            LinearAlgebraOperation.matrixAdd,
            [P.firstMatrix.name: [[1, 2]], P.secondMatrix.name: [[1], [2]]]
        )
        let product = try await engine.calculate(
            .linearAlgebra,
            LinearAlgebraOperation.matrixMultiply,
            [P.firstMatrix.name: [[1, 2]], P.secondMatrix.name: [[1, 2]]]
        )
        let dot = try await engine.calculate(
            .linearAlgebra,
            LinearAlgebraOperation.vectorDot,
            [P.firstVector.name: [1, 2], P.secondVector.name: [1, 2, 3]]
        )
        let cross = try await engine.calculate(
            .linearAlgebra,
            LinearAlgebraOperation.vectorCross,
            [P.firstVector.name: [1, 2, 3], P.secondVector.name: [1, 2]]
        )
        let determinant = try await engine.calculate(
            .linearAlgebra,
            LinearAlgebraOperation.matrixDeterminant,
            [P.matrix.name: [[1, 2, 3]]]
        )
        let system = try await engine.calculate(
            .linearAlgebra,
            LinearAlgebraOperation.solveLinearSystem,
            [P.matrix.name: [[1, 0], [0, 1]], P.constants.name: [1, 2, 3]]
        )

        #expect(addition.failure?.details.first?.field == "b")
        #expect(product.failure?.details.first?.field == "b")
        #expect(dot.failure?.details.first?.field == "b")
        #expect(cross.failure?.details.first?.field == "b")
        #expect(determinant.failure?.details.first?.field == "matrix")
        #expect(system.failure?.details.first?.field == "constants")
    }

    @Test("reports a singular matrix with its own stable code")
    func singularThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let inverse = try await engine.calculate(
            .linearAlgebra,
            LinearAlgebraOperation.matrixInverse,
            [P.matrix.name: [[1, 2], [2, 4]]]
        )

        #expect(inverse.failure?.code == ErrorCode("SINGULAR_MATRIX"))
        #expect(inverse.failure?.classification == .expectedDomain)
    }

    @Test("rejects ragged matrices and matrices beyond the supported size")
    func matrixValidationThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()
        let tooLarge = Array(repeating: [1.0], count: Matrix.maximumDimension + 1)

        let ragged = await #expect(throws: CalculationError.self) {
            try await engine.calculate(
                .linearAlgebra,
                LinearAlgebraOperation.matrixTranspose,
                [P.matrix.name: [[1, 2], [3]]]
            )
        }
        let large = await #expect(throws: CalculationError.self) {
            try await engine.calculate(
                .linearAlgebra,
                LinearAlgebraOperation.matrixTranspose,
                [P.matrix.name: .matrix(tooLarge)]
            )
        }

        #expect(ragged?.details.first?.field == "matrix")
        #expect(large?.details.first?.reason == "must contain between 1 and 100 elements")
    }

    @Test("maps matrix failures to stable error codes")
    func mapsFailures() {
        #expect(MatrixError.singular.calculationError.code == ErrorCode("SINGULAR_MATRIX"))
        #expect(MatrixError.zeroVector.calculationError.code == .undefinedResult)
        #expect(MatrixError.notSquare(rows: 1, columns: 2).calculationError.code == .undefinedResult)
        #expect(MatrixError.dimensionMismatch(left: "1", right: "2").calculationError.code == .undefinedResult)
        #expect(MatrixError.crossProductNeedsThreeDimensions(actual: 2).calculationError.code == .undefinedResult)
    }
}
