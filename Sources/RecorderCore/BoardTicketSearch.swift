import Foundation

public struct BoardCitationFilter: Equatable, Sendable {
    public let source: BoardReference.Source
    public let itemID: String
    public var anchor: String?
    public var versionID: String?

    public init(source: BoardReference.Source, itemID: String, anchor: String? = nil, versionID: String? = nil) {
        self.source = source
        self.itemID = itemID
        self.anchor = anchor
        self.versionID = versionID
    }

    func matches(_ reference: BoardReference) -> Bool {
        reference.source == source && reference.itemID == itemID &&
            (anchor == nil || anchor == reference.anchor) && (versionID == nil || versionID == reference.versionID)
    }
}

public struct BoardTicketQuery: Equatable, Sendable {
    public var text = ""
    public var columnID: String?
    /// An empty string selects unassigned tickets.
    public var swimlaneID: String?
    public var originKey: String?
    public var citation: BoardCitationFilter?
    public init() {}

    public func includesCell(_ ticket: BoardTicket) -> Bool {
        (columnID == nil || columnID == ticket.columnID) && (swimlaneID == nil || swimlaneID == (ticket.swimlaneID ?? ""))
    }
}

public struct BoardTicketHit: Identifiable, Sendable {
    public struct Match: Encodable, Sendable {
        public enum Field: String, Encodable, Sendable { case title, notes, citation }
        public let field: Field
        public let excerpt: String
    }
    public let ticket: BoardTicket
    public let match: Match?
    public let sharedReference: BoardReference?
    public var id: String { ticket.id }
}

/// One owner per board. The text index is built only on search and contains only saved board content.
public final class BoardTicketSearch {
    private var database: SearchDatabase?
    private var indexedTickets: [BoardTicket] = []
    public init() {}

    private func index(_ tickets: [BoardTicket]) throws -> SearchDatabase {
        if let database, indexedTickets == tickets { return database }
        let db = try SearchDatabase()
        try db.execute("CREATE VIRTUAL TABLE cards USING fts5(title, notes, citations, tokenize='porter unicode61 remove_diacritics 2')")
        try db.transaction {
            for ticket in tickets {
                try Task.checkCancellation()
                let citations = ticket.references.map { [$0.label, $0.quote].compactMap { $0 }.joined(separator: " — ") }
                try db.execute("INSERT INTO cards(title,notes,citations) VALUES(?,?,?)", [ticket.title, ticket.notes, citations.joined(separator: "\n")])
            }
        }
        indexedTickets = tickets
        database = db
        return db
    }

    public func results(on board: TaskBoard, for query: BoardTicketQuery) throws -> [BoardTicketHit] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = LibrarySearchQuery(text)
        var ranks: [Int: (tier: Int, weight: Double, match: BoardTicketHit.Match)] = [:]
        if parsed.terms.count <= 64, let expression = parsed.expression {
            let db = try index(board.tickets)
            // Relax one unquoted term in a short multi-word query. Keeping at least two terms
            // avoids suggesting every ticket containing just "fix" or "update".
            var expressions = [expression]
            if (3...8).contains(parsed.terms.count), parsed.terms.allSatisfy(\.prefix) {
                let terms = parsed.terms.map(\.expression)
                let alternatives = terms.indices.map { skip in terms.enumerated().compactMap { $0.offset == skip ? nil : $0.element }.joined(separator: " AND ") }
                expressions.append(alternatives.map { "(" + $0 + ")" }.joined(separator: " OR "))
            }
            for (index, expression) in expressions.enumerated() {
                try Task.checkCancellation()
                let rows = try db.rows("""
                    SELECT rowid, bm25(cards, 8, 3, 1),
                      CASE snippet(cards,-1,'','','…',20)
                        WHEN snippet(cards,0,'','','…',20) THEN 'title'
                        WHEN snippet(cards,1,'','','…',20) THEN 'notes' ELSE 'citation' END,
                      snippet(cards,-1,'','','…',20)
                    FROM cards WHERE cards MATCH ?
                    """, [expression])
                for row in rows {
                    guard let rowID = Int(row[0]), let field = BoardTicketHit.Match.Field(rawValue: row[2]), ranks[rowID] == nil else { continue }
                    ranks[rowID] = (index + 1, Double(row[1]) ?? 0, .init(field: field, excerpt: String(row[3].prefix(260))))
                }
            }
        }

        var hits: [(hit: BoardTicketHit, tier: Int, weight: Double, order: Int)] = []
        for (offset, ticket) in board.tickets.enumerated() {
            try Task.checkCancellation()
            guard query.includesCell(ticket), query.originKey == nil || query.originKey == ticket.originKey else { continue }
            let reference = query.citation.flatMap { filter in ticket.references.first(where: filter.matches) }
            guard query.citation == nil || reference != nil else { continue }
            var rank = ranks[offset + 1]
            if !text.isEmpty {
                // Preserve literal substring searches, including punctuation and partial identifiers.
                if let match = Self.literal(text, in: ticket.title, field: .title) {
                    rank = (0, rank?.weight ?? 0, match)
                } else if (rank?.tier ?? Int.max) > 1, let match = Self.literal(text, in: ticket.notes, field: .notes) {
                    rank = (1, 0, match)
                }
                guard rank != nil else { continue }
            }
            hits.append((.init(ticket: ticket, match: rank?.match, sharedReference: reference), rank?.tier ?? 0, rank?.weight ?? 0, offset))
        }
        if !text.isEmpty {
            hits.sort { ($0.tier, $0.weight, $0.order) < ($1.tier, $1.weight, $1.order) }
        }
        return hits.map(\.hit)
    }

    private static func literal(_ text: String, in fieldText: String, field: BoardTicketHit.Match.Field) -> BoardTicketHit.Match? {
        guard let range = fieldText.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = fieldText.index(range.lowerBound, offsetBy: -48, limitedBy: fieldText.startIndex) ?? fieldText.startIndex
        let end = fieldText.index(start, offsetBy: 200, limitedBy: fieldText.endIndex) ?? fieldText.endIndex
        let excerpt = (start == fieldText.startIndex ? "" : "…") + fieldText[start..<end] + (end == fieldText.endIndex ? "" : "…")
        return .init(field: field, excerpt: excerpt)
    }
}
