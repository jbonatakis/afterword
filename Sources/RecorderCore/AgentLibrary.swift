import Foundation
import CoreFoundation

struct AgentCall {
    let recording: LibraryRecording
    let id: String
    let revision: String
    init(recording: LibraryRecording, id: String, revision: String) {
        self.recording = recording; self.id = id; self.revision = revision
    }
    init(recording: LibraryRecording, id: String) throws {
        var payload: [String: Any] = ["title": recording.name, "date": AgentJSON.date(recording.date),
            "details": try AgentJSON.object(recording.details), "information_readable": recording.detailsError == nil]
        payload["speaker_display_names"] = recording.directoryLabels
        payload["duration"] = recording.duration
        if let summary = recording.summary { payload["summary"] = try AgentJSON.object(summary) }
        payload["summary_readable"] = recording.summaryError == nil
        payload["versions"] = try recording.transcripts.map { version -> [String: Any] in
            var item: [String: Any] = ["id": version.runName, "date": AgentJSON.date(version.date), "readable": version.document != nil]
            if let document = version.document { item["document"] = try AgentJSON.object(document) }
            return item
        }
        self.init(recording: recording, id: id, revision: AgentJSON.hash(try AgentJSON.data(payload)))
    }
    func versionID(_ version: LibraryTranscript) -> String { AgentJSON.hash(id + "/" + version.runName) }
    func versionInfo(_ version: LibraryTranscript) -> [String: Any] {
        ["version_id": versionID(version), "created_at": AgentJSON.date(version.date),
         "edited": version.document?.editing != nil, "readable": version.document != nil]
    }
    var summary: [String: Any] {
        var value: [String: Any] = ["call_id": id, "revision": revision, "title": recording.name,
            "recorded_at": AgentJSON.date(recording.date), "participants": recording.participantDisplayNames,
            "tags": recording.details.tags, "has_transcript": recording.hasTranscript,
            "has_summary": recording.summary?.current != nil, "summary_readable": recording.summaryError == nil,
            "information_readable": recording.detailsError == nil]
        value["duration_seconds"] = recording.duration
        value["latest_version"] = recording.latestTranscript.map(versionInfo)
        return value
    }
    func speaker(_ paragraph: TranscriptParagraph, version: LibraryTranscript) -> String {
        recording.speakerLabel(for: paragraph, version: version)
    }
    func summaryInfo(_ version: CallSummaryVersion, includeText: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["revision_id": version.id, "created_at": AgentJSON.date(version.createdAt),
                                   "author": version.author, "source_changed": version.sourceChanged(in: recording)]
        if let run = version.sourceTranscript { result["source_version_id"] = AgentJSON.hash(id + "/" + run) }
        if includeText { result["markdown"] = version.markdown }
        return result
    }
    func paragraph(_ paragraph: TranscriptParagraph, version: LibraryTranscript) -> [String: Any] {
        let speaker = speaker(paragraph, version: version)
        return ["paragraph_id": paragraph.id, "speaker": speaker, "source": paragraph.source.rawValue,
                "start_seconds": paragraph.start, "end_seconds": paragraph.end, "text": paragraph.text,
                "reference": "\(recording.name) · \(AgentJSON.date(recording.date)) · \(speaker) · \(Transcript.timestamp(paragraph.start))"]
    }
}

/// Exposes only saved content. Never accepts a caller-supplied filesystem path.
public final class AgentLibrary {
    private var index: LibrarySearchIndex?
    private var indexedFolders: [String]?
    public let directory: URL
    private var peopleURL: URL { directory.deletingLastPathComponent().appendingPathComponent("People.json") }
    public init(directory: URL = AgentAccessStore.directory) { self.directory = directory }

