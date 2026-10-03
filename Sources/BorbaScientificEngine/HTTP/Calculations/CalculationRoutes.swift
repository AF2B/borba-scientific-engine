import BorbaScientificCore
import Vapor

/// The endpoints that run calculations.
///
/// Handlers do three things and nothing else: translate the request into a command, call the use case, translate the
/// outcome into a response. Failures are thrown as typed errors and become responses in ``APIErrorMiddleware``, so no
/// handler chooses a status code.
struct CalculationRoutes: RouteCollection {
    private static let batchLimitName = "batch size"
    private static let emptyBatchReason = "must contain at least one calculation"

    private let service: CalculationService
    private let settings: CalculationSettings
    private let fingerprinter = RequestFingerprinter()

    /// Creates the routes.
    ///
    /// - Parameters:
    ///   - service: Runs and records calculations.
    ///   - settings: Limits of the batch endpoint.
    init(
        service: CalculationService,
        settings: CalculationSettings
    ) {
        self.service = service
        self.settings = settings
    }

    func boot(routes: any RoutesBuilder) throws {
        let calculations = routes.grouped(APIPath.apiRoot, APIPath.version1, APIPath.calculations)

        calculations.post(use: execute)
        calculations.post(APIPath.batch, use: executeBatch)
    }

    // MARK: - Single calculation

    /// Runs one calculation.
    ///
    /// A calculation that runs is recorded and answered with `201 Created`. One that fails while running — a division
    /// by zero, say — is recorded too and answered with an error response that carries its `calculation_id`. A retry
    /// with the same `Idempotency-Key` is answered from the record, with `200 OK` and `Idempotent-Replayed: true`.
    ///
    /// - Parameter request: The incoming request.
    /// - Returns: The recorded calculation.
    /// - Throws: ``APIFailure`` for a malformed request or a calculation that failed, and ``ExecutionFailure`` when the
    ///   calculation was refused, cancelled or could not be recorded.
    @Sendable
    private func execute(_ request: Request) async throws -> Response {
        let body = try request.decodeJSONBody(CalculationRequestBody.self)
        let key = try request.idempotencyKey()
        let command = try makeCommand(for: body, key: key, trace: request.trace)

        let result = try await service.execute(command)
        return try respond(to: result, on: request)
    }

    private func respond(
        to result: ExecutionResult,
        on request: Request
    ) throws -> Response {
        let record = result.record

        if case .failed(let failure) = record.outcome {
            throw APIFailure.calculationFailed(failure, calculationID: record.id, replayed: result.isReplay)
        }

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .location, value: APIPath.location(of: record.id))
        if result.isReplay {
            headers.replaceOrAdd(name: APIHeader.idempotentReplayed, value: APIHeader.replayedValue)
        }

        return try request.jsonResponse(
            CalculationResource(record),
            status: result.isReplay ? .ok : .created,
            headers: headers
        )
    }

    // MARK: - Batch

    /// Runs many calculations concurrently and reports each one independently.
    ///
    /// The batch answers `200 OK` whenever it was understood; one failing calculation never affects the others.
    ///
    /// - Parameter request: The incoming request.
    /// - Returns: One entry per calculation, in request order, and a summary.
    /// - Throws: ``APIFailure`` for a malformed batch and ``ExecutionFailure`` when the batch size is out of range.
    @Sendable
    private func executeBatch(_ request: Request) async throws -> Response {
        let body = try request.decodeJSONBody(BatchRequestBody.self)
        try checkSize(of: body)
        let commands = try makeCommands(for: body, trace: request.trace)

        let outcomes = await service.executeBatch(commands, maximumConcurrency: settings.batchConcurrency)

        let results = outcomes.enumerated().map { index, outcome in
            BatchItemResponse(index: index, outcome: outcome, requestID: request.trace.requestID)
        }
        logUnexpectedFailures(in: outcomes, for: request)

        return try request.jsonResponse(BatchResponse(results: results))
    }

    private func checkSize(of body: BatchRequestBody) throws(ExecutionFailure) {
        if body.calculations.isEmpty {
            throw .rejected(.invalidParameter(BatchRequestBody.calculationsField, reason: Self.emptyBatchReason))
        }
        if body.calculations.count > settings.maximumBatchSize {
            throw .rejected(
                .limitExceeded(LimitExceededError(limit: Self.batchLimitName, maximum: settings.maximumBatchSize))
            )
        }
    }

    private func makeCommands(
        for body: BatchRequestBody,
        trace: TraceContext
    ) throws -> [ExecuteCalculation] {
        var commands: [ExecuteCalculation] = []
        var problems: [ErrorDetail] = []

        for (index, item) in body.calculations.enumerated() {
            var key: IdempotencyKey?
            if let raw = item.idempotencyKey {
                key = IdempotencyKeyPolicy.parse(raw)
                if key == nil {
                    problems.append(
                        ErrorDetail(
                            field: "\(BatchRequestBody.calculationsField)[\(index)].idempotency_key",
                            reason: IdempotencyKeyPolicy.requirement
                        )
                    )
                    continue
                }
            }
            commands.append(try makeCommand(for: item.calculation, key: key, trace: trace))
        }

        guard problems.isEmpty else {
            throw APIFailure.invalidRequest(details: problems)
        }
        return commands
    }

    /// Writes a log line for every outcome that signals a problem on our side. Failures the caller caused are part of
    /// the response and are not logged.
    private func logUnexpectedFailures(
        in outcomes: [Result<ExecutionResult, ExecutionFailure>],
        for request: Request
    ) {
        for case .failure(let failure) in outcomes where failure.classification.isReportable {
            ErrorMapper.describe(failure).log(to: request.logger)
        }
    }

    // MARK: - Shared

    private func makeCommand(
        for body: CalculationRequestBody,
        key: IdempotencyKey?,
        trace: TraceContext
    ) throws -> ExecuteCalculation {
        let calculation = body.calculationRequest
        let claim = try key.map {
            IdempotencyClaim(key: $0, fingerprint: try fingerprinter.fingerprint(of: calculation))
        }

        return ExecuteCalculation(request: calculation, idempotency: claim, trace: trace)
    }
}
