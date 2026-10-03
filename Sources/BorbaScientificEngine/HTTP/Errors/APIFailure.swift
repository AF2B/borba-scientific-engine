import BorbaScientificCore

/// A failure the HTTP layer reports itself, as opposed to one the engine or the history reports.
enum APIFailure: Error, Sendable, Equatable {
    /// The request is malformed in a way the caller can fix. The details name every offending field, header or
    /// query parameter.
    case invalidRequest(details: [ErrorDetail])

    /// The body is not JSON.
    case unsupportedMediaType

    /// A calculation ran and failed, for example because of a division by zero. The failure is part of the history,
    /// so the response carries the calculation identifier.
    ///
    /// - Parameters:
    ///   - failure: What was recorded.
    ///   - calculationID: Identifier of the recorded calculation.
    ///   - replayed: Whether the stored failure of an earlier identical request is being returned.
    case calculationFailed(RecordedFailure, calculationID: CalculationID, replayed: Bool)
}
