import BorbaScientificCore
import BorbaScientificPersistence
import Fluent
import FluentPostgresDriver
import Vapor

/// Builds the production object graph: PostgreSQL, the real clock and the standard calculation modules.
enum LiveServices {
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

        let repository = FluentCalculationRepository(
            databases: application.databases,
            logger: application.logger
        )
        return assemble(
            repository: repository,
            events: LoggingEventPublisher(logger: application.logger),
            clock: SystemClock(),
            calculation: configuration.calculation
        )
    }

    /// Assembles the services over any repository, which is how tests build the same graph with in-memory adapters.
    ///
    /// - Parameters:
    ///   - repository: The calculation history store.
    ///   - events: Receives events about each calculation.
    ///   - clock: The time source of timestamps, measurements and time budgets.
    ///   - calculation: The calculation limits.
    /// - Returns: The services the routes need.
    static func assemble(
        repository: any CalculationRepository,
        events: any EventPublisher,
        clock: any EngineClock,
        calculation: CalculationSettings
    ) -> EngineServices {
        let registry = ModuleRegistry.standard()
        let identifiers = UUIDv7Generator(clock: clock)
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
            identifiers: identifiers
        )
    }
}
