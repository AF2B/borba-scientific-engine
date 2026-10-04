import BorbaScientificCore
import PerformanceSupport
import TestSupport
import Testing

extension Benchmarks {
    /// How fast the calculation engine itself is, without HTTP, persistence or events.
    @Suite("Engine")
    struct EngineBenchmarks {
        private static let group = "engine"

        private struct ScaledCase {
            let name: String
            let type: CalculationType
            let parameters: [String: CalculationValue]
            let budget: Duration

            init(
                _ name: String,
                module: String,
                operation: String,
                parameters: [String: CalculationValue],
                budget: Duration
            ) {
                self.name = name
                type = CalculationType(module: ModuleName(module), operation: OperationName(operation))
                self.parameters = parameters
                self.budget = budget
            }
        }

        private static func makeEngine() -> CalculationEngine {
            CalculationEngine(registry: .standard(), clock: SystemClock(), timeout: .seconds(30))
        }

        private static func numbers(_ count: Int) -> [Double] {
            (0..<count).map { Double($0 % 97) * 1.5 + 1 }
        }

        /// A diagonally dominant matrix, which is never singular.
        private static func matrix(_ size: Int) -> [[Double]] {
            (0..<size).map { row in
                (0..<size).map { column in row == column ? Double(size) + 1 : 1 / Double(row + column + 1) }
            }
        }

        private static func measure(
            _ name: String,
            _ type: CalculationType,
            _ parameters: [String: CalculationValue],
            iterations: Int,
            engine: CalculationEngine
        ) async throws -> BenchmarkResult {
            let request = CalculationRequest(type: type, parameters: parameters)

            return try await Benchmark.run(
                name,
                group: group,
                warmup: BenchmarkScale.warmup(for: iterations),
                iterations: iterations
            ) { _ in
                let run = try await engine.execute(request)
                guard case .success = run.result else {
                    throw BenchmarkFailure(description: "\(name) did not succeed: \(run.result)")
                }
            }
        }

        @Test("profiles the first documented example of every operation")
        func everyOperation() async throws {
            let engine = Self.makeEngine()
            let iterations = BenchmarkScale.iterations(2_000)
            var results: [BenchmarkResult] = []

            for module in ModuleRegistry.standard().modules {
                for operation in module.operations {
                    guard let example = operation.examples.first else {
                        continue
                    }
                    let result = try await Self.measure(
                        operation.type.description,
                        operation.type,
                        example.parameters,
                        iterations: iterations,
                        engine: engine
                    )
                    expectWithinBudget(result, p99: .milliseconds(5))
                    results.append(result)
                }
            }

            try BenchmarkScale.publish(
                group: "engine-operations",
                results.sorted { $0.latency.p95 > $1.latency.p95 }.prefix(25).map { $0 }
            )
            #expect(results.count > 50, "every operation has an example, so every operation was measured")
        }

        @Test("shows how the heavier operations grow with the size of their input")
        func scaledInputs() async throws {
            let engine = Self.makeEngine()
            let iterations = BenchmarkScale.iterations(300)
            let big = Self.numbers(10_000)
            let cases = [
                ScaledCase(
                    "statistics.mean (10,000 values)",
                    module: "statistics",
                    operation: "mean",
                    parameters: ["values": .numbers(big)],
                    budget: .milliseconds(10)
                ),
                ScaledCase(
                    "statistics.linear_regression (10,000 points)",
                    module: "statistics",
                    operation: "linear_regression",
                    parameters: ["x": .numbers(big), "y": .numbers(big.reversed())],
                    budget: .milliseconds(25)
                ),
                ScaledCase(
                    "financial.amortization_schedule (360 months)",
                    module: "financial",
                    operation: "amortization_schedule",
                    parameters: ["principal": 250_000, "annual_rate": 6.5, "term_months": 360],
                    budget: .milliseconds(25)
                ),
                ScaledCase(
                    "numerical.integrate (100,000 intervals)",
                    module: "numerical",
                    operation: "integrate",
                    parameters: ["expression": "sin(x) * exp(-x)", "lower": 0, "upper": 10, "intervals": 100_000],
                    budget: .milliseconds(150)
                ),
                ScaledCase(
                    "linear_algebra.matrix_determinant (50×50)",
                    module: "linear_algebra",
                    operation: "matrix_determinant",
                    parameters: ["matrix": .matrix(Self.matrix(50))],
                    budget: .milliseconds(25)
                ),
                ScaledCase(
                    "linear_algebra.matrix_inverse (50×50)",
                    module: "linear_algebra",
                    operation: "matrix_inverse",
                    parameters: ["matrix": .matrix(Self.matrix(50))],
                    budget: .milliseconds(60)
                ),
                ScaledCase(
                    "linear_algebra.solve_linear_system (50×50)",
                    module: "linear_algebra",
                    operation: "solve_linear_system",
                    parameters: ["matrix": .matrix(Self.matrix(50)), "constants": .numbers(Self.numbers(50))],
                    budget: .milliseconds(30)
                ),
                ScaledCase(
                    "expression.evaluate (compiled once, cached)",
                    module: "expression",
                    operation: "evaluate",
                    parameters: ["expression": "sin(x)^2 + cos(x)^2 + sqrt(abs(x)) * 2", "variables": ["x": 0.75]],
                    budget: .milliseconds(5)
                ),
            ]

            var results: [BenchmarkResult] = []
            for scaled in cases {
                let result = try await Self.measure(
                    scaled.name,
                    scaled.type,
                    scaled.parameters,
                    iterations: iterations,
                    engine: engine
                )
                expectWithinBudget(result, p99: scaled.budget)
                results.append(result)
            }
            try BenchmarkScale.publish(group: "engine-scaled", results)
        }
    }
}
