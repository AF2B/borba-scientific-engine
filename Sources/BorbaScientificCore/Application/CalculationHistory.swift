/// Why a history query failed.
public enum HistoryFailure: Error, Sendable, Equatable {
    /// No calculation has this identifier.
    case notFound(CalculationID)

    /// The history could not be read.
    case storage(RepositoryError)

    /// Stable identifier of the failure.
    public var code: ErrorCode {
        switch self {
        case .notFound:
            .calculationNotFound
        case .storage(let error):
            error.code
        }
    }

    /// Explanation that is safe to show to the caller.
    public var message: String {
        switch self {
        case .notFound:
            "No calculation with this identifier exists."
        case .storage(let error):
            error.message
        }
    }

    /// How logging, metrics and error reporting should treat the failure.
    public var classification: ErrorClassification {
        switch self {
        case .notFound:
            .application
        case .storage(let error):
            error.classification
        }
    }
}

extension ErrorCode {
    /// The requested calculation does not exist.
    public static let calculationNotFound = ErrorCode("CALCULATION_NOT_FOUND")
}

/// Reads the calculation history.
///
/// Queries are kept apart from ``CalculationService`` because they have no side effects, never touch the engine, and
/// are the part of the system that can be scaled out or cached independently.
public struct CalculationHistory: Sendable {
    private let repository: any CalculationRepository

    /// Creates the query service.
    ///
    /// - Parameter repository: The stored history.
    public init(repository: any CalculationRepository) {
        self.repository = repository
    }

    /// Finds one calculation.
    ///
    /// - Parameter id: The identifier of the calculation.
    /// - Returns: The record.
    /// - Throws: ``HistoryFailure/notFound(_:)`` when no such calculation exists and
    ///   ``HistoryFailure/storage(_:)`` when the store fails.
    public func calculation(id: CalculationID) async throws(HistoryFailure) -> CalculationRecord {
        let record: CalculationRecord?
        do {
            record = try await repository.find(id: id)
        } catch {
            throw .storage(error)
        }

        guard let record else {
            throw .notFound(id)
        }
        return record
    }

    /// Lists calculations, newest first.
    ///
    /// - Parameters:
    ///   - filter: Narrows the calculations considered.
    ///   - page: Which page to read.
    /// - Returns: The page, with a cursor when more calculations follow.
    /// - Throws: ``HistoryFailure/storage(_:)`` when the store fails.
    public func calculations(
        matching filter: HistoryFilter,
        page: PageRequest
    ) async throws(HistoryFailure) -> Page<CalculationRecord> {
        do {
            return try await repository.list(matching: filter, page: page)
        } catch {
            throw .storage(error)
        }
    }
}
