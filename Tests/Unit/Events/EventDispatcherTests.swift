import BorbaScientificCore
import Logging
import TestSupport
import Testing

@testable import BorbaScientificEngine

@Suite("EventDispatcher", .timeLimit(.minutes(1)))
struct EventDispatcherTests {
    private static let drainTimeout = Duration.seconds(10)

    private func event(_ sequence: Int) -> CalculationEvent {
        .requested(
            CalculationRequested(
                eventID: RecordFixtures.id(sequence).rawValue,
                occurredAt: RecordFixtures.epoch,
                calculationID: RecordFixtures.id(sequence),
                type: CalculationType(module: ModuleName("arithmetic"), operation: OperationName("add")),
                trace: RecordFixtures.trace
            )
        )
    }

    private func ids(_ range: ClosedRange<Int>) -> [CalculationID] {
        range.map(RecordFixtures.id)
    }

    @Test("delivers every event to every subscriber, in the order it was published")
    func deliversInOrder() async {
        let first = RecordingSubscriber(name: "first")
        let second = RecordingSubscriber(name: "second")
        let dispatcher = EventDispatcher(subscribers: [first, second], bufferSize: 100, logger: Logger(label: "test"))

        for sequence in 1...5 {
            await dispatcher.publish(event(sequence))
        }
        await first.waitUntilHandled(count: 5)
        await second.waitUntilHandled(count: 5)

        #expect(await first.handled == ids(1...5))
        #expect(await second.handled == ids(1...5))
    }

    @Test("lets a stalled subscriber delay neither the publisher nor the other subscribers")
    func isolatesSlowSubscribers() async {
        let gate = Gate()
        let slow = RecordingSubscriber(name: "slow", gate: gate)
        let fast = RecordingSubscriber(name: "fast")
        let dispatcher = EventDispatcher(subscribers: [slow, fast], bufferSize: 100, logger: Logger(label: "test"))

        for sequence in 1...3 {
            await dispatcher.publish(event(sequence))
        }
        await fast.waitUntilHandled(count: 3)

        #expect(await fast.handled == ids(1...3))
        #expect(await slow.handled.isEmpty, "the slow subscriber is still stalled")

        await gate.open()
        await slow.waitUntilHandled(count: 3)
        #expect(await slow.handled == ids(1...3))
    }

    @Test("drops the oldest queued events of a subscriber that cannot keep up, and counts them")
    func dropsTheOldest() async {
        let gate = Gate()
        let slow = RecordingSubscriber(name: "slow", gate: gate)
        let dispatcher = EventDispatcher(subscribers: [slow], bufferSize: 2, logger: Logger(label: "test"))

        await dispatcher.publish(event(1))
        await slow.waitUntilStarted(count: 1)
        for sequence in 2...5 {
            await dispatcher.publish(event(sequence))
        }
        await gate.open()
        await slow.waitUntilHandled(count: 3)

        #expect(await slow.handled == [1, 4, 5].map(RecordFixtures.id), "events 2 and 3 were the oldest queued")
        #expect(await dispatcher.droppedCount(for: "slow") == 2)
        #expect(await dispatcher.droppedCount(for: "unknown") == 0)
    }

    @Test("drains what is queued on shutdown and ignores later events")
    func shutdownDrains() async {
        let gate = Gate()
        let subscriber = RecordingSubscriber(name: "queued", gate: gate)
        let clock = ManualClock()
        let dispatcher = EventDispatcher(subscribers: [subscriber], bufferSize: 100, logger: Logger(label: "test"))
        for sequence in 1...3 {
            await dispatcher.publish(event(sequence))
        }

        async let drained = dispatcher.shutdown(within: Self.drainTimeout, clock: clock)
        await gate.open()

        #expect(await drained)
        #expect(await subscriber.handled == ids(1...3))

        await dispatcher.publish(event(4))
        #expect(await subscriber.handled == ids(1...3), "nothing is delivered after shutdown")
    }

    @Test("gives up on subscribers that do not drain in time")
    func shutdownTimesOut() async {
        let gate = Gate()
        let stuck = RecordingSubscriber(name: "stuck", gate: gate)
        let clock = ManualClock()
        let dispatcher = EventDispatcher(subscribers: [stuck], bufferSize: 100, logger: Logger(label: "test"))
        await dispatcher.publish(event(1))
        await stuck.waitUntilStarted(count: 1)

        async let drained = dispatcher.shutdown(within: Self.drainTimeout, clock: clock)
        await clock.waitUntilSleeping()
        clock.advance(by: Self.drainTimeout)

        #expect(await drained == false)
        await gate.open()
    }

    @Test("shuts down at once when there are no subscribers")
    func noSubscribers() async {
        let dispatcher = EventDispatcher(subscribers: [], bufferSize: 10, logger: Logger(label: "test"))

        await dispatcher.publish(event(1))

        #expect(await dispatcher.shutdown(within: Self.drainTimeout, clock: ManualClock()))
    }
}
