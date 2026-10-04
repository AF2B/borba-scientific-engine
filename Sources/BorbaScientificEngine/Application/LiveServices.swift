import BorbaScientificCore
import BorbaScientificPersistence
import Fluent
import FluentPostgresDriver
import Vapor

/// Builds the production object graph: PostgreSQL behind a retrying decorator, the real clock, the standard calculation
/// modules, an event dispatcher and the readiness checks.
enum LiveServices {
    private static let readinessTimeToLiveSeconds = 1
    private static let readinessProbeTimeoutSeconds = 2
    private static let eventDrainTimeoutSeconds = 5

    /// How many undelivered events each subscriber may queue before its oldest are dropped.
    static let eventBufferSize = 1_000

    /// How long an answer to a readiness probe is reused.
    static let readinessTimeToLive = Duration.seconds(readinessTimeToLiveSeconds)

    /// The longest a single readiness probe may take before it is reported down.
    static let readinessProbeTimeout = Duration.seconds(readinessProbeTimeoutSeconds)

    /// The longest the event subscribers get to deliver queued events during shutdown.
    static let eventDrainTimeout = Duration.seconds(eventDrainTimeoutSeconds)

    /// Registers the database and its migrations on the application and assembles the services on top of them.
    ///
    /// Nothing connects here: the pool opens connections on first use, and migrations run only through the `migrate`
    /// command, never on startup.
    ///
    /// - Parameters:
    ///   - application: The application that owns the database registry and the migrate command.
    ///   - configuration: Validated runtime configuration.
    /// - Returns: The services the routes need.
    /// - Throws: ``RepositoryError`` when the database URL cannot be used.
    static func assemble(
        for application: Application,
        with configuration: AppConfiguration
    ) throws(RepositoryError) -> EngineServices {
        let database = configuration.database
        let settings = PostgresSettings(
            url: database.url.reveal(),
            applicationName: ServiceIdentity.name,
            maximumConnectionsPerEventLoop: database.maximumConnectionsPerEventLoop,
            connectionPoolTimeout: database.connectionPoolTimeout,
            statementTimeout: database.statementTimeout
        )
        application.databases.use(try settings.makeConfiguration(), as: .psql)
        application.migrations.add(PersistenceMigrations.all)

        let clock = SystemClock()
        let logger = application.logger

        let repository = RetryingCalculationRepository(
            base: FluentCalculationRepository(databases: application.databases, logger: logger),
            policy: .standard,
            clock: clock,
            logger: logger
        )
        let dispatcher = EventDispatcher(
            subscribers: [LoggingEventSubscriber(logger: logger)],
            bufferSize: eventBufferSize,
            logger: logger
        )
        let health = DatabaseHealth(
            databases: application.databases,
            databaseID: .psql,
            expectedMigrations: PersistenceMigrations.names,
            clock: clock,
            logger: logger
        )

        return assemble(
            repository: repository,
            events: dispatcher,
            clock: clock,
            calculation: configuration.calculation,
            probes: [DatabaseReadinessProbe(health: health)],
            eventDispatcher: dispatcher
        )
    }

    /// Assembles the services over any repository, which is how tests build the same graph with in-memory adapters.
    ///
    /// - Parameters:
    ///   - repository: The calculation history store.
    ///   - events: Receives events about each calculation.
    ///   - clock: The time source of timestamps, measurements and time budgets.
    ///   - calculation: The calculation limits.
    ///   - probes: What must be up for the service to be ready.
    ///   - eventDispatcher: The dispatcher behind `events`, when the services own it and must drain it on shutdown.
    /// - Returns: The services the routes need.
    static func assemble(
        repository: any CalculationRepository,
        events: any EventPublisher,
        clock: any EngineClock,
        calculation: CalculationSettings,
        probes: [any ReadinessProbe] = [],
        eventDispatcher: EventDispatcher? = nil
    ) -> EngineServices {
        let registry = ModuleRegistry.standard()
        let identifiers = UUIDv7Generator(clock: clock)
        let shutdown = ShutdownState()
        let engine = CalculationEngine(
            registry: registry,
            clock: clock,
            timeout: calculation.timeout
        )

        return EngineServices(
            calculations: CalculationService(
                engine: engine,
                repository: repository,
                events: events,
                clock: clock,
                identifiers: identifiers
            ),
            history: CalculationHistory(repository: repository),
            registry: registry,
            identifiers: identifiers,
            clock: clock,
            readiness: ReadinessService(
                probes: probes,
                shutdown: shutdown,
                timeToLive: readinessTimeToLive,
                probeTimeout: readinessProbeTimeout,
                clock: clock
            ),
            shutdown: shutdown,
            inFlight: InFlightRequests(),
            eventDispatcher: eventDispatcher
        )
    }
}
