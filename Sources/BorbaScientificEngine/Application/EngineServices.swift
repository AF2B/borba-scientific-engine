import BorbaScientificCore
import Prometheus

/// The services the HTTP layer talks to, assembled once at startup and handed to the routes explicitly.
///
/// Nothing reaches for a global or a service locator: a route receives exactly the collaborators it uses, which keeps
/// the dependencies visible and lets tests assemble the same graph with in-memory adapters.
struct EngineServices: Sendable {
    /// Runs and records calculations.
    let calculations: CalculationService

    /// Reads the recorded calculations.
    let history: CalculationHistory

    /// The modules the engine can run, for the catalog endpoints.
    let registry: ModuleRegistry

    /// Creates request identifiers.
    let identifiers: any IdentifierGenerator

    /// The time source of timestamps and measurements.
    let clock: any EngineClock

    /// Records the metrics of the service.
    let metrics: EngineMetrics

    /// Holds every metric, and is what `/metrics` publishes.
    let metricsRegistry: PrometheusCollectorRegistry

    /// Told about the failures that deserve a person's attention.
    let errorReporter: any ErrorReporter

    /// Answers whether the service should be sent traffic.
    let readiness: ReadinessService

    /// Whether the process has begun to shut down.
    let shutdown: ShutdownState

    /// The requests being served, which the shutdown waits for.
    let inFlight: InFlightRequests

    /// Delivers events to their subscribers, when the services own one. The application drains it on shutdown.
    let eventDispatcher: EventDispatcher?
}
