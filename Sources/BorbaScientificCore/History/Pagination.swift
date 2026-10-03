public import Foundation

/// Narrows the history to the entries a caller is interested in. Every field is optional; absent fields match
/// everything.
public struct HistoryFilter: Sendable, Equatable {
    /// Only calculations of this module.
    public var module: ModuleName?

    /// Only calculations of this operation.
    public var operation: OperationName?

    /// Only calculations with this status.
    public var status: CalculationStatus?

    /// Only calculations recorded at or after this instant.
    public var createdFrom: Date?

    /// Only calculations recorded before this instant.
    public var createdBefore: Date?

    /// Creates a filter.
    ///
    /// - Parameters:
    ///   - module: Only calculations of this module.
    ///   - operation: Only calculations of this operation.
    ///   - status: Only calculations with this status.
    ///   - createdFrom: Only calculations recorded at or after this instant.
    ///   - createdBefore: Only calculations recorded before this instant.
    public init(
        module: ModuleName? = nil,
        operation: OperationName? = nil,
        status: CalculationStatus? = nil,
        createdFrom: Date? = nil,
        createdBefore: Date? = nil
    ) {
        self.module = module
        self.operation = operation
        self.status = status
        self.createdFrom = createdFrom
        self.createdBefore = createdBefore
    }
}

/// The position of the last entry of a page. The next page starts strictly after it.
///
/// Keyset pagination stays correct while rows are being added and stays fast on deep pages, unlike an offset, which
/// shifts under concurrent writes and makes the database skip rows it then throws away.
public struct PageCursor: Sendable, Equatable, Hashable {
    /// When the last entry was recorded.
    public let createdAt: Date

    /// Identifier of the last entry, which breaks ties between entries recorded at the same instant.
    public let id: CalculationID

    /// Creates a cursor.
    ///
    /// - Parameters:
    ///   - createdAt: When the last entry was recorded.
    ///   - id: Identifier of the last entry.
    public init(
        createdAt: Date,
        id: CalculationID
    ) {
        self.createdAt = createdAt
        self.id = id
    }
}

/// Which page of the history to read.
public struct PageRequest: Sendable, Equatable {
    /// Entries returned when the caller does not choose.
    public static let defaultLimit = 20

    /// Most entries a single page may contain.
    public static let maximumLimit = 100

    /// How many entries to return, between 1 and ``maximumLimit``.
    public let limit: Int

    /// Where the previous page ended; `nil` for the first page.
    public let cursor: PageCursor?

    /// Creates a page request, clamping the limit into its valid range.
    ///
    /// - Parameters:
    ///   - limit: How many entries to return.
    ///   - cursor: Where the previous page ended.
    public init(
        limit: Int = PageRequest.defaultLimit,
        cursor: PageCursor? = nil
    ) {
        self.limit = min(max(limit, 1), Self.maximumLimit)
        self.cursor = cursor
    }
}

/// One page of results, newest first.
public struct Page<Element: Sendable>: Sendable {
    /// The entries of the page.
    public let items: [Element]

    /// Where to continue, or `nil` when this was the last page.
    public let nextCursor: PageCursor?

    /// Creates a page.
    ///
    /// - Parameters:
    ///   - items: The entries of the page.
    ///   - nextCursor: Where to continue.
    public init(
        items: [Element],
        nextCursor: PageCursor?
    ) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

extension Page: Equatable where Element: Equatable {}
