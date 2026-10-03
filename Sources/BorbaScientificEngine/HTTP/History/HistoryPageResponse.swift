import BorbaScientificCore

/// Where a listing stands and how to continue it.
struct PageInfo: Encodable, Sendable, Equatable {
    /// The most entries the page may hold, as requested or defaulted.
    let limit: Int

    /// Token that reads the next page, or `null` when this was the last one.
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case limit
        case nextCursor = "next_cursor"
    }

    /// Writes the cursor explicitly as `null` on the last page, so clients can test for it without guessing whether a
    /// missing key means "no more" or "not supported".
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An encoding error raised by the encoder.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(limit, forKey: .limit)
        try container.encode(nextCursor, forKey: .nextCursor)
    }
}

/// The body of the response to `GET /api/v1/calculations`: one page of the history, newest first.
///
/// ```json
/// { "items": [ { "id": "…", "status": "succeeded" } ], "page": { "limit": 20, "next_cursor": null } }
/// ```
struct HistoryPageResponse: Encodable, Sendable, Equatable {
    /// The calculations of the page, newest first.
    let items: [CalculationResource]

    /// Where the listing stands.
    let page: PageInfo

    /// Presents a page of the history.
    ///
    /// - Parameters:
    ///   - page: The page the history returned.
    ///   - limit: The page size that was requested.
    init(
        page: Page<CalculationRecord>,
        limit: Int
    ) {
        items = page.items.map(CalculationResource.init)
        self.page = PageInfo(limit: limit, nextCursor: page.nextCursor.map(PageCursorCodec.encode))
    }
}
