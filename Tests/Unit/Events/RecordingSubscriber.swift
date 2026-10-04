import BorbaScientificCore
import TestSupport

@testable import BorbaScientificEngine

/// Records what it receives and can be made to stall.
actor RecordingSubscriber: EventSubscriber {
    nonisolated let name: String

    private let gate: Gate?
    private(set) var handled: [CalculationID] = []
    private var started = 0

    /// - Parameters:
    ///   - name: The subscriber's name.
    ///   - gate: When given, every event stalls here until the gate opens.
    init(
        name: String,
        gate: Gate? = nil
    ) {
        self.name = name
        self.gate = gate
    }

    func handle(_ event: CalculationEvent) async {
        started += 1
        await gate?.wait()
        handled.append(event.calculationID)
    }

    func waitUntilStarted(count: Int) async {
        while started < count {
            await Task.yield()
        }
    }

    func waitUntilHandled(count: Int) async {
        while handled.count < count {
            await Task.yield()
        }
    }
}
