import Foundation
import AVFoundation

/// A reading layout over the original segments. Timings and wording stay intact.
public struct TranscriptParagraph: Identifiable, Sendable {
    public let id: Int
    public let segments: [TranscriptSegment]
    public var source: TranscriptSource { segments[0].source }
    public var participant: String? { segments[0].participant }
    public func speakerLabel(automaticParticipant: String? = nil) -> String { segments[0].speakerLabel(automaticParticipant: automaticParticipant) }
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
               last.participant == segment.participant,
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
    func readableText(recordingName: String, automaticParticipant: String? = nil) -> String {
        let body = paragraphs.map { "\($0.speakerLabel(automaticParticipant: automaticParticipant ?? self.automaticParticipant)) · \(Self.timestamp($0.start))\n\($0.text)" }.joined(separator: "\n\n")
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

public struct LibraryAudioTrack: Identifiable, Sendable {
    public let source: TranscriptSource
    public let url: URL
    public var id: String { source.rawValue }
    public var label: String {
        switch source { case .mixed: return "Mixed audio"; case .microphone: return "Microphone"; case .system: return "System audio" }
    }
}

public struct LibraryTranscript: Identifiable, Sendable {
    public let url: URL
    public let document: Transcript?
    public let error: String?
    public let date: Date
    let fileModificationDate: Date
    public var id: String { url.path }
}

public struct LibraryRecording: Identifiable, Sendable {
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
    public var id: String { url.path }
    public var latestTranscript: LibraryTranscript? { transcripts.first }
    public var hasTranscript: Bool { transcripts.contains { $0.document != nil } }
    public func automaticParticipant(for version: LibraryTranscript) -> String? {
        version.document?.automaticParticipant ?? details.automaticParticipants?[version.url.deletingLastPathComponent().lastPathComponent]
            ?? (details.participants.count == 1 ? details.participants.first : nil)
    }
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let information = ([name, sourceName, details.description] + details.participants + details.tags).joined(separator: "\n")
        return query.isEmpty || information.localizedStandardContains(query) || transcripts.contains {
            version in version.document?.paragraphs.contains {
                $0.text.localizedStandardContains(query) || $0.speakerLabel(automaticParticipant: automaticParticipant(for: version)).localizedStandardContains(query)
            } == true
        }
    }
    public func matchingPassage(_ query: String) -> String? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        for version in transcripts {
            if let paragraph = version.document?.paragraphs.first(where: {
                $0.text.localizedStandardContains(query) || $0.speakerLabel(automaticParticipant: automaticParticipant(for: version)).localizedStandardContains(query)
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
    public static func scan(roots: [URL]) -> LibraryScan {
        var result = LibraryScan(), visited = Set<String>()
        let fm = FileManager.default
        for root in roots {
            if Task.isCancelled { break }
            do {
                let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .creationDateKey], options: [.skipsHiddenFiles])
                let candidates = audioTracks(in: root).isEmpty ? children : [root]
                // Legacy files share their parent's Transcripts directory. Match
                // the stored recording name so transcripts cannot cross calls.
                let shared = transcripts(in: root)
                for candidate in candidates {
                    if Task.isCancelled { break }
                    let url = candidate.resolvingSymlinksInPath().standardizedFileURL
                    guard visited.insert(url.path).inserted else { continue }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .creationDateKey])
                    let directory = values?.isDirectory == true
                    let tracks: [LibraryAudioTrack]
                    if directory { tracks = audioTracks(in: url) }
                    else if values?.isRegularFile == true,
                            ["m4a", "wav", "caf", "mp3", "aiff"].contains(url.pathExtension.lowercased()),
                            !RecordingTrack.allCases.contains(where: { $0.filename == url.lastPathComponent }) {
                        tracks = [.init(source: .mixed, url: url)]
                    } else { continue }
                    guard !tracks.isEmpty else { continue }
                    let name = directory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
                    let versions = directory ? transcripts(in: url) : shared.filter {
                        $0.document?.recording == name && $0.document?.sources[TranscriptSource.mixed.rawValue] == url.lastPathComponent
                    }
                    var details = CallDetails(), detailsError: String?
                    do { details = try CallDetailsStore.load(for: url, isDirectory: directory) }
                    catch { detailsError = error.localizedDescription }
                    let reader = tracks.lazy.compactMap { try? AVAudioFile(forReading: $0.url) }.first
                    let duration = reader.map { Double($0.length) / $0.processingFormat.sampleRate }
                    result.recordings.append(.init(url: url, sourceName: name, isDirectory: directory, details: details, detailsError: detailsError,
                        date: recordingDate(name) ?? values?.creationDate ?? .distantPast,
                        duration: duration?.isFinite == true ? duration : nil, tracks: tracks, transcripts: versions))
                }
            } catch {
                result.issues.append("\(root.lastPathComponent): \(error.localizedDescription)")
            }
        }
        result.recordings.sort { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        return result
    }

    private static func audioTracks(in directory: URL) -> [LibraryAudioTrack] {
        [(TranscriptSource.mixed, RecordingTrack.mixed), (.microphone, .microphone), (.system, .system)].compactMap { source, track in
            let url = directory.appendingPathComponent(track.filename)
            return PrivateFiles.isRegular(url) ? .init(source: source, url: url) : nil
        }
    }

    static func transcripts(in directory: URL) -> [LibraryTranscript] {
        let root = directory.appendingPathComponent("Transcripts", isDirectory: true)
        let runs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return runs.compactMap { run -> LibraryTranscript? in
            let url = run.appendingPathComponent("Transcript.json")
            guard PrivateFiles.isRegular(url) else { return nil }
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
