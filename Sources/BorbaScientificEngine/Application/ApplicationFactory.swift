import BorbaScientificCore
import Foundation
import NIOCore
public import Vapor

/// Composition root: wires configuration, adapters, middleware and routes into a Vapor application.
public enum ApplicationFactory {
    /// Configures an application for production use: the real database, clock and calculation modules.
    ///
    /// - Parameters:
    ///   - application: Freshly created application to configure.
    ///   - configuration: Validated runtime configuration.
    /// - Throws: Any error raised while wiring the services or registering routes.
    public static func configure(
        _ application: Application,
        with configuration: AppConfiguration
    ) throws {
        let services = try LiveServices.assemble(for: application, with: configuration)

        try configure(application, with: configuration, services: services, watchingSignals: true)
    }

    /// Configures an application over services that have already been assembled.
    ///
    /// Tests use this entry point to run the full HTTP stack — middleware, routing, error mapping — over in-memory
    /// adapters.
    ///
    /// - Parameters:
    ///   - application: Freshly created application to configure.
    ///   - configuration: Validated runtime configuration.
    ///   - services: The services the routes use.
    ///   - watchingSignals: Whether to watch `SIGTERM` and `SIGINT` to flip readiness the moment shutdown begins. Off
    ///     in tests, where the process must keep its default signal handling.
    /// - Throws: Any error raised while registering routes.
    static func configure(
        _ application: Application,
        with configuration: AppConfiguration,
        services: EngineServices,
        watchingSignals: Bool = false
    ) throws {
        application.http.server.configuration.hostname = configuration.http.host
        application.http.server.configuration.port = configuration.http.port
        application.routes.defaultMaxBodySize = ByteCount(value: configuration.http.maximumBodySizeBytes)
        application.http.server.configuration.shutdownTimeout = TimeAmount(configuration.http.shutdownTimeout)

        configureMiddleware(application, services: services)
        try registerRoutes(application, with: configuration, services: services)
        registerShutdown(application, with: configuration, services: services, watchingSignals: watchingSignals)
    }

    /// Replaces Vapor's default error handling with the API's own and orders the middleware, outermost first: the
    /// in-flight count, request identifiers, access log, security headers, error mapping.
    private static func configureMiddleware(
        _ application: Application,
        services: EngineServices
    ) {
        application.middleware = Middlewares()
        application.middleware.use(InFlightMiddleware(requests: services.inFlight))
        application.middleware.use(RequestContextMiddleware(identifiers: services.identifiers))
        application.middleware.use(AccessLogMiddleware(clock: services.clock))
        application.middleware.use(SecurityHeadersMiddleware())
        application.middleware.use(APIErrorMiddleware())
    }

    private static func registerRoutes(
        _ application: Application,
        with configuration: AppConfiguration,
        services: EngineServices
    ) throws {
        try application.register(
            collection: OperationalRoutes(
                version: versionResponse(for: configuration),
                readiness: services.readiness
            )
        )
        try application.register(
            collection: CalculationRoutes(service: services.calculations, settings: configuration.calculation)
        )
        try application.register(collection: HistoryRoutes(history: services.history))
        try application.register(collection: CatalogRoutes(registry: services.registry))
    }

    /// Flips readiness when a termination signal arrives, and on shutdown waits for the requests in flight and drains the
    /// event subscribers before the database closes.
    private static func registerShutdown(
        _ application: Application,
        with configuration: AppConfiguration,
        services: EngineServices,
        watchingSignals: Bool
    ) {
        application.lifecycle.use(
            ShutdownLifecycle(
                sequence: ShutdownSequence(
                    state: services.shutdown,
                    inFlight: services.inFlight,
                    events: services.eventDispatcher,
                    requestDrainTimeout: configuration.http.shutdownTimeout,
                    eventDrainTimeout: LiveServices.eventDrainTimeout,
                    clock: SystemClock(),
                    logger: application.logger
                ),
                watcher: watchingSignals
                    ? ShutdownSignalWatcher(signals: [SIGTERM, SIGINT], state: services.shutdown) : nil
            )
        )
    }

    private static func versionResponse(for configuration: AppConfiguration) -> VersionResponse {
        VersionResponse(
            name: ServiceIdentity.name,
            version: configuration.version.number,
            commit: configuration.version.commit,
            buildDate: configuration.version.buildDate,
            environment: configuration.environment.rawValue,
            apiVersions: ServiceIdentity.apiVersions
        )
    }
}
