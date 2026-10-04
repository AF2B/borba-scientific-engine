import BorbaScientificCore
import Synchronization
import TestSupport
import Testing

@testable import BorbaScientificEngine

/// A probe whose answer and speed the test controls.
private final class StubProbe: ReadinessProbe, Sendable {
    let name: String

    private let calls = Mutex(0)
    private let answer: Mutex<ReadinessCheckResult.State>
    private let gate: Gate?

    init(
        name: String = "database",
        state: ReadinessCheckResult.State = .up,
        gate: Gate? = nil
    ) {
        self.name = name
        self.answer = Mutex(state)
        self.gate = gate
    }

    var callCount: Int {
        calls.withLock { $0 }
    }

    func set(_ state: ReadinessCheckResult.State) {
        answer.withLock { $0 = state }
    }

    func check() async -> ReadinessCheckResult {
        calls.withLock { $0 += 1 }
        await gate?.wait()
        let state = answer.withLock { $0 }
        return ReadinessCheckResult(name: name, state: state, detail: state == .down ? "unreachable" : nil)
    }

    func waitUntilCalled(times count: Int) async {
        while callCount < count {
            await Task.yield()
        }
    }
}

@Suite("ReadinessService", .timeLimit(.minutes(1)))
struct ReadinessServiceTests {
    private static let timeToLive = Duration.seconds(1)
    private static let probeTimeout = Duration.seconds(2)

    private func service(
        _ probes: [any ReadinessProbe],
        shutdown: ShutdownState = ShutdownState(),
        clock: ManualClock = ManualClock()
    ) -> ReadinessService {
        ReadinessService(
            probes: probes,
            shutdown: shutdown,
            timeToLive: Self.timeToLive,
            probeTimeout: Self.probeTimeout,
            clock: clock
        )
    }

    @Test("is ready when every probe is up, and lists them in order")
    func ready() async {
        let report = await service([StubProbe(name: "database"), StubProbe(name: "cache")]).report()

        #expect(report.isReady)
        #expect(report.checks.map(\.name) == ["database", "cache"])
    }

    @Test("is not ready when any probe is down")
    func notReady() async {
        let report = await service([StubProbe(name: "database"), StubProbe(name: "cache", state: .down)]).report()

        #expect(!report.isReady)
        #expect(report.checks.map(\.state) == [.up, .down])
    }

    @Test("has nothing to wait for when there are no probes")
    func noProbes() async {
        #expect(await service([]).report().isReady)
    }

    @Test("reuses an answer until it is older than its lifetime, then asks again")
    func cachesBriefly() async {
        let probe = StubProbe()
        let clock = ManualClock()
        let readiness = service([probe], clock: clock)

        _ = await readiness.report()
        clock.advance(by: .milliseconds(500))
        _ = await readiness.report()
        #expect(probe.callCount == 1, "still fresh")

        probe.set(.down)
        clock.advance(by: .milliseconds(600))
        let refreshed = await readiness.report()

        #expect(probe.callCount == 2)
        #expect(!refreshed.isReady, "the new answer replaces the old one")
    }

    @Test("lets concurrent callers share one check")
    func coalescesConcurrentChecks() async {
        let gate = Gate()
        let probe = StubProbe(gate: gate)
        let readiness = service([probe])

        async let first = readiness.report()
        async let second = readiness.report()
        async let third = readiness.report()
        await probe.waitUntilCalled(times: 1)
        await gate.open()
        let reports = await [first, second, third]

        #expect(probe.callCount == 1)
        #expect(Set(reports.map(\.isReady)) == [true])
    }

    @Test("reports a probe that does not answer in time as down")
    func boundsProbes() async {
        let gate = Gate()
        let stuck = StubProbe(gate: gate)
        let clock = ManualClock()
        let readiness = service([stuck], clock: clock)

        async let report = readiness.report()
        await clock.waitUntilSleeping()
        clock.advance(by: Self.probeTimeout)
        let result = await report

        #expect(!result.isReady)
        #expect(result.checks.first?.detail == "timed out")
        await gate.open()
    }

    @Test("answers not ready at once, without probing, when the process is shutting down")
    func shutdownWins() async {
        let probe = StubProbe()
        let shutdown = ShutdownState()
        let readiness = service([probe], shutdown: shutdown)

        #expect(await readiness.report().isReady)
        shutdown.begin()
        let report = await readiness.report()

        #expect(!report.isReady, "a cached 'ready' must not outlive the start of shutdown")
        #expect(report.checks.first?.detail == ReadinessReport.shuttingDownDetail)
        #expect(probe.callCount == 1)
    }
}

@Suite("ShutdownState")
struct ShutdownStateTests {
    @Test("starts running and cannot be undone")
    func irreversible() {
        let state = ShutdownState()
        #expect(!state.isShuttingDown)

        state.begin()
        state.begin()

        #expect(state.isShuttingDown)
    }
}

@Suite("Race", .timeLimit(.minutes(1)))
struct RaceTests {
    @Test("returns the result of the first contender to finish")
    func firstWins() async {
        let gate = Gate()

        let winner = await Race.firstToFinish(
            {
                await gate.wait()
                return "slow"
            },
            { "fast" }
        )

        #expect(winner == "fast")
        await gate.open()
    }

    @Test("does not wait for a loser that ignores cancellation")
    func doesNotWaitForTheLoser() async {
        let gate = Gate()

        let winner = await Race.firstToFinish(
            { "quick" },
            {
                await gate.wait()
                return "stuck"
            }
        )

        #expect(winner == "quick", "returned while the other contender is still blocked")
        await gate.open()
    }

    @Test("cancels the loser")
    func cancelsTheLoser() async {
        let clock = ManualClock()

        let winner = await Race.firstToFinish(
            {
                try? await clock.sleep(for: .seconds(60))
                return "slept"
            },
            { "done" }
        )

        #expect(winner == "done")
        while clock.sleeperCount > 0 {
            await Task.yield()
        }
    }
}
