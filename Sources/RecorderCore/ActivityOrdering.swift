import Foundation

public struct ActivityMatch: Sendable {
    public enum Source: Int, Sendable { case call, coding, github }
    public let id: String
    let source: Source
    let title, evidence: String
    let date: Date?
    let qualified: Bool
    public init(id: String, source: Source, title: String, evidence: String, date: Date?, qualified: Bool = false) {
        self.id = id
        self.source = source
        self.title = title
        self.evidence = evidence
        self.date = date
        self.qualified = qualified
    }
    // Preserve the source's result order inside a relevance tier, and rotate
    // between sources at the same rank. Browsing uses the user's activity date.
    public static func ordered(_ groups: [[Self]], query: String) -> [Self] {
        let parsed = LibrarySearchQuery(query)
        let ranked = groups.flatMap { group in
            var ranks: [Int: Int] = [:]
            return group.map { item -> (Self, Int, Int) in
                let strong =
                    !parsed.isEmpty
                    && (parsed.matches(item.title, allowPrefixes: false)
                        || (parsed.terms.contains(where: { !$0.prefix }) && parsed.matchesQuotes(item.evidence)))
                let tier = item.qualified ? 0 : strong ? 1 : 2
                let rank = ranks[tier, default: 0]
                ranks[tier] = rank + 1
                return (item, tier, rank)
            }
        }
        return ranked.sorted { lhs, rhs in
            if parsed.isEmpty {
                if lhs.0.date != rhs.0.date { return (lhs.0.date ?? .distantPast) > (rhs.0.date ?? .distantPast) }
            } else {
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            }
            if lhs.0.source != rhs.0.source { return lhs.0.source.rawValue < rhs.0.source.rawValue }
            return lhs.0.id < rhs.0.id
        }.map { $0.0 }
    }
}
