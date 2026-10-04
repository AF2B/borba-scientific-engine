import BorbaScientificCore
import Logging

/// Delivers calculation events to subscribers without ever making a request wait for them.
///
/// Publishing is a non-blocking hand-off. Every subscriber owns a bounded queue (an `AsyncStream`) and a task that
/// drains it, so:
///
/// - a slow subscriber delays nobody: not the request that published, not the other subscribers;
/// - a subscriber that falls behind loses its **oldest** events instead of growing memory without bound or applying
///   back-pressure to requests — the drop is counted and logged, never silent;
/// - each subscriber sees events in the order they were published.
///
/// The dispatcher is an actor because it owns mutable state — the queues and the drop counters — that every request
/// touches concurrently. The work of the subscribers runs on their own tasks, outside the actor.
///
/// Delivery is at most once and in-process. That is the right strength for observers (logs, metrics, alerts): the
/// calculation is already stored when its event is published, so losing an event never loses data. A consumer that
/// needed guaranteed delivery would need an outbox in the database, which this service deliberately does not have.
actor EventDispatcher: EventPublisher {
    /// How often a subscriber's drops are written to the log: the first one, then every this-many-th.
    static let dropLogInterval = 1_000

    private struct Channel {
        let name: String
        let continuation: AsyncStream<CalculationEvent>.Continuation
        let consumer: Task<Void, Never>
    }

    private let channels: [Channel]
    private let logger: Logger
    private let onDrop: @Sendable (String) -> Void
    private var dropped: [String: Int] = [:]
    private var isStopped = false

    /// Starts one consumer task per subscriber.
    ///
    /// - Parameters:
    ///   - subscribers: Who receives the events.
    ///   - bufferSize: How many undelivered events each subscriber may have queued before its oldest are dropped.
    ///   - logger: Where drops and shutdown problems are reported.
    ///   - onDrop: Told, with the subscriber's name, about every event that is dropped.
    init(
        subscribers: [any EventSubscriber],
        bufferSize: Int,
        logger: Logger,
        onDrop: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.logger = logger
        self.onDrop = onDrop
        channels = subscribers.map { subscriber in
            let (stream, continuation) = AsyncStream.makeStream(
                of: CalculationEvent.self,
                bufferingPolicy: .bufferingNewest(bufferSize)
            )
            let consumer = Task {
                for await event in stream {
                    await subscriber.handle(event)
                }
            }
            return Channel(name: subscriber.name, continuation: continuation, consumer: consumer)
        }
    }

    /// Queues an event for every subscriber and returns immediately.
    ///
    /// - Parameter event: The event to deliver. Events published after ``shutdown(within:clock:)`` are discarded.
    func publish(_ event: CalculationEvent) async {
        guard !isStopped else {
            return
        }

        for channel in channels {
            if case .dropped = channel.continuation.yield(event) {
                recordDrop(for: channel.name)
            }
        }
    }

    /// How many events a subscriber missed because it could not keep up.
    ///
    /// - Parameter subscriber: The subscriber's name.
    /// - Returns: The number of events dropped so far.
    func droppedCount(for subscriber: String) -> Int {
        dropped[subscriber, default: 0]
    }

    /// Stops accepting events, lets every subscriber finish what is already queued and waits for them.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait for the subscribers to drain.
    ///   - clock: Measures the wait.
    /// - Returns: `true` when every subscriber drained in time; `false` when the time ran out, in which case the
    ///   remaining subscribers are cancelled and whatever they had not handled is lost.
    @discardableResult
    func shutdown(
        within timeout: Duration,
        clock: any EngineClock
    ) async -> Bool {
        isStopped = true
        for channel in channels {
            channel.continuation.finish()
        }

        let consumers = channels.map(\.consumer)
        let drained = await Race.firstToFinish(
            {
                for consumer in consumers {
                    await consumer.value
                }
                return true
            },
            {
                try? await clock.sleep(for: timeout)
                return false
            }
        )

        if !drained {
            consumers.forEach { $0.cancel() }
            logger.warning("Event subscribers did not drain before shutdown; queued events were lost")
        }
        return drained
    }

    private func recordDrop(for subscriber: String) {
        let count = dropped[subscriber, default: 0] + 1
        dropped[subscriber] = count
        onDrop(subscriber)

        if count == 1 || count.isMultiple(of: Self.dropLogInterval) {
            logger.warning(
                "An event subscriber cannot keep up; its oldest events are being dropped",
                metadata: ["subscriber": "\(subscriber)", "dropped_total": "\(count)"]
            )
        }
    }
}
