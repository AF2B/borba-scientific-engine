import BorbaScientificCore

/// The outcome of one calculation of a batch: either the calculation or the reason there is none.
///
/// The `error` has the same shape as the body of an error response, so one parser handles both endpoints. When the
/// calculation ran and failed, `error.calculation_id` points at the recorded calculation in the history.
struct BatchItemResponse: Encodable, Sendable, Equatable {
    /// Position of the calculation in the request.
    let index: Int

    /// The calculation, when it succeeded.
    let calculation: CalculationResource?

    /// Whether the calculation is the stored result of an earlier request with the same idempotency key. Omitted when
    /// the calculation ran now.
    let replayed: Bool?

    /// Why there is no calculation.
    let error: ErrorResponse.Body?

    /// Presents the outcome of one calculation.
    ///
    /// - Parameters:
    ///   - index: Position of the calculation in the request.
    ///   - outcome: What running it produced.
    ///   - requestID: The request that carried the batch, quoted in error bodies.
    init(
        index: Int,
        outcome: Result<ExecutionResult, ExecutionFailure>,
        requestID: RequestID
    ) {
        self.index = index

        switch outcome {
        case .success(let result):
            let record = result.record
            switch record.outcome {
            case .succeeded:
                calculation = CalculationResource(record)
                replayed = result.isReplay ? true : nil
                error = nil
            case .failed(let failure):
                let failureDescription = ErrorMapper.describe(
                    APIFailure.calculationFailed(failure, calculationID: record.id, replayed: result.isReplay)
                )
                calculation = nil
                replayed = nil
                error = failureDescription.response(requestID: requestID).error
            }
        case .failure(let failure):
            calculation = nil
            replayed = nil
            error = ErrorMapper.describe(failure).response(requestID: requestID).error
        }
    }
}

/// How many calculations of a batch succeeded and how many did not.
struct BatchSummary: Encodable, Sendable, Equatable {
    /// Calculations in the batch.
    let total: Int

    /// Calculations that produced a result.
    let succeeded: Int

    /// Calculations that did not, whether they failed while running or were refused beforehand.
    let failed: Int
}

/// The body of the response to `POST /api/v1/calculations/batch`.
///
/// The batch itself succeeds whenever it was understood; whether each calculation did is reported item by item, in the
/// order of the request.
struct BatchResponse: Encodable, Sendable, Equatable {
    /// One entry per calculation of the request, in the same order.
    let results: [BatchItemResponse]

    /// Counts of the results.
    let summary: BatchSummary

    /// Presents the outcomes of a batch.
    ///
    /// - Parameter results: One entry per calculation, in request order.
    init(results: [BatchItemResponse]) {
        let succeeded = results.filter { $0.calculation != nil }.count

        self.results = results
        summary = BatchSummary(total: results.count, succeeded: succeeded, failed: results.count - succeeded)
    }
}

extension ExecutionResult {
    /// Whether the record is the stored result of an earlier identical request.
    var isReplay: Bool {
        switch self {
        case .executed:
            false
        case .replayed:
            true
        }
    }
}
