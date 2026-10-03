public import BorbaScientificCore
public import FluentKit
import FluentPostgresDriver
import NIOCore
import PostgresKit

/// How to connect to PostgreSQL.
public struct PostgresSettings: Sendable, Equatable {
    private static let applicationNameParameter = "application_name"
    private static let statementTimeoutParameter = "statement_timeout"
    private static let millisecondsPerSecond: Int64 = 1_000
    private static let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000

    /// The connection URL, which embeds the credentials.
    public let url: String

    /// Reported to the server on every connection, so database operators can tell this application's sessions apart.
    public let applicationName: String

    /// Pool size per event loop. The total pool size is this value times the number of event loops.
    public let maximumConnectionsPerEventLoop: Int

    /// Longest a call waits for a free pooled connection before failing.
    public let connectionPoolTimeout: Duration

    /// Longest the server lets a single statement run before cancelling it.
    public let statementTimeout: Duration

    /// Creates connection settings.
    ///
    /// - Parameters:
    ///   - url: The connection URL, such as `postgres://user:password@host:5432/database`.
    ///   - applicationName: The name the server shows for this application's sessions in `pg_stat_activity`.
    ///   - maximumConnectionsPerEventLoop: Pool size per event loop.
    ///   - connectionPoolTimeout: Longest a call waits for a free pooled connection.
    ///   - statementTimeout: Longest the server lets a single statement run.
    public init(
        url: String,
        applicationName: String,
        maximumConnectionsPerEventLoop: Int,
        connectionPoolTimeout: Duration,
        statementTimeout: Duration
    ) {
        self.url = url
        self.applicationName = applicationName
        self.maximumConnectionsPerEventLoop = maximumConnectionsPerEventLoop
        self.connectionPoolTimeout = connectionPoolTimeout
        self.statementTimeout = statementTimeout
    }

    /// Builds the driver configuration to register with Fluent's `Databases` (as `DatabaseID.psql`).
    ///
    /// Every connection announces the application name and a statement timeout to the server, so a runaway query is
    /// cancelled by PostgreSQL itself even if the client is stuck.
    ///
    /// - Returns: A configuration factory.
    /// - Throws: ``RepositoryError/unexpected(reason:)`` when the URL is not a valid PostgreSQL URL. The URL is never
    ///   included in the error.
    public func makeConfiguration() throws(RepositoryError) -> DatabaseConfigurationFactory {
        var configuration: SQLPostgresConfiguration
        do {
            configuration = try SQLPostgresConfiguration(url: url)
        } catch {
            throw .unexpected(reason: "The database URL is not a valid PostgreSQL URL")
        }

        configuration.coreConfiguration.options.additionalStartupParameters += [
            (Self.applicationNameParameter, applicationName),
            (Self.statementTimeoutParameter, String(milliseconds(of: statementTimeout))),
        ]

        return .postgres(
            configuration: configuration,
            maxConnectionsPerEventLoop: maximumConnectionsPerEventLoop,
            connectionPoolTimeout: .milliseconds(milliseconds(of: connectionPoolTimeout))
        )
    }

    private func milliseconds(of duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * Self.millisecondsPerSecond + components.attoseconds / Self.attosecondsPerMillisecond
    }
}
