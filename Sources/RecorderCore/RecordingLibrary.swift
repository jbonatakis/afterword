import Foundation
import AVFoundation

/// A reading layout over the original segments. Timings and wording stay intact.
public struct TranscriptParagraph: Identifiable, Codable, Sendable {
    public let id: Int
    public let segments: [TranscriptSegment]
    public var source: TranscriptSource { segments[0].source }
    public var participant: String? { segments[0].participant }
    public func speakerLabel(automaticParticipant: String? = nil, participantNames: [String: String] = [:]) -> String {
        segments[0].speakerLabel(automaticParticipant: automaticParticipant, participantNames: participantNames)
    }
    public var start: Double { segments[0].start }
    public var end: Double { segments.map(\.end).max() ?? start }
    public var text: String { segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ") }

    public static func make(from segments: [TranscriptSegment]) -> [TranscriptParagraph] {
        let ordered = segments.enumerated().filter {
            $0.element.start.isFinite && $0.element.end.isFinite && $0.element.start >= 0 &&
            $0.element.end >= $0.element.start && !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }
        var groups: [[TranscriptSegment]] = []
        for item in ordered {
            let segment = item.element
            if let previous = groups.last, let last = previous.last,
               last.source == segment.source,
               last.participant == segment.participant, last.speakerGroup == segment.speakerGroup, last.groupAssignment == segment.groupAssignment,
               segment.start - (previous.map(\.end).max() ?? last.end) <= 3,
               segment.end - previous[0].start <= 45,
               previous.reduce(0, { $0 + $1.text.count + 1 }) + segment.text.count <= 650 {
                groups[groups.count - 1].append(segment)
            } else { groups.append([segment]) }
        }
        return groups.enumerated().map { .init(id: $0.offset, segments: $0.element) }
    }
}

public extension Transcript {
    var paragraphs: [TranscriptParagraph] { TranscriptParagraph.make(from: segments) }
    var readableText: String {
        readableText(recordingName: recording)
    }
    func readableText(recordingName: String, automaticParticipant: String? = nil, participantNames: [String: String] = [:], suggestions: [String: String] = [:]) -> String {
        let body = paragraphs.map { paragraph in
            let first = paragraph.segments[0]
            let name = first.speakerLabel(automaticParticipant: automaticParticipant ?? self.automaticParticipant, participantNames: participantNames,
                                          suggestion: first.speakerGroup.flatMap { suggestions[$0] })
            return "\(name) · \(Self.timestamp(paragraph.start))\n\(paragraph.text)"
        }.joined(separator: "\n\n")
        let empty = editing == nil ? "No speech was detected." : "This edited transcript has no text."
        return "\(recordingName)\nModel: \(modelName)\n" + (editing == nil ? "\n" : "Manually edited transcript\n\n") + (body.isEmpty ? empty : body) + "\n"
    }
    static func read(from url: URL) throws -> Transcript {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Transcript.self, from: Data(contentsOf: url))
        guard (1...3).contains(document.version), document.segments.allSatisfy({
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end < 1e12
        }) else { throw RecorderError.message("This transcript has an unsupported format or invalid timestamps.") }
        return document
    }
}

public struct LibraryAudioTrack: Identifiable, Codable, Sendable {
    public let source: TranscriptSource
    public let url: URL
    public var id: String { source.rawValue }
    public var label: String {
        switch source { case .mixed: return "Mixed audio"; case .microphone: return "Microphone"; case .system: return "System audio" }
    }
}

public struct LibraryTranscript: Identifiable, Codable, Sendable {
    public let url: URL
    public let document: Transcript?
    public let error: String?
    public let date: Date
    let fileModificationDate: Date
    public var id: String { url.path }
    public var runName: String { url.deletingLastPathComponent().lastPathComponent }
}

public struct LibraryRecording: Identifiable, Codable, Sendable {
    public func agentSummaryRequest() throws -> String {
        let callID = try AgentJSON.identity(url)
        return "Summarize this Afterword call and save the summary back to it. Use call_id \(callID) and scope \(details.scope.rawValue) for each tool call. Read get_call and the full get_transcript first, then use save_call_summary with the source version and current call revision."
    }
    public let url: URL
    public let sourceName: String
    public let isDirectory: Bool
    public let details: CallDetails
    public let detailsError: String?
    public var name: String { details.title ?? sourceName }
    public let date: Date
    public let duration: Double?
    public let tracks: [LibraryAudioTrack]
    public let transcripts: [LibraryTranscript]
    public var summary: CallSummary? = nil
    public var summaryError: String? = nil
    public var directoryLabels: [String: String]? = nil

    public func displayName(_ label: String) -> String { directoryLabels?[label] ?? label }
    public var participantDisplayNames: [String] { details.participants.map(displayName) }

