import Foundation
import CoreFoundation

struct AgentCall {
    let recording: LibraryRecording
    let id: String
    let revision: String
    func versionID(_ version: LibraryTranscript) -> String { AgentJSON.hash(id + "/" + version.runName) }
    func versionInfo(_ version: LibraryTranscript) -> [String: Any] {
        ["version_id": versionID(version), "created_at": AgentJSON.date(version.date),
         "edited": version.document?.editing != nil, "readable": version.document != nil]
    }
    var summary: [String: Any] {
        var value: [String: Any] = ["call_id": id, "revision": revision, "title": recording.name,
            "recorded_at": AgentJSON.date(recording.date), "participants": recording.details.participants,
            "tags": recording.details.tags, "has_transcript": recording.hasTranscript,
            "information_readable": recording.detailsError == nil]
        value["duration_seconds"] = recording.duration
        value["latest_version"] = recording.latestTranscript.map(versionInfo)
        return value
    }
    func speaker(_ paragraph: TranscriptParagraph, version: LibraryTranscript) -> String {
        // "You" would refer to the agent or reader outside the recorder UI.
        paragraph.source == .microphone ? "Recorder" : recording.speakerLabel(for: paragraph, version: version)
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
    public let directory: URL
    public init(directory: URL = AgentAccessStore.directory) { self.directory = directory }

    public func call(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        try AgentTools.validate(name, arguments: arguments)
        let configuration = try AgentAccessStore.load(directory: directory)
        guard configuration.enabled else { throw AgentFailure("Agent access is disabled. Enable it in Call Recorder Settings → Agent Access.") }
        let roots = configuration.folders.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        guard roots.allSatisfy({ $0 == $0.resolvingSymlinksInPath().standardizedFileURL }) else {
            throw AgentFailure("An allowed folder was replaced by a symbolic link. Review Agent Access settings.")
        }
        let scope = AgentJSON.hash(try AgentJSON.data(configuration.folders.sorted()))
        let scan = RecordingLibraryScanner.scan(roots: roots, confined: true)
        guard scan.issues.isEmpty else {
            throw AgentFailure("An allowed folder could not be scanned completely. Check folder availability and file permissions, then retry. No change checkpoint was advanced.")
        }
        var seen = Set<String>()
        let calls = try scan.recordings.compactMap { recording -> AgentCall? in
            let id = try AgentJSON.identity(recording.url)
            guard seen.insert(id).inserted else { return nil }
            // Fingerprint the saved data used for resolution, not just file timestamps.
            var payload: [String: Any] = ["title": recording.name, "date": AgentJSON.date(recording.date),
                "details": try AgentJSON.object(recording.details), "information_readable": recording.detailsError == nil]
            payload["duration"] = recording.duration
            payload["versions"] = try recording.transcripts.map { version -> [String: Any] in
                var item: [String: Any] = ["id": version.runName, "date": AgentJSON.date(version.date), "readable": version.document != nil]
                if let document = version.document { item["document"] = try AgentJSON.object(document) }
                return item
            }
            return AgentCall(recording: recording, id: id, revision: AgentJSON.hash(try AgentJSON.data(payload)))
        }
        let revisions = Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0.revision) })
        let libraryRevision = AgentJSON.hash(try AgentJSON.data(revisions))
        let args = AgentArguments(arguments)
        var result: [String: Any]
        switch name {
        case "list_calls":
            try args.checkRevision(libraryRevision)
            let filtered = try filtered(calls, args: args)
            result = try page(filtered.map(\.summary), args: args)
            result["library_revision"] = libraryRevision
        case "get_call":
            let call = try find(calls, args: args); try args.checkRevision(call.revision)
            result = call.summary
            result["description"] = call.recording.details.description
            result["versions"] = call.recording.transcripts.map(call.versionInfo)
            result["attendees"] = call.recording.details.callAttendees.map {
                ["name": $0.name, "kind": $0.kind.rawValue, "attendance": $0.attendance.rawValue]
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
            result = try page(paragraphs.map { call.paragraph($0, version: version) }, args: args)
            result["call"] = call.summary; result["version"] = call.versionInfo(version)
        case "search_transcripts":
            try args.checkRevision(libraryRevision)
            let query = args.string("query")!.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw AgentFailure("query must not be empty.") }
            var matches: [[String: Any]] = [], unreadable = Set<String>()
            for call in try filtered(calls, args: args, filterQuery: false) {
                if call.recording.detailsError != nil { unreadable.insert(call.id); continue }
                let versions = args.bool("all_versions") ? call.recording.transcripts : Array(call.recording.transcripts.prefix(1))
                for version in versions {
                    guard let document = version.document else { unreadable.insert(call.id); continue }
                    let paragraphs = document.paragraphs
                    for (index, paragraph) in paragraphs.enumerated() where paragraph.text.localizedStandardContains(query) || call.speaker(paragraph, version: version).localizedStandardContains(query) {
                        let context = max(0, index - 1)...min(paragraphs.count - 1, index + 1)
                        matches.append(["call": call.summary, "version": call.versionInfo(version),
                            "match": call.paragraph(paragraph, version: version),
                            "context": context.map { call.paragraph(paragraphs[$0], version: version) }])
                    }
                }
            }
            result = try page(matches, args: args); result["library_revision"] = libraryRevision
            result["unreadable_call_ids"] = unreadable.sorted()
        case "get_changes":
            result = try AgentCheckpoints(directory: directory).changes(current: revisions, scope: scope,
                cursor: args.string("cursor"), pageToken: args.string("page_token"), limit: args.integer("limit", default: 40))
        default: throw AgentFailure("Unknown tool.")
        }
        // A running client loses access on its next request without needing to restart.
        guard try AgentAccessStore.load(directory: directory) == configuration else {
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
    private func filtered(_ calls: [AgentCall], args: AgentArguments, filterQuery: Bool = true) throws -> [AgentCall] {
        let from = try args.date("from"), to = try args.date("to")
        if let from, let to, from > to { throw AgentFailure("from must not be after to.") }
        return calls.filter { call in
            let value = call.recording
            if let from, value.date < from { return false }
            if let to, value.date >= to { return false }
            if let person = args.string("participant"), !value.details.participants.contains(where: { $0.localizedStandardContains(person) }) { return false }
            if let tag = args.string("tag"), !value.details.tags.contains(where: { $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) { return false }
            if filterQuery, let query = args.string("query"), !value.matches(query) { return false }
            return true
        }
    }
    private func page(_ items: [[String: Any]], args: AgentArguments) throws -> [String: Any] {
        let offset = args.integer("offset", default: 0), limit = args.integer("limit", default: 40)
        guard offset <= items.count else { throw AgentFailure("offset exceeds the number of results. Restart pagination.") }
        let end = min(items.count, offset + limit)
        var result: [String: Any] = ["items": Array(items[offset..<end]), "total": items.count]
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
