import BorbaScientificCore

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
}
