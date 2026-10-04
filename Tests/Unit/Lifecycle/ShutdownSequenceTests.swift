import BorbaScientificCore
import InMemoryLogging
import Logging
import TestSupport
import Testing

@testable import BorbaScientificEngine

@Suite("InFlightRequests", .timeLimit(.minutes(1)))
struct InFlightRequestsTests {
    @Test("counts the requests that began and have not ended")
    func counts() {
        let requests = InFlightRequests()

        requests.begin()
        requests.begin()
        requests.end()

        #expect(requests.active == 1)
    }

    @Test("has nothing to wait for when no request is running")
    func idleReturnsAtOnce() async {
        await InFlightRequests().waitUntilIdle()
    }

    @Test("wakes every waiter when the last request ends, and not before")
    func wakesWaitersTogether() async {
        let requests = InFlightRequests()
        requests.begin()
        requests.begin()

        let waiters = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<3 {
                    group.addTask { await requests.waitUntilIdle() }
                }
                await group.waitForAll()
            }
        }

        requests.end()
        #expect(requests.active == 1, "one request is still running, so nobody is released")
        requests.end()
        await waiters.value

        #expect(requests.active == 0)
    }
}

@Suite("ShutdownSequence", .timeLimit(.minutes(1)))
struct ShutdownSequenceTests {
    private static let requestDrainTimeout = Duration.seconds(15)
    private static let eventDrainTimeout = Duration.seconds(5)
    private static let errorReportDrainTimeout = Duration.seconds(2)

    private struct Fixture {
        let sequence: ShutdownSequence
        let state: ShutdownState
        let inFlight: InFlightRequests
        let clock: ManualClock
        let logs: InMemoryLogHandler
    }

    private func fixture(events: EventDispatcher? = nil) -> Fixture {
        let state = ShutdownState()
        let inFlight = InFlightRequests()
        let clock = ManualClock()
        let logs = InMemoryLogHandler()
        let logger = Logger(label: "test") { _ in
            var handler = logs
            handler.logLevel = .trace
            return handler
        }
        return Fixture(
            sequence: ShutdownSequence(
                state: state,
                inFlight: inFlight,
                events: events,
                errorReporter: DisabledErrorReporter(),
                requestDrainTimeout: Self.requestDrainTimeout,
                eventDrainTimeout: Self.eventDrainTimeout,
                errorReportDrainTimeout: Self.errorReportDrainTimeout,
                clock: clock,
                logger: logger
            ),
            state: state,
            inFlight: inFlight,
            clock: clock,
            logs: logs
        )
    }

    @Test("stops reporting ready at once, then waits for the requests in flight")
    func waitsForRequests() async {
        let fixture = fixture()
        fixture.inFlight.begin()

        let shutdown = Task { await fixture.sequence.run() }
        while !fixture.state.isShuttingDown {
            await Task.yield()
        }
        #expect(fixture.inFlight.active == 1, "the request is still running while readiness already says not ready")

        fixture.inFlight.end()
        await shutdown.value

        #expect(fixture.logs.entries.filter { $0.level == .warning }.isEmpty)
    }

    @Test("gives up at the deadline and says how many requests were left")
    func givesUpAtTheDeadline() async {
        let fixture = fixture()
        fixture.inFlight.begin()
        fixture.inFlight.begin()

        let shutdown = Task { await fixture.sequence.run() }
        await fixture.clock.waitUntilSleeping()
        fixture.clock.advance(by: Self.requestDrainTimeout)
        await shutdown.value

        let warning = fixture.logs.entries.first { $0.level == .warning }
        #expect(warning?.metadata["in_flight"] == "2")
    }

    @Test("lets the event subscribers deliver what is queued before it returns")
    func drainsEventsAfterRequests() async {
        let gate = Gate()
        let subscriber = RecordingSubscriber(name: "audit", gate: gate)
        let dispatcher = EventDispatcher(subscribers: [subscriber], bufferSize: 10, logger: Logger(label: "test"))
        await dispatcher.publish(
            .requested(
                CalculationRequested(
                    eventID: RecordFixtures.id(1).rawValue,
                    occurredAt: RecordFixtures.epoch,
                    calculationID: RecordFixtures.id(1),
                    type: CalculationType(module: ModuleName("arithmetic"), operation: OperationName("add")),
                    trace: RecordFixtures.trace
                )
            )
        )
        let fixture = fixture(events: dispatcher)

        let shutdown = Task { await fixture.sequence.run() }
        await gate.open()
        await shutdown.value

        #expect(await subscriber.handled == [RecordFixtures.id(1)])
    }
}
