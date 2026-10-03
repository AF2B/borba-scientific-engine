import BorbaScientificCore
import Foundation
import Vapor

/// The query parameters of `GET /api/v1/calculations`, by wire name.
enum HistoryParameter: String, CaseIterable {
    case module
    case operation
    case status
    case createdFrom = "created_from"
    case createdBefore = "created_before"
    case limit
    case cursor
}

/// A validated history listing request: what to match and which page to read.
struct HistoryQuery: Sendable, Equatable {
    private static let unknownReason = "is not a recognised query parameter"
    private static let repeatedReason = "must be sent once"
    private static let emptyReason = "must not be empty"
    private static let statusReason =
        "must be one of: \(CalculationStatus.allCases.map(\.rawValue).joined(separator: ", "))"
    private static let timestampReason = "must be an ISO 8601 timestamp, such as 2026-10-03T12:00:00Z"
    private static let limitReason = "must be a whole number between 1 and \(PageRequest.maximumLimit)"
    private static let cursorReason = "is not a cursor returned by this API"
    private static let rangeReason = "must be later than created_from"

    /// What the listed calculations must match.
    let filter: HistoryFilter

    /// Which page to read.
    let page: PageRequest

    /// Validates the query string of a listing request.
    ///
    /// Every problem is collected so a caller can fix the whole request at once. Unknown parameters are rejected: a
    /// misspelled filter would otherwise silently return everything.
    ///
    /// - Parameter items: The query items of the request.
    /// - Returns: The validated query.
    /// - Throws: ``APIFailure/invalidRequest(details:)`` listing every problem.
    static func parse(_ items: [URLQueryItem]) throws(APIFailure) -> HistoryQuery {
        var problems: [ErrorDetail] = []
        let values = collect(items, problems: &problems)

        let filter = HistoryFilter(
            module: values[.module].map(ModuleName.init),
            operation: values[.operation].map(OperationName.init),
            status: parse(values[.status], as: .status, problems: &problems) { CalculationStatus(rawValue: $0) },
            createdFrom: parse(values[.createdFrom], as: .createdFrom, problems: &problems, using: Timestamp.parse),
            createdBefore: parse(
                values[.createdBefore],
                as: .createdBefore,
                problems: &problems,
                using: Timestamp.parse
            )
        )
        let limit = parse(values[.limit], as: .limit, problems: &problems) { text in
            Int(text).flatMap { (1...PageRequest.maximumLimit).contains($0) ? $0 : nil }
        }
        let cursor = parse(values[.cursor], as: .cursor, problems: &problems, using: PageCursorCodec.decode)

        if let from = filter.createdFrom, let before = filter.createdBefore, from >= before {
            problems.append(ErrorDetail(field: HistoryParameter.createdBefore.rawValue, reason: rangeReason))
        }

        guard problems.isEmpty else {
            throw .invalidRequest(details: problems)
        }
        return HistoryQuery(
            filter: filter,
            page: PageRequest(limit: limit ?? PageRequest.defaultLimit, cursor: cursor)
        )
    }

    private static func collect(
        _ items: [URLQueryItem],
        problems: inout [ErrorDetail]
    ) -> [HistoryParameter: String] {
        var values: [HistoryParameter: String] = [:]

        for item in items {
            guard let parameter = HistoryParameter(rawValue: item.name) else {
                problems.append(ErrorDetail(field: item.name, reason: unknownReason))
                continue
            }
            guard let value = item.value, !value.isEmpty else {
                problems.append(ErrorDetail(field: item.name, reason: emptyReason))
                continue
            }
            if values.updateValue(value, forKey: parameter) != nil {
                problems.append(ErrorDetail(field: item.name, reason: repeatedReason))
            }
        }
        return values
    }

    private static func parse<Value>(
        _ text: String?,
        as parameter: HistoryParameter,
        problems: inout [ErrorDetail],
        using convert: (String) -> Value?
    ) -> Value? {
        guard let text else {
            return nil
        }
        guard let value = convert(text) else {
            problems.append(ErrorDetail(field: parameter.rawValue, reason: reason(for: parameter)))
            return nil
        }
        return value
    }

    private static func reason(for parameter: HistoryParameter) -> String {
        switch parameter {
        case .status:
            statusReason
        case .createdFrom, .createdBefore:
            timestampReason
        case .limit:
            limitReason
        case .cursor:
            cursorReason
        case .module, .operation:
            emptyReason
        }
    }
}

extension Request {
    /// Reads and validates the query string of a history listing.
    ///
    /// - Returns: The validated query.
    /// - Throws: ``APIFailure/invalidRequest(details:)`` listing every problem.
    func historyQuery() throws(APIFailure) -> HistoryQuery {
        try HistoryQuery.parse(URLComponents(string: url.string)?.queryItems ?? [])
    }

    /// Reads the calculation identifier of a `/calculations/{id}` path.
    ///
    /// - Returns: The identifier.
    /// - Throws: ``APIFailure/invalidRequest(details:)`` when the path segment is not a UUID.
    func calculationID() throws(APIFailure) -> CalculationID {
        guard
            let text = parameters.get(APIPath.calculationIDName),
            let identifier = UUID(uuidString: text)
        else {
            throw .invalidRequest(
                details: [ErrorDetail(field: APIPath.calculationIDName, reason: "must be a UUID")]
            )
        }
        return CalculationID(identifier)
    }
}