    func resolvingPeople(_ people: PeopleDirectory) -> Self {
        var result = self
        let labels = people.labels(for: details.callAttendees)
        result.directoryLabels = labels.isEmpty ? nil : labels
        return result
    }
    public var id: String { url.path }
    public var latestTranscript: LibraryTranscript? { transcripts.first }
    public var hasTranscript: Bool { transcripts.contains { $0.document != nil } }
    public func automaticParticipant(for version: LibraryTranscript) -> String? {
        details.automaticParticipant(for: version)
    }
    public func speakerLabel(for paragraph: TranscriptParagraph, version: LibraryTranscript) -> String {
        let names = paragraph.participant.map { [$0: details.participantName($0, for: version).map(displayName) ?? ""] } ?? [:]
        return paragraph.speakerLabel(automaticParticipant: automaticParticipant(for: version).map(displayName), participantNames: names)
    }
    public func readableText(for version: LibraryTranscript, suggestions: [String: String] = [:]) -> String? {
        version.document?.readableText(recordingName: name, automaticParticipant: automaticParticipant(for: version).map(displayName) ?? "",
                                       participantNames: details.participantNames(for: version).mapValues(displayName), suggestions: suggestions.mapValues(displayName))
    }
    public func matches(_ query: String, allVersions: Bool = false) -> Bool {
        let query = LibrarySearchQuery(query)
        let information = ([name, sourceName, details.description, summary?.current?.markdown ?? ""] + participantDisplayNames + details.participants + details.tags).joined(separator: "\n")
        let versions = allVersions ? transcripts : Array(transcripts.prefix(1))
        return query.isEmpty || query.matches(information) || versions.contains { version in
            let paragraphs = version.document?.paragraphs ?? []
            return query.matches(information + "\n" + paragraphs.map(\.text).joined(separator: " ") + "\n" + paragraphs.map { speakerLabel(for: $0, version: version) }.joined(separator: " "))
        }
    }
    public func matchingPassage(_ query: String, allVersions: Bool = false) -> String? {
        let query = LibrarySearchQuery(query)
        guard !query.isEmpty else { return nil }
        for version in allVersions ? transcripts : Array(transcripts.prefix(1)) {
            if let paragraph = version.document?.paragraphs.first(where: {
                !query.highlightRanges(in: $0.text).isEmpty || !query.highlightRanges(in: speakerLabel(for: $0, version: version)).isEmpty
            }) { return paragraph.text }
        }
        return nil
    }

}

public struct LibraryScan: Sendable {
    public var recordings: [LibraryRecording] = []
    public var issues: [String] = []
}

