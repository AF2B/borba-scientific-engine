import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("Statistics")
struct StatisticsTests {
    private typealias P = StatisticsParameters

    private func sample(_ values: Double...) throws -> Sample {
        try Sample(values)
    }

    @Test("refuses an empty sample")
    func emptySample() {
        #expect(throws: StatisticsError.emptySample) {
            try Sample([])
        }
    }

    @Test("computes mean, extremes and range")
    func centreAndExtremes() throws {
        let sample = try sample(2, 4, 4, 4, 5, 5, 7, 9)

        #expect(sample.mean == 5)
        #expect(sample.minimum == 2)
        #expect(sample.maximum == 9)
        #expect(sample.range == 7)
        #expect(sample.count == 8)
        #expect(sample.sum == 40)
    }

    @Test("takes the middle observation, or the midpoint of the middle pair")
    func median() throws {
        #expect(try sample(3, 1, 2).median == 2)
        #expect(try sample(4, 1, 3, 2).median == 2.5)
        #expect(try sample(42).median == 42)
    }

    @Test("lists every most-frequent value in ascending order and none when all values are unique")
    func modes() throws {
        #expect(try sample(1, 2, 2, 3, 3, 3).modes == [3])
        #expect(try sample(2, 1, 2, 1, 3).modes == [1, 2])
        #expect(try sample(1, 2, 3).modes.isEmpty)
    }

    @Test("computes population and sample variance")
    func variance() throws {
        let sample = try sample(2, 4, 4, 4, 5, 5, 7, 9)

        #expect(try sample.variance(kind: .population) == 4)
        #expect(try sample.variance(kind: .sample) == 32.0 / 7.0)
        #expect(try sample.standardDeviation(kind: .population) == 2)
    }

    @Test("stays accurate when observations share a large offset")
    func numericalStability() throws {
        let offset = 1e9
        let sample = try sample(offset + 4, offset + 7, offset + 13, offset + 16)

        #expect(try sample.variance(kind: .population) == 22.5)
        #expect(try sample.variance(kind: .sample) == 30)
    }

    @Test("needs two observations for a sample variance")
    func sampleVarianceOfOneObservation() throws {
        let single = try sample(5)

        #expect(throws: StatisticsError.insufficientObservations(required: 2, actual: 1)) {
            try single.variance(kind: .sample)
        }
        #expect(try single.variance(kind: .population) == 0)
    }

    @Test(
        "interpolates percentiles between the nearest ranks",
        arguments: [(0.0, 15.0), (25.0, 20.0), (40.0, 29.0), (50.0, 35.0), (100.0, 50.0)]
    )
    func percentile(percent: Double, expected: Double) throws {
        let sample = try sample(50, 15, 40, 20, 35)

        #expect(sample.percentile(percent) == expected)
    }

    @Test("computes quartiles and the interquartile range")
    func quartiles() throws {
        let quartiles = try sample(1, 2, 3, 4, 5, 6, 7, 8, 9).quartiles

        #expect(quartiles == Quartiles(first: 3, median: 5, third: 7))
        #expect(quartiles.interquartileRange == 4)
    }

    @Test("computes covariance, correlation and regression of paired samples")
    func pairedStatistics() throws {
        let pair = try PairedSample(x: [1, 2, 3, 4, 5], y: [2, 4, 6, 8, 10])

        #expect(try pair.covariance(kind: .population) == 4)
        #expect(try pair.covariance(kind: .sample) == 5)
        #expect(try pair.correlation() == 1)
        #expect(try pair.linearRegression() == LinearRegression(slope: 2, intercept: 0, rSquared: 1))
    }

    @Test("fits a noisy line")
    func noisyRegression() throws {
        let pair = try PairedSample(x: [1, 2, 3, 4, 5], y: [2.2, 4.1, 5.9, 8.2, 9.9])

        let fit = try pair.linearRegression()

        #expect(abs(fit.slope - 1.95) < 1e-9)
        #expect(abs(fit.intercept - 0.21) < 1e-9)
        #expect(fit.rSquared > 0.99 && fit.rSquared < 1)
    }

    @Test("treats a constant dependent variable as a perfect horizontal fit")
    func constantDependentVariable() throws {
        let fit = try PairedSample(x: [1, 2, 3], y: [4, 4, 4]).linearRegression()

        #expect(fit == LinearRegression(slope: 0, intercept: 4, rSquared: 1))
    }

    @Test("is undefined when a variable does not vary")
    func zeroVariance() throws {
        let constantX = try PairedSample(x: [2, 2, 2], y: [1, 2, 3])
        let constantY = try PairedSample(x: [1, 2, 3], y: [2, 2, 2])

        #expect(throws: StatisticsError.zeroVariance) { try constantX.correlation() }
        #expect(throws: StatisticsError.zeroVariance) { try constantY.correlation() }
        #expect(throws: StatisticsError.zeroVariance) { try constantX.linearRegression() }
    }

    @Test("refuses paired samples of different sizes")
    func lengthMismatch() {
        #expect(throws: StatisticsError.lengthMismatch(first: 3, second: 2)) {
            try PairedSample(x: [1, 2, 3], y: [1, 2])
        }
    }

    @Test("maps statistics failures to stable error codes")
    func mapsFailures() {
        #expect(StatisticsError.emptySample.calculationError.code == .undefinedResult)
        #expect(StatisticsError.zeroVariance.calculationError.code == .undefinedResult)
        #expect(
            StatisticsError.insufficientObservations(required: 2, actual: 1).calculationError.code == .undefinedResult
        )
        #expect(StatisticsError.lengthMismatch(first: 1, second: 2).calculationError.code == .validationFailed)
    }

    @Test("names the offending parameter when paired lists differ in length")
    func lengthMismatchThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let result = try await engine.calculate(
            .statistics,
            StatisticsOperation.correlation,
            [P.x.name: [1, 2, 3], P.y.name: [1, 2]]
        )

        #expect(result.failure?.code == .validationFailed)
        #expect(result.failure?.details.first?.field == "y")
    }

    @Test("rejects a percentile outside 0 to 100 through the engine")
    func percentileBoundsThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let error = await #expect(throws: CalculationError.self) {
            try await engine.calculate(
                .statistics,
                StatisticsOperation.percentile,
                [P.values.name: [1, 2, 3], P.percentile.name: 101]
            )
        }

        #expect(error?.details == [ErrorDetail(field: "percentile", reason: "must be at most 100")])
    }

    @Test("rejects an empty list before computing anything")
    func emptyListThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let error = await #expect(throws: CalculationError.self) {
            try await engine.calculate(.statistics, StatisticsOperation.mean, [P.values.name: []])
        }

        #expect(error?.details == [ErrorDetail(field: "values", reason: "must contain between 1 and 100000 elements")])
    }
}
