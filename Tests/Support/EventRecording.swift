public import BorbaScientificCore
public import Foundation
import Synchronization

/// An event publisher that remembers what it was given, so tests can assert on the event stream.
public actor RecordingEventPublisher: EventPublisher {
    private var recorded: [CalculationEvent] = []

    /// Creates an empty publisher.
    public init() {}

    /// Every event published so far, in order.
    public var events: [CalculationEvent] {
        recorded
    }

    /// The names of the events published so far, in order.
    public var eventNames: [String] {
        recorded.map(\.name)
    }

    /// Records an event.
    ///
    /// - Parameter event: The event to record.
    public func publish(_ event: CalculationEvent) async {
        recorded.append(event)
    }
}

/// Produces predictable identifiers: the first call returns `00000000-0000-0000-0000-000000000001`, the next one
/// `…002`, and so on.
public final class SequentialIdentifiers: IdentifierGenerator, Sendable {
    private let counter = Mutex<UInt64>(0)

    /// Creates a generator that starts counting at one.
    public init() {}

    /// Returns the next identifier in the sequence.
    public func next() -> UUID {
        let value = counter.withLock { counter -> UInt64 in
            counter += 1
            return counter
        }
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", value)) ?? UUID()
    }
}
