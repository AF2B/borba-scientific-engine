import BorbaScientificCore
import Foundation
import TestSupport
import Testing
import Vapor

@testable import BorbaScientificEngine

@Suite("ErrorMapper")
struct ErrorMapperTests {
    private struct Unrecognised: Error {}

    private static let requestID = RequestID("req-1")
    private static let secret = "db-host-7.internal password=hunter2"

    private func bodyText(of description: ErrorDescription) throws -> String {
        let data = try JSONCoding.makeEncoder().encode(description.response(requestID: Self.requestID))
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func body(of description: ErrorDescription) throws -> CalculationValue {
        let data = try JSONCoding.makeEncoder().encode(description.response(requestID: Self.requestID))
        return try JSONDecoder().decode(CalculationValue.self, from: data)
    }

    @Test("describes a refused request with the details of every rejected parameter")
    func validationFailure() throws {
        let rejected = ExecutionFailure.rejected(
            .validation(
                ValidationError(issues: [
                    ValidationIssue(parameter: "a", reason: "is required"),
                    ValidationIssue(parameter: "b", reason: "must be a number"),
                ])
            )
        )

        let description = ErrorMapper.describe(rejected)
        let json = try body(of: description)

        #expect(description.status == .unprocessableEntity)
        #expect(description.classification == .expectedDomain)
        #expect(json.at("error", "code") == "VALIDATION_FAILED")
        #expect(json.at("error", "request_id") == "req-1")
        #expect(json.at("error", "details", 0, "field") == "a")
        #expect(json.at("error", "details", 1, "reason") == "must be a number")
        #expect(json.at("error", "calculation_id") == nil)
    }

    @Test("omits details and calculation_id when there is nothing to say")
    func omitsEmptyFields() throws {
        let json = try body(of: ErrorMapper.describe(HistoryFailure.notFound(RecordFixtures.id(1))))

        #expect(json.at("error", "code") == "CALCULATION_NOT_FOUND")
        #expect(json.at("error", "details") == nil)
        #expect(json.at("error", "calculation_id") == nil)
    }

    @Test("keeps the cause of a defect out of the response and in the diagnostic")
    func defectsDoNotLeak() throws {
        let description = ErrorMapper.describe(ExecutionFailure.defect(reason: Self.secret))
        let text = try bodyText(of: description)

        #expect(description.status == .internalServerError)
        #expect(description.classification == .unexpected)
        #expect(description.diagnostic == Self.secret)
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("db-host-7"))
    }

    @Test("reports storage failures as unavailable without naming the store")
    func storageFailures() throws {
        let description = ErrorMapper.describe(ExecutionFailure.storage(.unavailable(reason: Self.secret)))
        let text = try bodyText(of: description)

        #expect(description.status == .serviceUnavailable)
        #expect(description.classification == .infrastructure)
        #expect(description.diagnostic?.contains("db-host-7") == true)
        #expect(!text.contains("db-host-7"))
    }

    @Test("reports a stored failure with its calculation, and marks a replay")
    func recordedFailures() throws {
        let recorded = RecordedFailure(
            code: .divisionByZero,
            message: "Division by zero is undefined: the divisor must not be zero.",
            details: [RecordedDetail(field: "divisor", reason: "must not be zero")]
        )

        let description = ErrorMapper.describe(
            APIFailure.calculationFailed(recorded, calculationID: RecordFixtures.id(7), replayed: true)
        )
        let json = try body(of: description)

        #expect(description.status == .unprocessableEntity)
        #expect(description.isReplay)
        #expect(description.classification == .expectedDomain)
        #expect(json.at("error", "calculation_id")?.text == RecordFixtures.id(7).description)
        #expect(json.at("error", "details", 0, "field") == "divisor")
    }

    @Test("maps the failures of the HTTP layer")
    func apiFailures() {
        let invalid = ErrorMapper.describe(
            APIFailure.invalidRequest(details: [ErrorDetail(field: "limit", reason: "must be positive")])
        )
        let media = ErrorMapper.describe(APIFailure.unsupportedMediaType)

        #expect(invalid.status == .badRequest)
        #expect(invalid.code == .invalidRequest)
        #expect(invalid.details.map(\.field) == ["limit"])
        #expect(media.status == .unsupportedMediaType)
    }

    @Test(
        "maps the failures Vapor raises and never forwards their reason",
        arguments: [
            (HTTPResponseStatus.notFound, ErrorCode.notFound, HTTPResponseStatus.notFound),
            (.payloadTooLarge, .payloadTooLarge, .payloadTooLarge),
            (.unsupportedMediaType, .unsupportedMediaType, .unsupportedMediaType),
            (.imATeapot, .invalidRequest, .imATeapot),
            (.badGateway, .internalError, .internalServerError),
        ]
    )
    func vaporFailures(raised: HTTPResponseStatus, code: ErrorCode, status: HTTPResponseStatus) throws {
        let description = ErrorMapper.describe(Abort(raised, reason: Self.secret))
        let text = try bodyText(of: description)

        #expect(description.code == code)
        #expect(description.status == status)
        #expect(!text.contains("hunter2"))
    }

    @Test("treats a cancelled task as a cancelled calculation")
    func cancellation() {
        let description = ErrorMapper.describe(CancellationError())

        #expect(description.code == .calculationCancelled)
        #expect(description.status == .serviceUnavailable)
    }

    @Test("turns anything else into an internal error and keeps the cause for the logs")
    func unknownErrors() {
        let description = ErrorMapper.describe(Unrecognised())

        #expect(description.code == .internalError)
        #expect(description.classification == .unexpected)
        #expect(description.diagnostic?.contains("Unrecognised") == true)
    }
}
