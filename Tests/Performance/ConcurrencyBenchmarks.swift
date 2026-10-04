import BorbaScientificCore
import PerformanceSupport
import TestSupport
import Testing

extension Benchmarks {
    /// How throughput grows with the number of calculations in flight.
    @Suite("Concurrency")
    struct ConcurrencyBenchmarks {
        private static let levels = [1, 2, 4, 8, 16]

        private static func makeService() -> CalculationService {
            let clock = SystemClock()
            return CalculationService(
                engine: CalculationEngine(registry: .standard(), clock: clock, timeout: .seconds(30)),
                repository: InMemoryCalculationRepository(),
                events: NullEventPublisher(),
                clock: clock,
                identifiers: UUIDv7Generator(clock: clock)
            )
        }

        @Test("runs CPU-bound calculations in parallel, through the service, at increasing concurrency")
        func throughputScaling() async throws {
            let service = Self.makeService()
            let values = (0..<1_000).map { Double($0 % 97) + 1 }
            let command = ExecuteCalculation(
                request: CalculationRequest(
                    type: CalculationType(
                        module: ModuleName("statistics"),
                        operation: OperationName("standard_deviation")
                    ),
                    parameters: ["values": .numbers(values)]
                ),
                trace: TraceContext(requestID: RequestID("benchmark"), correlationID: CorrelationID("benchmark"))
            )
            let iterations = BenchmarkScale.iterations(4_000)

            var results: [BenchmarkResult] = []
            for level in Self.levels {
                results.append(
                    try await Benchmark.run(
                        "standard_deviation (1,000 values) × \(level)",
                        group: "concurrency",
                        warmup: BenchmarkScale.warmup(for: iterations),
                        iterations: iterations,
                        concurrency: level
                    ) { _ in
                        _ = try await service.execute(command)
                    }
                )
            }
            try BenchmarkScale.publish(group: "concurrency", results)

            let single = try #require(results.first).operationsPerSecond
            let widest = try #require(results.last).operationsPerSecond
            #expect(widest >= single * 0.8, "running 16 at once must not be slower than running one at a time")
        }

        @Test("keeps a batch's throughput close to the sum of its calculations")
        func batch() async throws {
            let service = Self.makeService()
            let trace = TraceContext(requestID: RequestID("benchmark"), correlationID: CorrelationID("benchmark"))
            let commands = (0..<1_000).map { index in
                ExecuteCalculation(
                    request: CalculationRequest(
                        type: CalculationType(module: ModuleName("arithmetic"), operation: OperationName("add")),
                        parameters: ["a": .number(Double(index)), "b": 1]
                    ),
                    trace: trace
                )
            }
            let batchesPerRun = BenchmarkScale.iterations(50)

            let result = try await Benchmark.run(
                "executeBatch (1,000 additions, concurrency 8)",
                group: "concurrency",
                warmup: 3,
                iterations: batchesPerRun
            ) { _ in
                let outcomes = await service.executeBatch(commands, maximumConcurrency: 8)
                guard outcomes.count == commands.count else {
                    throw BenchmarkFailure(description: "a batch lost calculations")
                }
            }

            try BenchmarkScale.publish(group: "concurrency-batch", [result])
            expectWithinBudget(result, p99: .milliseconds(250))
        }
    }
}
