import BorbaScientificCore
import Foundation

/// What identifies this service and this run to Sentry, constant for the life of the process.
struct SentryContext: Sendable, Equatable {
    /// The release, such as `borba-scientific-engine@1.2.3`.
    let release: String

    /// The environment, such as `production`.
    let environment: String

    /// The version of the client, reported in the authentication header and the `sdk` field.
    let clientVersion: String
}

/// Where reports go and who they are from: a Sentry project and the identity of this service.
struct SentryProject: Sendable, Equatable {
    /// The project reports go to.
    let dsn: SentryDSN

    /// What identifies this service and this run.
    let context: SentryContext
}

/// One error report, ready to post: Sentry's envelope format, which is newline-delimited JSON.
///
/// ```text
/// {"event_id":"…","sent_at":"…","dsn":"https://host/1"}
/// {"type":"event","length":412}
/// {…the event…}
/// ```
///
/// Sentry's SDKs do not support Linux for Swift, and the envelope is a small, documented format, so the service writes it
/// itself. What goes into the event is decided here, in one place: see ``ReportableFailure`` for what never does.
struct SentryEnvelope: Sendable, Equatable {
    /// The longest diagnostic that is sent, in characters.
    static let maximumDiagnosticLength = 500

    private static let clientName = "borba-scientific-engine.sentry"
    private static let platform = "swift"
    private static let loggerName = "borba-scientific-engine"
    private static let eventItemType = "event"
    private static let level = "error"
    private static let lineSeparator = "\n"

    private struct Header: Encodable {
        let eventID: String
        let sentAt: String
        let dsn: String

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case sentAt = "sent_at"
            case dsn
        }
    }

    private struct ItemHeader: Encodable {
        let type: String
        let length: Int
    }

    private struct SDK: Encodable {
        let name: String
        let version: String
    }

    private struct Event: Encodable {
        let eventID: String
        let timestamp: String
        let platform: String
        let level: String
        let logger: String
        let message: String
        let release: String
        let environment: String
        let fingerprint: [String]
        let tags: [String: String]
        let contexts: [String: [String: String]]
        let extra: [String: CalculationValue]
        let sdk: SDK

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case timestamp
            case platform
            case level
            case logger
            case message
            case release
            case environment
            case fingerprint
            case tags
            case contexts
            case extra
            case sdk
        }
    }

    /// The identifier of the event, 32 lowercase hexadecimal characters.
    let eventID: String

    /// The envelope as it is posted.
    let body: Data

    /// Builds the envelope for a failure.
    ///
    /// - Parameters:
    ///   - failure: What went wrong.
    ///   - repeats: How many identical failures were folded into this report since the last one.
    ///   - eventID: The identifier of the event, 32 hexadecimal characters.
    ///   - occurredAt: When the failure happened.
    ///   - project: The project the report is for and the identity of this service.
    /// - Returns: The envelope.
    /// - Throws: An encoding error, which does not happen for the values built here.
    static func make(
        for failure: ReportableFailure,
        repeats: Int,
        eventID: String,
        occurredAt: Date,
        project: SentryProject
    ) throws -> SentryEnvelope {
        let context = project.context
        let dsn = project.dsn
        let timestamp = Timestamp.format(occurredAt)
        let event = Event(
            eventID: eventID,
            timestamp: timestamp,
            platform: platform,
            level: level,
            logger: loggerName,
            message: "\(failure.code.rawValue): \(failure.message)",
            release: context.release,
            environment: context.environment,
            fingerprint: [failure.code.rawValue, failure.route],
            tags: [
                "error_code": failure.code.rawValue,
                "classification": classification(of: failure),
                "method": failure.method,
                "route": failure.route,
                "http_status": String(failure.status),
            ],
            contexts: [
                "request": [
                    TraceMetadataKey.requestID: failure.trace.requestID.rawValue,
                    TraceMetadataKey.correlationID: failure.trace.correlationID.rawValue,
                ]
            ],
            extra: extra(for: failure, repeats: repeats),
            sdk: SDK(name: clientName, version: context.clientVersion)
        )

        let encoder = JSONCoding.makeEncoder()
        let payload = try encoder.encode(event)
        let header = try encoder.encode(Header(eventID: eventID, sentAt: timestamp, dsn: dsn.redacted))
        let itemHeader = try encoder.encode(ItemHeader(type: eventItemType, length: payload.count))

        var body = Data()
        for part in [header, itemHeader, payload] {
            body.append(part)
            body.append(Data(lineSeparator.utf8))
        }
        return SentryEnvelope(eventID: eventID, body: body)
    }

    private static func extra(
        for failure: ReportableFailure,
        repeats: Int
    ) -> [String: CalculationValue] {
        var extra: [String: CalculationValue] = [:]

        if repeats > 0 {
            extra["repeats_since_last_report"] = .number(Double(repeats))
        }
        if failure.classification == .infrastructure, let diagnostic = failure.diagnostic {
            extra["diagnostic"] = .text(String(LogRedaction.mask(diagnostic).prefix(maximumDiagnosticLength)))
        }
        return extra
    }

    private static func classification(of failure: ReportableFailure) -> String {
        switch failure.classification {
        case .expectedDomain:
            "expected_domain"
        case .application:
            "application"
        case .infrastructure:
            "infrastructure"
        case .unexpected:
            "unexpected"
        }
    }
}
