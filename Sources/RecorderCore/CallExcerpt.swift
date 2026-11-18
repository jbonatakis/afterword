import Foundation

struct CallExcerpt {
    static let characterLimit = 260
    let text: String
    let ids: [Int]

    /// Reconstruct from the transcript so the IDs cover only visible words.
    static func semantic(_ chunk: SemanticChunk, paragraphs: [TranscriptParagraph]) -> Self? {
        let ids = chunk.paragraphs
        guard let first = ids.first, ids.allSatisfy(paragraphs.indices.contains) else { return nil }
        if ids.count == 1 {
            let source = paragraphs[first].text
            // Long paragraphs can have independently embedded slices. Locate the
            // opening words of the slice in the original, preserving punctuation.
            let opening = String(chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
            let start = source.range(of: opening)?.lowerBound ?? source.startIndex
            return .init(text: String(source[start...].prefix(characterLimit)), ids: ids)
        }
        var text = "", visible: [Int] = []
        for id in ids {
            let separator = text.isEmpty ? "" : " "
            let room = characterLimit - text.count - separator.count
            guard room > 0 else { break }
            let part = paragraphs[id].text.prefix(room)
            guard !part.isEmpty else { continue }
            text += separator + part
            visible.append(id)
        }
        return visible.isEmpty ? nil : .init(text: text, ids: visible)
    }

    static func select(query: LibrarySearchQuery, lexical: [Self], semantic: [Self]) -> [Self] {
        // Reciprocal-rank fusion within this transcript. A turn found both
        // ways competes with strong hits found by only one retrieval method.
        struct Candidate {
            let excerpt: CallExcerpt
            let quoted: Bool
            var score: Double
            let order: Int
        }
        let hasQuote = query.terms.contains { !$0.prefix }
        var candidates: [[Int]: Candidate] = [:]
        for list in [semantic, lexical] {
            var seen = Set<[Int]>()
            for excerpt in list where seen.insert(excerpt.ids).inserted {
                let score = 1 / Double(4 + seen.count)
                let quoted = hasQuote && query.matchesQuotes(excerpt.text)
                if var previous = candidates[excerpt.ids] {
                    if quoted && !previous.quoted {
                        previous = Candidate(excerpt: excerpt, quoted: true, score: previous.score, order: previous.order)
                    }
                    previous.score += score
                    candidates[excerpt.ids] = previous
                } else {
                    candidates[excerpt.ids] = Candidate(excerpt: excerpt, quoted: quoted, score: score, order: candidates.count)
                }
            }
        }
        let ranked = candidates.values.sorted {
            if $0.quoted != $1.quoted { return $0.quoted }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.order < $1.order
        }
        var result: [Self] = [], used = Set<Int>(), texts = Set<String>()
        for candidate in ranked {
            let excerpt = candidate.excerpt
            guard used.isDisjoint(with: excerpt.ids), texts.insert(excerpt.text).inserted else { continue }
            result.append(excerpt)
            used.formUnion(excerpt.ids)
            if result.count == 3 { break }
        }
        return result
    }
}