    public func call(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        try AgentTools.validate(name, arguments: arguments)
        let configuration = try AgentAccessStore.load(directory: directory)
        guard configuration.enabled else {
            index?.stopSemanticSearch(); index = nil; indexedFolders = nil
            throw AgentFailure("Agent access is disabled. Enable it in Afterword Settings → Agent Access.")
        }
        let roots = configuration.folders.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        guard roots.allSatisfy({ $0 == $0.resolvingSymlinksInPath().standardizedFileURL }) else {
            throw AgentFailure("An allowed folder was replaced by a symbolic link. Review Agent Access settings.")
        }
        let scope = AgentJSON.hash(try AgentJSON.data(configuration.folders.sorted()))
        if indexedFolders != configuration.folders {
            index?.stopSemanticSearch()
            index = try LibrarySearchIndex(roots: roots, confined: true,
                directory: directory == AgentAccessStore.directory ? LibrarySearchIndex.cacheDirectory : directory.appendingPathComponent("Search"),
                embeddingDirectory: directory == AgentAccessStore.directory ? EmbeddingSettings.directory : directory.appendingPathComponent("Embeddings"), peopleURL: peopleURL)
            indexedFolders = configuration.folders
        }
        guard let index else { throw AgentFailure("Search index is unavailable. Retry.") }
        do { try index.synchronize() }
        catch { throw AgentFailure("An allowed folder could not be indexed completely. Check folder availability and file permissions, then retry. No change checkpoint was advanced.") }
        let calls = index.calls
        let revisions = Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0.revision) })
        let libraryRevision = AgentJSON.hash(try AgentJSON.data(revisions))
        let args = AgentArguments(arguments)
        var result: [String: Any]
        switch name {
        case "list_calls":
            var searchRevision = libraryRevision
            var searchStatus = index.semanticStatus(allVersions: args.bool("all_versions"))
            var matchingHits: [String: LibrarySearchHit] = [:]
            var filtered = try filtered(calls, args: args)
            if args.string("query") != nil || args.string("speaker") != nil {
                let search = try index.hybridSearch(args.string("query") ?? "", allVersions: args.bool("all_versions"), speaker: args.string("speaker"), keywordOnly: args.string("mode") == "keyword", recordingIDs: Set(filtered.map { $0.recording.id }))
                let hits = search.hits; searchStatus = search.status
                matchingHits = Dictionary(uniqueKeysWithValues: hits.map { ($0.recordingID, $0) })
                searchRevision = AgentJSON.hash(libraryRevision + search.revision)
                let positions = Dictionary(uniqueKeysWithValues: hits.enumerated().map { ($0.element.recordingID, $0.offset) })
                filtered = filtered.filter { positions[$0.recording.id] != nil }.sorted { positions[$0.recording.id]! < positions[$1.recording.id]! }
            }
            try args.checkRevision(searchRevision)
            result = try page(filtered, args: args) { call in
                var item = call.summary
                if let hit = matchingHits[call.recording.id], let snippet = hit.snippet {
                    item["match_source"] = hit.summaryMatch ? "summary" : "transcript"
                    item["match_text"] = snippet
                }
                return item
            }
            result["library_revision"] = searchRevision
            result["search_status"] = try AgentJSON.object(searchStatus)
        case "get_call":
            let call = try find(calls, args: args); try args.checkRevision(call.revision)
            result = call.summary
            result["description"] = call.recording.details.description
            result["versions"] = call.recording.transcripts.map(call.versionInfo)
            let summaryVersions = call.recording.summary?.versions ?? []
            let selectedSummary = args.string("summary_revision_id").flatMap { id in summaryVersions.first { $0.id == id } } ?? (args.string("summary_revision_id") == nil ? summaryVersions.first : nil)
            if args.string("summary_revision_id") != nil && selectedSummary == nil { throw AgentFailure("Summary version not found. Read get_call for available summary_versions.") }
            result["summary"] = selectedSummary.map { call.summaryInfo($0, includeText: true) } ?? NSNull() as Any
            let summaryPage = try page(summaryVersions, args: AgentArguments(["offset": args.integer("summary_offset", default: 0), "limit": args.integer("summary_limit", default: 40)])) { call.summaryInfo($0) }
            result["summary_versions"] = summaryPage["items"]
            result["summary_version_count"] = summaryPage["total"]
            result["next_summary_offset"] = summaryPage["next_offset"]
            result["attendees"] = call.recording.details.callAttendees.map {
                ["name": call.recording.displayName($0.name), "kind": $0.kind.rawValue, "attendance": $0.attendance.rawValue]
            }
        case "get_transcript":
            let call = try find(calls, args: args); try args.checkRevision(call.revision)
            guard call.recording.detailsError == nil else { throw AgentFailure("Call information is unreadable. Repair it in the library before retrieving resolved speakers.") }
            let versionID = args.string("version_id")
            guard let version = versionID.flatMap({ id in call.recording.transcripts.first { call.versionID($0) == id } }) ?? (versionID == nil ? call.recording.latestTranscript : nil) else {
                throw AgentFailure("Transcript version not found. Use get_call to list available versions.")
            }
            guard let document = version.document else { throw AgentFailure("The selected transcript is unreadable. Use get_call to choose another saved version.") }
            var paragraphs = document.paragraphs
            if let start = args.number("start_seconds") { paragraphs = paragraphs.filter { $0.end >= start } }
            if let end = args.number("end_seconds") { paragraphs = paragraphs.filter { $0.start <= end } }
            if let start = args.number("start_seconds"), let end = args.number("end_seconds"), start > end { throw AgentFailure("start_seconds must not exceed end_seconds.") }
            result = try page(paragraphs, args: args) { call.paragraph($0, version: version) }
            result["call"] = call.summary; result["version"] = call.versionInfo(version)
        case "search_transcripts":
            let query = args.string("query")!
            guard LibrarySearchQuery(query).expression != nil else { throw AgentFailure("query must contain a word or phrase.") }
            let filtered = try filtered(calls, args: args)
            let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
            let search = try index.hybridPassages(query, allVersions: args.bool("all_versions"), allowed: Set(byID.keys), speaker: args.string("speaker"), keywordOnly: args.string("mode") == "keyword")
            let searchRevision = AgentJSON.hash(libraryRevision + search.revision)
            try args.checkRevision(searchRevision)
            let passages = search.passages
            let offset = args.integer("offset", default: 0), limit = args.integer("limit", default: 40)
            guard offset <= passages.count else { throw AgentFailure("offset exceeds the number of results. Restart pagination.") }
            let end = min(passages.count, offset + limit)
            var paragraphsByVersion: [String: [TranscriptParagraph]] = [:]
            let items = passages[offset..<end].compactMap { passage -> [String: Any]? in
                guard let call = byID[passage.callID], let version = call.recording.transcripts.first(where: { $0.id == passage.versionID }), let document = version.document else { return nil }
                let paragraphs: [TranscriptParagraph]
                if let cached = paragraphsByVersion[version.id] { paragraphs = cached }
                else { paragraphs = document.paragraphs; paragraphsByVersion[version.id] = paragraphs }
                return ["call": call.summary, "version": call.versionInfo(version),
                    "match": call.paragraph(paragraphs[passage.matchingParagraphs[0]], version: version),
                    "matches": passage.matchingParagraphs.map { call.paragraph(paragraphs[$0], version: version) },
                    "context": passage.context.map { call.paragraph(paragraphs[$0], version: version) }]
            }
            result = ["items": items, "total": passages.count, "library_revision": searchRevision, "search_status": try AgentJSON.object(search.status)]
            if end < passages.count { result["next_offset"] = end }
            result["unreadable_call_ids"] = filtered.filter { call in
                let versions = args.bool("all_versions") ? call.recording.transcripts : Array(call.recording.transcripts.prefix(1))
                return call.recording.detailsError != nil || versions.contains { $0.document == nil }
            }.map(\.id).sorted()
        case "save_call_summary":
            guard configuration.allowSummaryWrites else { throw AgentFailure("Summary writes are disabled. Enable Allow agents to save summaries in Afterword Settings → Agent Access.") }
            let call = try find(calls, args: args); try args.checkRevision(call.revision)
            guard call.recording.detailsError == nil,
                  let version = call.recording.transcripts.first(where: { call.versionID($0) == args.string("source_version_id") }), version.document != nil else {
                throw AgentFailure("A readable source transcript is required. Read get_transcript before saving a summary.")
            }
            let saved = try CallSummaryStore.save(args.string("markdown")!, for: call.recording, source: version, author: "agent", peopleURL: peopleURL) {
                guard try AgentAccessStore.load(directory: self.directory) == configuration,
                      roots.allSatisfy({ $0 == $0.resolvingSymlinksInPath().standardizedFileURL }),
                      roots.contains(where: { CallFileOperations.contains($0, call.recording.url) }),
                      try AgentJSON.identity(call.recording.url) == call.id else {
                    throw AgentFailure("Access or the call changed before saving. Read the call again before retrying.")
                }
            }
            var updated = call.recording; updated.summary = saved
            let updatedCall = try AgentCall(recording: updated, id: call.id)
            result = ["call": updatedCall.summary, "summary": updatedCall.summaryInfo(saved.current!, includeText: true)]
        case "get_changes":
            result = try AgentCheckpoints(directory: directory).changes(current: revisions, scope: scope,
                cursor: args.string("cursor"), pageToken: args.string("page_token"), limit: args.integer("limit", default: 40))
        default: throw AgentFailure("Unknown tool.")
        }
        // A running client loses access on its next request without needing to restart.
        guard try name == "save_call_summary" || AgentAccessStore.load(directory: directory) == configuration else {
            index.stopSemanticSearch()
            throw AgentFailure("Agent access settings changed during this request. Retry.")
        }
        guard try AgentJSON.data(result).count <= 1_048_576 else {
            throw AgentFailure("Result exceeds 1 MiB. Request a smaller limit or a narrower search.")
        }
        return result
    }
    private func find(_ calls: [AgentCall], args: AgentArguments) throws -> AgentCall {
        guard let call = calls.first(where: { $0.id == args.string("call_id") }) else { throw AgentFailure("Call not found in the allowed folders.") }
        return call
    }
    private func filtered(_ calls: [AgentCall], args: AgentArguments) throws -> [AgentCall] {
        let from = try args.date("from"), to = try args.date("to")
        if let from, let to, from > to { throw AgentFailure("from must not be after to.") }
        return calls.filter { call in
            let value = call.recording
            if let from, value.date < from { return false }
            if let to, value.date >= to { return false }
            if let person = args.string("participant"), !(value.participantDisplayNames + value.details.participants).contains(where: { $0.localizedStandardContains(person) }) { return false }
            if let tag = args.string("tag"), !value.details.tags.contains(where: { $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) { return false }
            return true
        }
    }
    private func page<T>(_ items: [T], args: AgentArguments, transform: (T) -> [String: Any]) throws -> [String: Any] {
        let offset = args.integer("offset", default: 0), limit = args.integer("limit", default: 40)
        guard offset <= items.count else { throw AgentFailure("offset exceeds the number of results. Restart pagination.") }
        let end = min(items.count, offset + limit)
        var result: [String: Any] = ["items": items[offset..<end].map(transform), "total": items.count]
        if end < items.count { result["next_offset"] = end }
        return result
    }
}

struct AgentArguments {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
    func string(_ key: String) -> String? { value[key] as? String }
    func bool(_ key: String) -> Bool { value[key] as? Bool ?? false }
    func number(_ key: String) -> Double? { (value[key] as? NSNumber)?.doubleValue }
    func integer(_ key: String, default fallback: Int) -> Int { (value[key] as? NSNumber)?.intValue ?? fallback }
    func checkRevision(_ revision: String) throws {
        if let expected = string("expected_revision"), expected != revision { throw AgentFailure("Content changed. Restart retrieval with the current revision.") }
    }
    func date(_ key: String) throws -> Date? {
        guard let text = string(key) else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let date = formatter.date(from: text) else { throw AgentFailure("\(key) must be an ISO 8601 date and time with a timezone.") }
        return date
    }
}