/// Index only saved deliveries. Hidden export/transcription staging directories
/// are excluded; opening the library never writes to recordings or transcripts.
public enum RecordingLibraryScanner {
    public static func scan(roots: [URL], confined: Bool = false) -> LibraryScan {
        let catalog = discover(roots: roots, confined: confined)
        var result = LibraryScan(issues: catalog.issues)
        let people = (try? PeopleDirectory.load(from: PeopleDirectory.fileURL)) ?? PeopleDirectory()
        for candidate in catalog.candidates {
            if Task.isCancelled { break }
            do { result.recordings.append(try load(candidate, confined: confined, people: people)) }
            catch { result.issues.append("\(candidate.url.lastPathComponent): \(error.localizedDescription)") }
        }
        result.recordings.sort { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        return result
    }

    // Discovery reads directory entries and stat information, never transcript bodies or audio.
    static func discover(roots: [URL], confined: Bool, includes: ((URL, Bool) throws -> Bool)? = nil) -> (candidates: [LibraryCandidate], issues: [String]) {
        var candidates: [LibraryCandidate] = [], issues: [String] = [], visited = Set<String>()
        let fm = FileManager.default
        for root in roots {
            do {
                let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles])
                let entries = audioTracks(in: root).isEmpty ? children : [root]
                for candidate in entries {
                    let url = candidate.resolvingSymlinksInPath().standardizedFileURL
                    if confined && (url != candidate.standardizedFileURL || !CallFileOperations.contains(root, url)) { continue }
                    guard visited.insert(url.path).inserted else { continue }
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    let directory = values.isDirectory == true
                    if confined && directory && !fm.isReadableFile(atPath: url.path) {
                        throw RecorderError.message("A library directory is unreadable.")
                    }
                    let tracks: [LibraryAudioTrack]
                    if directory { tracks = audioTracks(in: url) }
                    else if values.isRegularFile == true,
                            ["m4a", "wav", "caf", "mp3", "aiff"].contains(url.pathExtension.lowercased()),
                            !RecordingTrack.allCases.contains(where: { $0.filename == url.lastPathComponent }) {
                        tracks = [.init(source: .mixed, url: url)]
                    } else { continue }
                    guard !tracks.isEmpty else { continue }
                    let transcriptDirectory = directory ? url : url.deletingLastPathComponent()
                    let details = CallDetailsStore.url(for: url, isDirectory: directory)
                    if confined, let size = try? details.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_048_576 {
                        throw RecorderError.message("Call information exceeds the agent access size limit.")
                    }
                    if let includes, try !includes(url, directory) { continue }
                    let files = try transcriptFiles(in: transcriptDirectory, confined: confined)
                    let summary = CallSummaryStore.url(for: url, isDirectory: directory)
                    let nodes = [url, details, summary, transcriptDirectory.appendingPathComponent("Transcripts")] + tracks.map(\.url) + files.flatMap { [$0.deletingLastPathComponent(), $0] }
                    candidates.append(try LibraryCandidate(url: url, isDirectory: directory, tracks: tracks, transcriptFiles: files, nodes: nodes))
                }
            } catch { issues.append("\(root.lastPathComponent): \(error.localizedDescription)") }
        }
        return (candidates, issues)
    }

    static func load(_ candidate: LibraryCandidate, confined: Bool, people: PeopleDirectory? = nil) throws -> LibraryRecording {
        let url = candidate.url, directory = candidate.isDirectory
        let name = directory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let versions = readTranscripts(candidate.transcriptFiles).filter {
            directory || ($0.document?.recording == name && $0.document?.sources[TranscriptSource.mixed.rawValue] == url.lastPathComponent)
        }
        var details = CallDetails(), detailsError: String?
        do { details = try CallDetailsStore.load(for: url, isDirectory: directory) }
        catch { detailsError = error.localizedDescription }
        var summary: CallSummary?, summaryError: String?
        do { summary = try CallSummaryStore.load(for: url, isDirectory: directory) }
        catch { summaryError = error.localizedDescription }
        let reader = candidate.tracks.lazy.compactMap { try? AVAudioFile(forReading: $0.url) }.first
        let duration = reader.map { Double($0.length) / $0.processingFormat.sampleRate }
        guard try candidate.currentFingerprint() == candidate.fingerprint else {
            throw RecorderError.message("A recording changed while it was being read. Refresh to retry.")
        }
        return .init(url: url, sourceName: name, isDirectory: directory, details: details, detailsError: detailsError,
            date: recordingDate(name) ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast,
            duration: duration?.isFinite == true ? duration : nil, tracks: candidate.tracks, transcripts: versions,
            summary: summary, summaryError: summaryError).resolvingPeople(people ?? (try? PeopleDirectory.load(from: PeopleDirectory.fileURL)) ?? .init())
    }

    private static func audioTracks(in directory: URL) -> [LibraryAudioTrack] {
        [(TranscriptSource.mixed, RecordingTrack.mixed), (.microphone, .microphone), (.system, .system)].compactMap { source, track in
            let url = directory.appendingPathComponent(track.filename)
            return PrivateFiles.isRegular(url) ? .init(source: source, url: url) : nil
        }
    }

    static func transcripts(in directory: URL) -> [LibraryTranscript] {
        (try? transcripts(in: directory, confined: false)) ?? []
    }

    static func transcripts(in directory: URL, confined: Bool) throws -> [LibraryTranscript] {
        readTranscripts(try transcriptFiles(in: directory, confined: confined))
    }

    private static func transcriptFiles(in directory: URL, confined: Bool) throws -> [URL] {
        let root = directory.appendingPathComponent("Transcripts", isDirectory: true)
        if confined && root.resolvingSymlinksInPath().standardizedFileURL != root.standardizedFileURL { return [] }
        let runs: [URL]
        do { runs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) }
        catch {
            if confined && FileManager.default.fileExists(atPath: root.path) { throw error }
            return []
        }
        if confined {
            for run in runs where run.resolvingSymlinksInPath().standardizedFileURL == run.standardizedFileURL {
                if !FileManager.default.isReadableFile(atPath: run.path) {
                    throw RecorderError.message("A transcript directory is unreadable.")
                }
                let file = run.appendingPathComponent("Transcript.json")
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 16 * 1_048_576 {
                    throw RecorderError.message("A transcript exceeds the agent access size limit.")
                }
            }
        }
        return runs.compactMap { run in
            if confined && run.resolvingSymlinksInPath().standardizedFileURL != run.standardizedFileURL { return nil }
            let url = run.appendingPathComponent("Transcript.json")
            return PrivateFiles.isRegular(url) ? url : nil
        }.sorted { $0.path < $1.path }
    }

    private static func readTranscripts(_ files: [URL]) -> [LibraryTranscript] {
        files.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            do {
                let document = try Transcript.read(from: url)
                return .init(url: url, document: document, error: nil, date: document.createdAt, fileModificationDate: date)
            } catch { return .init(url: url, document: nil, error: error.localizedDescription, date: date, fileModificationDate: date) }
        }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            // JSON timestamps have second precision. Rapid edits still sort by save order.
            if $0.fileModificationDate != $1.fileModificationDate { return $0.fileModificationDate > $1.fileModificationDate }
            return $0.id > $1.id
        }
    }

    private static func recordingDate(_ name: String) -> Date? {
        guard name.hasPrefix("Call-") else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"; formatter.isLenient = false
        return formatter.date(from: String(name.dropFirst(5).prefix(19)))
    }
}
