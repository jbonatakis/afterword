import Foundation

/// A deliberately small query language shared by the library and MCP. Words
/// are ANDed and match prefixes as you type; quotes preserve exact words/phrases.
/// An explicit trailing * remains supported, but is no longer required.
/// User input is never passed through as executable FTS syntax.
public struct LibrarySearchQuery: Sendable {
    struct Term: Sendable { let words: [String]; let prefix: Bool }
    let terms: [Term]
    public let isEmpty: Bool
    private static let chunks = try! NSRegularExpression(pattern: #""([^"]*)"?|([^\s"]+)"#)
    private static let words = try! NSRegularExpression(pattern: #"[\p{L}\p{N}\p{Co}_][\p{L}\p{N}\p{M}\p{Co}_]*"#)

    public init(_ text: String) {
        isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let string = text as NSString
        terms = Self.chunks.matches(in: text, range: NSRange(location: 0, length: string.length)).flatMap { match -> [Term] in
            if match.range(at: 1).location != NSNotFound {
                let words = Self.tokens(string.substring(with: match.range(at: 1))).map(\.word)
                return words.isEmpty ? [] : [Term(words: words, prefix: false)]
            }
            let chunk = string.substring(with: match.range(at: 2))
            let words = Self.tokens(chunk).map(\.word)
            return words.map { Term(words: [$0], prefix: true) }
        }
    }
    private static func tokens(_ text: String) -> [(word: String, range: NSRange)] {
        let string = text as NSString
        return words.matches(in: text, range: NSRange(location: 0, length: string.length)).map {
            (string.substring(with: $0.range).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")), $0.range)
        }
    }
    var expression: String? {
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"" + $0.words.joined(separator: " ") + "\"" + ($0.prefix ? "*" : "") }.joined(separator: " AND ")
    }
    // Evidence can span paragraphs or fields. The document query establishes
    // eligibility; this OR query finds the paragraphs contributing its terms.
    var evidenceExpression: String? {
        guard !terms.isEmpty else { return nil }
        return terms.flatMap { term in term.words.enumerated().map {
            "\"" + $0.element + "\"" + (term.prefix && $0.offset == term.words.count - 1 ? "*" : "")
        } }.joined(separator: " OR ")
    }
    public func matches(_ text: String) -> Bool {
        matches(text, allowPrefixes: true)
    }
    func matches(_ text: String, allowPrefixes: Bool) -> Bool {
        if isEmpty { return true }
        let words = Self.tokens(text).map(\.word)
        return !terms.isEmpty && terms.allSatisfy { term in
            guard words.count >= term.words.count else { return false }
            return (0...(words.count - term.words.count)).contains { start in
                term.words.indices.allSatisfy { i in
                    allowPrefixes && term.prefix && i == term.words.count - 1 ? words[start + i].hasPrefix(term.words[i]) : words[start + i] == term.words[i]
                }
            }
        }
    }
    public func highlightRanges(in text: String) -> [NSRange] {
        Self.tokens(text).filter { token in
            terms.contains { term in term.words.enumerated().contains { i, word in
                term.prefix && i == term.words.count - 1 ? token.word.hasPrefix(word) : token.word == word
            } }
        }.map(\.range)
    }
}
