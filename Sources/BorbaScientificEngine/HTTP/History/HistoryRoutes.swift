import BorbaScientificCore
import Vapor

/// The endpoints that read the calculation history.
struct HistoryRoutes: RouteCollection {
    private let history: CalculationHistory

    /// Creates the routes.
    ///
    /// - Parameter history: Reads the stored calculations.
    init(history: CalculationHistory) {
        self.history = history
    }

    func boot(routes: any RoutesBuilder) throws {
        let calculations = routes.grouped(APIPath.apiRoot, APIPath.version1, APIPath.calculations)

        calculations.get(use: list)
        calculations.get(.parameter(APIPath.calculationIDName), use: find)
    }

    /// Lists calculations, newest first, one page at a time.
    ///
    /// - Parameter request: The incoming request; the query string filters and pages the listing.
    /// - Returns: A page of calculations and the cursor of the next one.
    /// - Throws: ``APIFailure`` for a malformed query and ``HistoryFailure`` when the history cannot be read.
    @Sendable
    private func list(_ request: Request) async throws -> Response {
        let query = try request.historyQuery()
        let page = try await history.calculations(matching: query.filter, page: query.page)

        return try request.jsonResponse(HistoryPageResponse(page: page, limit: query.page.limit))
    }

    /// Returns one calculation, whether it succeeded or failed.
    ///
    /// - Parameter request: The incoming request; the path carries the calculation identifier.
    /// - Returns: The calculation.
    /// - Throws: ``APIFailure`` for a malformed identifier and ``HistoryFailure`` when it is unknown or unreadable.
    @Sendable
    private func find(_ request: Request) async throws -> Response {
        let record = try await history.calculation(id: try request.calculationID())

        return try request.jsonResponse(CalculationResource(record))
    }
}
