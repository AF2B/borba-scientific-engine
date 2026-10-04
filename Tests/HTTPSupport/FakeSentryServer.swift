import Foundation
import Synchronization
public import Vapor

/// One request the fake tracker received.
public struct ReceivedEnvelope: Sendable {
    /// The request path.
    public let path: String

    /// The `X-Sentry-Auth` header.
    public let authentication: String?

    /// The `Content-Type` header.
    public let contentType: String?

    /// The body, as text.
    public let body: String
}

/// What the fake server has received and how it answers. A class, because a `Mutex` cannot be captured by the route.
private final class Inbox: Sendable {
    let received = Mutex<[ReceivedEnvelope]>([])
    let status: Mutex<HTTPResponseStatus>

    init(status: HTTPResponseStatus) {
        self.status = Mutex(status)
    }
}

/// A stand-in for Sentry: a real HTTP server on a free local port that records what is posted to it, so the error
/// reporter can be exercised over a real connection without any external service.
public final class FakeSentryServer: Sendable {
    private static let loopback = "127.0.0.1"
    private static let anyFreePort = 0

    /// Connections kept alive by the client would otherwise hold the shutdown for Vapor's default ten seconds.
    private static let shutdownTimeoutMilliseconds: Int64 = 100

    private let application: Application
    private let inbox: Inbox

    /// The port the server listens on.
    public let port: Int

    /// Starts the server.
    ///
    /// - Parameter status: What it answers every envelope with.
    /// - Throws: An error when the server cannot start.
    public init(answering status: HTTPResponseStatus = .ok) async throws {
        let application = try await Application.make(.testing)
        let inbox = Inbox(status: status)

        application.post("api", ":project", "envelope") { request async throws -> Response in
            let entry = ReceivedEnvelope(
                path: request.url.path,
                authentication: request.headers.first(name: "X-Sentry-Auth"),
                contentType: request.headers.first(name: .contentType),
                body: request.body.string ?? ""
            )
            inbox.received.withLock { $0.append(entry) }
            return Response(status: inbox.status.withLock { $0 })
        }
        application.http.server.configuration.shutdownTimeout = .milliseconds(Self.shutdownTimeoutMilliseconds)
        try await application.server.start(address: .hostname(Self.loopback, port: Self.anyFreePort))

        self.application = application
        self.inbox = inbox
        port = application.http.server.shared.localAddress?.port ?? Self.anyFreePort
    }

    /// The DSN that points at this server.
    public var dsn: String {
        "http://test-public-key@\(Self.loopback):\(port)/1"
    }

    /// Everything received so far, in order.
    public var envelopes: [ReceivedEnvelope] {
        inbox.received.withLock { $0 }
    }

    /// Makes the server answer with another status from now on.
    ///
    /// - Parameter newStatus: The status.
    public func answer(with newStatus: HTTPResponseStatus) {
        inbox.status.withLock { $0 = newStatus }
    }

    /// Stops the server.
    public func stop() async {
        await application.server.shutdown()
        try? await application.asyncShutdown()
    }
}
