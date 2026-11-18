import Foundation

public struct LibrarySearchResult: Sendable {
    public let hits: [LibrarySearchHit]
    public let status: SemanticSearchStatus
    public let revision: String
    var excerptChunks: [String: [SemanticChunk]] = [:]
}
struct PassageSearchResult {
    let passages: [LibrarySearchPassage]
    let status: SemanticSearchStatus
    let revision: String
    var excerptChunks: [String: [SemanticChunk]] = [:]
}

extension LibrarySearchQuery {
    func matchesQuotes(_ text: String) -> Bool {
        matchesQuotes(in: [text])
    }
    func matchesQuotes(in fields: [String]) -> Bool {
        terms.filter { !$0.prefix }.allSatisfy { term in
            let phrase = LibrarySearchQuery("\"" + term.words.joined(separator: " ") + "\"")
            return fields.contains { phrase.matches($0) }
        }
    }
}

extension LibrarySearchIndex {
    static func sameSpeaker(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
    }
    public var speakerNames: [String] {
        Array(Set(calls.filter { $0.recording.detailsError == nil }.flatMap { call in call.recording.transcripts.flatMap { version in
            (version.document?.paragraphs ?? []).map { call.speaker($0, version: version) }
        } })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private func keywordPassages(_ text: String, allVersions: Bool, allowed: Set<String>, speaker: String?) throws -> [LibrarySearchPassage] {
        guard let speaker, !speaker.isEmpty else { return try passages(text, allVersions: allVersions, allowed: allowed) }
        let query = LibrarySearchQuery(text)
        return calls.filter { allowed.contains($0.id) && $0.recording.detailsError == nil }.flatMap { call in
            (allVersions ? call.recording.transcripts : Array(call.recording.transcripts.prefix(1))).flatMap { version -> [LibrarySearchPassage] in
                let paragraphs = version.document?.paragraphs ?? []
                let selected = paragraphs.filter { Self.sameSpeaker(call.speaker($0, version: version), speaker) }
                guard query.matches(selected.map(\.text).joined(separator: " ") + "\n" + speaker) else { return [] }
                let matches = selected.filter { query.isEmpty || !query.highlightRanges(in: $0.text + " " + speaker).isEmpty }.map(\.id)
                return Self.windows(callID: call.id, versionID: version.id, ids: matches, count: paragraphs.count)
            }
        }
    }
    private static func windows(callID: String, versionID: String, ids: [Int], count: Int) -> [LibrarySearchPassage] {
        var windows: [Range<Int>] = []
        for id in Set(ids).sorted() {
            let range = max(0, id - 1)..<min(count, id + 2)
            if let last = windows.last, last.upperBound >= range.lowerBound { windows[windows.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound) }
            else { windows.append(range) }
        }
        return windows.flatMap { window in stride(from: window.lowerBound, to: window.upperBound, by: 8).compactMap { start in
            let range = start..<min(start + 8, window.upperBound), matches = Set(ids).filter { range.contains($0) }.sorted()
            return matches.isEmpty ? nil : LibrarySearchPassage(callID: callID, versionID: versionID, matchingParagraphs: matches, context: range)
        } }
    }
    func hybridPassages(_ text: String, allVersions: Bool, allowed: Set<String>, speaker: String? = nil, keywordOnly: Bool = false, includeMetadata: Bool = false) throws -> PassageSearchResult {
        let lexical = try keywordPassages(text, allVersions: allVersions, allowed: allowed, speaker: speaker)
        var (status, revision) = semantic.snapshot(allVersions: allVersions)
        guard !keywordOnly, !LibrarySearchQuery(text).isEmpty else { return .init(passages: lexical, status: status, revision: revision + ":keyword") }
        let (candidates, semanticStatus, semanticRevision) = semantic.search(text, allVersions: allVersions)
        status = semanticStatus; revision = semanticRevision
        guard status.mode == "hybrid" else { return .init(passages: lexical, status: status, revision: revision) }
        let byID = Dictionary(uniqueKeysWithValues: calls.filter { allowed.contains($0.id) }.map { ($0.id, $0) })
        let query = LibrarySearchQuery(text)
        var scores: [String: [Int: Double]] = [:]
        var owners: [String: String] = [:]
        var matchingChunks: [String: [SemanticChunk]] = [:]
        for (rank, passage) in lexical.enumerated() {
            owners[passage.versionID] = passage.callID
            for id in passage.matchingParagraphs { scores[passage.versionID, default: [:]][id] = 1.3 / Double(60 + rank + 1) }
        }
        var seen = Set<String>(), rank = 0
        for (chunk, _) in candidates {
            guard case let .call(callID, versionID, _) = chunk.origin, let call = byID[callID], let version = call.recording.transcripts.first(where: { $0.id == versionID }), let paragraphs = version.document?.paragraphs else { continue }
            let eligible = paragraphs.filter { speaker == nil || speaker!.isEmpty || Self.sameSpeaker(call.speaker($0, version: version), speaker!) }
            // Quoted phrases and speaker filters are hard constraints even when
            // the rest of the query is expressed using different words.
            var fields = [eligible.map(\.text).joined(separator: " "), eligible.map { call.speaker($0, version: version) }.joined(separator: " ")]
            if includeMetadata && (speaker == nil || speaker!.isEmpty) {
                let recording = call.recording
                fields += [recording.name, ([recording.sourceName, recording.details.description] + recording.details.participants + recording.details.tags).joined(separator: " ")]
            }
            guard query.matchesQuotes(in: fields) else { continue }
            let ids = chunk.paragraphs.filter { id in eligible.contains { $0.id == id } }
            guard !ids.isEmpty, speaker == nil || speaker!.isEmpty || ids.count == chunk.paragraphs.count else { continue }
            let key = versionID + ":" + ids.map(String.init).joined(separator: ",")
            guard seen.insert(key).inserted else { continue }
            owners[versionID] = callID
            matchingChunks[versionID, default: []].append(chunk)
            for id in ids { scores[versionID, default: [:]][id, default: 0] += 1 / Double(60 + rank + 1) }
            rank += 1
            if rank >= 60 { break }
        }
        var ranked: [(LibrarySearchPassage, Double)] = []
        for (versionID, values) in scores {
            guard let callID = owners[versionID], let call = byID[callID],
                  let paragraphs = call.recording.transcripts.first(where: { $0.id == versionID })?.document?.paragraphs else { continue }
            for var passage in Self.windows(callID: callID, versionID: versionID, ids: Array(values.keys), count: paragraphs.count) {
                // Windows are chronological. Use the strongest independently matched turn
                // for the preview, or the strongest complete exchange when only a group matched.
                let chunks = matchingChunks[versionID, default: []].filter { chunk in
                    chunk.paragraphs.allSatisfy(passage.matchingParagraphs.contains)
                }
                if let best = chunks.first(where: { $0.paragraphs.count == 1 }) ?? chunks.first,
                   let end = best.paragraphs.last {
                    var preview = best.text
                    // Give a short turn its continuation within the same cited evidence.
                    // A partial chunk from a long paragraph must end before the next turn.
                    var next = end + 1
                    if best.text.hasSuffix(paragraphs[end].text) {
                        while preview.count < 260, passage.matchingParagraphs.contains(next) {
                            preview += " " + paragraphs[next].text
                            next += 1
                        }
                    }
                    passage.preview = String(preview.prefix(260))
                }
                ranked.append((passage, passage.matchingParagraphs.compactMap { values[$0] }.max() ?? 0))
            }
        }
        ranked.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            let a = $0.0, b = $1.0
            if a.callID != b.callID { return a.callID < b.callID }
            if a.versionID != b.versionID { return a.versionID < b.versionID }
            return a.context.lowerBound < b.context.lowerBound
        }
        return .init(passages: ranked.map(\.0), status: status, revision: revision, excerptChunks: matchingChunks)
    }
    public func hybridSearch(_ text: String, allVersions: Bool = false, speaker: String? = nil, keywordOnly: Bool = false, recordingIDs: Set<String>? = nil) throws -> LibrarySearchResult {
        let eligible = calls.filter { recordingIDs == nil || recordingIDs!.contains($0.recording.id) }
        let lexical = speaker == nil || speaker!.isEmpty ? try search(text, allVersions: allVersions).filter { recordingIDs == nil || recordingIDs!.contains($0.recordingID) } : []
        let result = try hybridPassages(text, allVersions: allVersions, allowed: Set(eligible.map(\.id)), speaker: speaker, keywordOnly: keywordOnly, includeMetadata: true)
        if result.status.mode == "keyword", speaker == nil || speaker!.isEmpty {
            return .init(hits: lexical, status: result.status, revision: result.revision)
        }
        var byID = Dictionary(uniqueKeysWithValues: lexical.map { ($0.recordingID, $0) })
        var scores = Dictionary(uniqueKeysWithValues: lexical.enumerated().map { ($0.element.recordingID, 1.3 / Double(61 + $0.offset)) })
        let callMap = Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0) })
        var seen = Set<String>()
        for (rank, passage) in result.passages.enumerated() {
            guard let call = callMap[passage.callID], seen.insert(call.recording.id).inserted,
                  let version = call.recording.transcripts.first(where: { $0.id == passage.versionID }), let paragraphs = version.document?.paragraphs else { continue }
            scores[call.recording.id, default: 0] += 1 / Double(61 + rank)
            if byID[call.recording.id] == nil {
                let preview = passage.preview ?? passage.matchingParagraphs.first.map { paragraphs[$0].text }
                byID[call.recording.id] = .init(recordingID: call.recording.id, versionID: passage.versionID, paragraphIDs: passage.matchingParagraphs, snippet: preview.map { String($0.prefix(260)) }, score: scores[call.recording.id]!)
            }
        }
        let hits = byID.values.sorted { a, b in
            if scores[a.recordingID] != scores[b.recordingID] { return scores[a.recordingID, default: 0] > scores[b.recordingID, default: 0] }
            return a.recordingID < b.recordingID
        }
        return .init(hits: hits, status: result.status, revision: result.revision, excerptChunks: result.excerptChunks)
    }
}
