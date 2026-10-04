import BorbaScientificCore
import BorbaScientificPersistence
import Fluent
import FluentPostgresDriver
import Foundation
import Logging
import Prometheus
import Vapor

/// Everything the services are assembled from: PostgreSQL-backed adapters in production, in-memory ones in tests.
struct ServiceInputs {
    /// The calculation history store.
    let repository: any CalculationRepository

    /// Receives events about each calculation.
    let events: any EventPublisher

    /// The time source of timestamps, measurements and time budgets.
    let clock: any EngineClock

    /// The calculation limits.
    let calculation: CalculationSettings

    /// What must be up for the service to be ready.
    let probes: [any ReadinessProbe]

    /// The dispatcher behind `events`, when the services own it and must drain it on shutdown.
    let eventDispatcher: EventDispatcher?

    /// Records the metrics of the service.
    let metrics: EngineMetrics

    /// Holds the metrics, and is what `/metrics` publishes.
    let metricsRegistry: PrometheusCollectorRegistry

    /// Told about the failures that deserve a person's attention.
    let errorReporter: any ErrorReporter

    /// Creates the inputs.
    ///
    /// - Parameters:
    ///   - repository: The calculation history store.
    ///   - events: Receives events about each calculation.
    ///   - clock: The time source of timestamps, measurements and time budgets.
    ///   - calculation: The calculation limits.
    ///   - metrics: Records the metrics of the service.
    ///   - metricsRegistry: Holds the metrics, and is what `/metrics` publishes.
    ///   - probes: What must be up for the service to be ready.
    ///   - eventDispatcher: The dispatcher behind `events`, if the services own it.
    ///   - errorReporter: Told about the failures that deserve a person's attention.
    init(
        repository: any CalculationRepository,
        events: any EventPublisher,
        clock: any EngineClock,
        calculation: CalculationSettings,
        metrics: EngineMetrics,
        metricsRegistry: PrometheusCollectorRegistry,
        probes: [any ReadinessProbe] = [],
        eventDispatcher: EventDispatcher? = nil,
        errorReporter: any ErrorReporter = DisabledErrorReporter()
    ) {
        self.repository = repository
        self.events = events
        self.clock = clock
        self.calculation = calculation
        self.metrics = metrics
        self.metricsRegistry = metricsRegistry
        self.probes = probes
        self.eventDispatcher = eventDispatcher
        self.errorReporter = errorReporter
    }
}

/// Builds the production object graph: PostgreSQL behind a metering and a retrying decorator, the real clock, the
/// standard calculation modules, an event dispatcher and the readiness checks.
enum LiveServices {
    private static let readinessTimeToLiveSeconds = 1
    private static let readinessProbeTimeoutSeconds = 2
    private static let eventDrainTimeoutSeconds = 5
    private static let errorReportDrainTimeoutSeconds = 2
    private static let errorReportQueueSize = 100
    private static let errorReportSendTimeoutSeconds = 5
    private static let throttleWindowSeconds = 60
    private static let reportsPerWindow = 30
    private static let trackerConnectTimeoutSeconds = 2
    private static let trackerReadTimeoutSeconds = 5

    /// How many undelivered events each subscriber may queue before its oldest are dropped.
    static let eventBufferSize = 1_000

    /// How long an answer to a readiness probe is reused.
    static let readinessTimeToLive = Duration.seconds(readinessTimeToLiveSeconds)

    /// The longest a single readiness probe may take before it is reported down.
    static let readinessProbeTimeout = Duration.seconds(readinessProbeTimeoutSeconds)

    /// The longest the event subscribers get to deliver queued events during shutdown.
    static let eventDrainTimeout = Duration.seconds(eventDrainTimeoutSeconds)

    /// The longest queued error reports get to be delivered during shutdown.
    static let errorReportDrainTimeout = Duration.seconds(errorReportDrainTimeoutSeconds)

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
        try registerDatabase(on: application, with: configuration)

        let clock = SystemClock()
        let logger = application.logger
        let metricsRegistry = PrometheusCollectorRegistry()
        let metrics = makeMetrics(over: metricsRegistry, for: configuration)

        let dispatcher = EventDispatcher(
            subscribers: [LoggingEventSubscriber(logger: logger), MetricsEventSubscriber(metrics: metrics)],
            bufferSize: eventBufferSize,
            logger: logger,
            onDrop: { metrics.recordDroppedEvent(subscriber: $0) }
        )
        let health = DatabaseHealth(
            databases: application.databases,
            databaseID: .psql,
            expectedMigrations: PersistenceMigrations.names,
            clock: clock,
            logger: logger
        )

