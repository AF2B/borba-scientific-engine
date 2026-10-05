import AsyncHTTPClient
import Foundation
import NIOCore
import Vapor

/// Why a probe concluded that an instance is not healthy.
enum HealthProbeFailure: Error, Equatable, CustomStringConvertible {
    /// Nothing answered in time, or the connection failed.
    case unreachable(String)

    /// The instance answered, but not with success.
    case unexpectedStatus(UInt)

    var description: String {
        switch self {
        case .unreachable(let reason):
            "no answer: \(reason)"
        case .unexpectedStatus(let status):
            "answered with status \(status)"
        }
    }
}

/// Asks a running instance whether it is alive. This is the command behind the container's health check: the runtime
/// image carries no `curl`, so the executable probes itself.
///
/// The probe asks for liveness (`/health`), not readiness (`/ready`). An orchestrator that restarts what it finds
/// unhealthy must not restart this process because its database is down, since a restart does not bring the database
/// back; and an instance that is draining for shutdown is still alive and keeps answering.
enum HealthProbe {
    /// The command-line argument that selects the probe: `borba-scientific-engine healthcheck`.
    static let commandName = "healthcheck"

    /// How long the probe waits for an answer. A container health check should allow its command a little longer.
    static let defaultTimeout = Duration.seconds(defaultTimeoutSeconds)

    private static let defaultTimeoutSeconds = 3
    private static let scheme = "http"
    private static let loopbackHost = "127.0.0.1"

    /// Addresses a server binds to in order to listen on every interface. They say where to listen, not where to connect.
    private static let wildcardHosts: Set<String> = ["0.0.0.0", "::"]

    private static let ipv6Marker: Character = ":"
    private static let attosecondsPerNanosecond: Int64 = 1_000_000_000
    private static let healthyMessage = "healthy"

    /// Probes the instance this process is configured to be, and reports the outcome on the standard streams.
    ///
    /// - Parameter variables: Environment variables the configuration is read from, as for the server itself.
    /// - Returns: `EXIT_SUCCESS` when the instance answered `200 OK`, `EXIT_FAILURE` otherwise.
    static func run(environment variables: [String: String]) async -> Int32 {
        do {
            let configuration = try ConfigurationLoader.load(from: variables)
            try await check(url: healthURL(for: configuration.http))

            write(healthyMessage, to: .standardOutput)
            return EXIT_SUCCESS
        } catch {
            write("unhealthy: \(error)", to: .standardError)
            return EXIT_FAILURE
        }
    }

    /// The address to probe for a server configured with `settings`.
    ///
    /// - Parameter settings: The HTTP settings of the instance.
    /// - Returns: The URL of its liveness endpoint. A server listening on every interface is reached through loopback.
    static func healthURL(for settings: HTTPSettings) -> String {
        let host = wildcardHosts.contains(settings.host) ? loopbackHost : settings.host
        let authority = host.contains(ipv6Marker) ? "[\(host)]" : host

        return "\(scheme)://\(authority):\(settings.port)/\(OperationalPath.health)"
    }

    /// Requests a URL and requires `200 OK`.
    ///
    /// - Parameters:
    ///   - url: The liveness endpoint.
    ///   - timeout: How long to wait for the answer, which also bounds a connection that is being refused.
    /// - Throws: ``HealthProbeFailure`` when nothing answers in time or the answer is not `200 OK`.
    static func check(
        url: String,
        timeout: Duration = defaultTimeout
    ) async throws(HealthProbeFailure) {
        let status: HTTPResponseStatus

        do {
            let response = try await HTTPClient.shared.execute(
                HTTPClientRequest(url: url),
                timeout: timeAmount(timeout)
            )
            for try await _ in response.body {}
            status = response.status
        } catch {
            throw .unreachable("\(error)")
        }

        guard status == .ok else {
            throw .unexpectedStatus(status.code)
        }
    }

    private static func timeAmount(_ duration: Duration) -> TimeAmount {
        let components = duration.components

        return .seconds(components.seconds) + .nanoseconds(components.attoseconds / attosecondsPerNanosecond)
    }

    private static func write(
        _ message: String,
        to stream: FileHandle
    ) {
        stream.write(Data((message + "\n").utf8))
    }
}
