import Foundation
import NIOCore
import Vapor

/// Why an envelope could not be delivered. Carries no detail: nothing in it is worth logging beyond the fact.
enum TransportFailure: Error, Sendable, Equatable {
    /// The tracker could not be reached or did not answer.
    case unreachable

    /// The tracker answered with a status that is not a success, such as `429` when over quota.
    case rejected(status: UInt)
}

/// Delivers envelopes to an error tracker.
protocol EnvelopeTransport: Sendable {
    /// Posts an envelope.
    ///
    /// - Parameters:
    ///   - envelope: What to send.
    ///   - dsn: Where to send it.
    ///   - clientVersion: Reported in the authentication header.
    /// - Throws: ``TransportFailure`` when it was not delivered.
    func deliver(
        _ envelope: SentryEnvelope,
        to dsn: SentryDSN,
        clientVersion: String
    ) async throws(TransportFailure)
}

/// Posts envelopes with Vapor's HTTP client.
struct VaporEnvelopeTransport: EnvelopeTransport {
    private static let contentType = "application/x-sentry-envelope"
    private static let protocolVersion = 7
    private static let clientName = "borba-scientific-engine"
    private static let successStatuses: Range<UInt> = 200..<300

    private let client: any Client

    /// Creates the transport.
    ///
    /// - Parameter client: The HTTP client to post with.
    init(client: any Client) {
        self.client = client
    }

    /// Posts an envelope.
    ///
    /// - Parameters:
    ///   - envelope: What to send.
    ///   - dsn: Where to send it.
    ///   - clientVersion: Reported in the authentication header.
    /// - Throws: ``TransportFailure`` when it was not delivered.
    func deliver(
        _ envelope: SentryEnvelope,
        to dsn: SentryDSN,
        clientVersion: String
    ) async throws(TransportFailure) {
        let status = try await post(envelope, to: dsn, clientVersion: clientVersion)

        guard Self.successStatuses.contains(status) else {
            throw .rejected(status: status)
        }
    }

    private func post(
        _ envelope: SentryEnvelope,
        to dsn: SentryDSN,
        clientVersion: String
    ) async throws(TransportFailure) -> UInt {
        let authentication =
            "Sentry sentry_version=\(Self.protocolVersion), sentry_client=\(Self.clientName)/\(clientVersion), "
            + "sentry_key=\(dsn.publicKey)"

        do {
            let response = try await client.post(URI(string: dsn.envelopeURL)) { request in
                request.headers.replaceOrAdd(name: .contentType, value: Self.contentType)
                request.headers.replaceOrAdd(name: HTTPHeaders.Name("X-Sentry-Auth"), value: authentication)
                request.body = ByteBuffer(bytes: envelope.body)
            }
            return response.status.code
        } catch {
            throw .unreachable
        }
    }
}