        return assemble(
            ServiceInputs(
                repository: makeRepository(on: application, metrics: metrics, clock: clock),
                events: dispatcher,
                clock: clock,
                calculation: configuration.calculation,
                metrics: metrics,
                metricsRegistry: metricsRegistry,
                probes: [DatabaseReadinessProbe(health: health)],
                eventDispatcher: dispatcher,
                errorReporter: makeErrorReporter(
                    on: application,
                    for: configuration,
                    metrics: metrics,
                    clock: clock
                )
            )
        )
    }

    /// Assembles the services over any adapters, which is how tests build the same graph in memory.
    ///
    /// - Parameter inputs: The adapters and settings to assemble from.
    /// - Returns: The services the routes need.
    static func assemble(_ inputs: ServiceInputs) -> EngineServices {
        let registry = ModuleRegistry.standard()
        let identifiers = UUIDv7Generator(clock: inputs.clock)
        let shutdown = ShutdownState()
        let metrics = inputs.metrics
        let engine = CalculationEngine(
            registry: registry,
            clock: inputs.clock,
            timeout: inputs.calculation.timeout
        )

        return EngineServices(
            calculations: CalculationService(
                engine: engine,
                repository: inputs.repository,
                events: inputs.events,
                clock: inputs.clock,
                identifiers: identifiers
            ),
            history: CalculationHistory(repository: inputs.repository),
            registry: registry,
            identifiers: identifiers,
            clock: inputs.clock,
            metrics: metrics,
            metricsRegistry: inputs.metricsRegistry,
            errorReporter: inputs.errorReporter,
            readiness: ReadinessService(
                probes: inputs.probes,
                shutdown: shutdown,
                timeToLive: readinessTimeToLive,
                probeTimeout: readinessProbeTimeout,
                clock: inputs.clock
            ),
            shutdown: shutdown,
            inFlight: InFlightRequests(onChange: { metrics.setRequestsInFlight($0) }),
            eventDispatcher: inputs.eventDispatcher
        )
    }

    private static func registerDatabase(
        on application: Application,
        with configuration: AppConfiguration
    ) throws(RepositoryError) {
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
    }

    private static func makeMetrics(
        over registry: PrometheusCollectorRegistry,
        for configuration: AppConfiguration
    ) -> EngineMetrics {
        let metrics = EngineMetrics(factory: PrometheusMetricsFactory(registry: registry))

        metrics.setBuildInfo(
            version: configuration.version.number,
            commit: configuration.version.commit,
            environment: configuration.environment.rawValue
        )
        metrics.setProcessGauge(MetricName.processStartTime, Date().timeIntervalSince1970)
        return metrics
    }

    /// The error tracker: Sentry when a DSN is configured, nothing otherwise.
    private static func makeErrorReporter(
        on application: Application,
        for configuration: AppConfiguration,
        metrics: EngineMetrics,
        clock: any EngineClock
    ) -> any ErrorReporter {
        guard let dsn = configuration.sentry.dsn.flatMap({ SentryDSN.parse($0.reveal()) }) else {
            return DisabledErrorReporter()
        }

        // Connection attempts to an unreachable tracker are retried by the HTTP client until its connect timeout, which
        // defaults to ten seconds; bound it, so an outage of the tracker is noticed quickly and holds nothing for long.
        application.http.client.configuration.timeout.connect = .seconds(Int64(trackerConnectTimeoutSeconds))
        application.http.client.configuration.timeout.read = .seconds(Int64(trackerReadTimeoutSeconds))

        return SentryReporter(
            settings: SentryReporterSettings(
                project: SentryProject(
                    dsn: dsn,
                    context: SentryContext(
                        release: "\(ServiceIdentity.name)@\(configuration.version.number)",
                        environment: configuration.environment.rawValue,
                        clientVersion: configuration.version.number
                    )
                ),
                sampleRate: configuration.sentry.sampleRate,
                queueSize: errorReportQueueSize,
                sendTimeout: .seconds(errorReportSendTimeoutSeconds)
            ),
            transport: VaporEnvelopeTransport(client: application.client),
            throttle: ReportThrottle(
                window: .seconds(throttleWindowSeconds),
                limitPerWindow: reportsPerWindow,
                clock: clock
            ),
            clock: clock,
            identifiers: UUIDv7Generator(clock: clock),
            metrics: metrics,
            logger: application.logger
        )
    }

    /// The history store: PostgreSQL, measured on every attempt, and retried where repeating is safe. The metering sits
    /// under the retries so that a call that needed three tries shows up as three durations.
    private static func makeRepository(
        on application: Application,
        metrics: EngineMetrics,
        clock: any EngineClock
    ) -> any CalculationRepository {
        RetryingCalculationRepository(
            base: MeteredCalculationRepository(
                base: FluentCalculationRepository(databases: application.databases, logger: application.logger),
                metrics: metrics,
                clock: clock
            ),
            policy: .standard,
            clock: clock,
            logger: application.logger,
            onRetry: { metrics.recordRetry(operation: $0) }
        )
    }
}
