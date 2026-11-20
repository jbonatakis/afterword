import Foundation
import AVFoundation

public enum TranscriptSource: String, Codable, Sendable {
    case microphone, system, mixed
    public var label: String {
        switch self { case .microphone: return "You"; case .system: return "Other participants"; case .mixed: return "Mixed audio" }
    }
}

public struct TranscriptionTrack: Codable, Sendable {
    public let source: TranscriptSource
    public let path: String
    public init(source: TranscriptSource, url: URL) { self.source = source; path = url.path }
}

public struct TranscriptionInput: Sendable {
    public let tracks: [TranscriptionTrack]
    public let outputDirectory: URL
    public let name: String
    public static func resolve(_ url: URL) throws -> TranscriptionInput {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw RecorderError.message("This recording could not be found. Choose it again.") }
        let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        let mic = folder.appendingPathComponent(RecordingTrack.microphone.filename)
        let system = folder.appendingPathComponent(RecordingTrack.system.filename)
        let standard = RecordingTrack.allCases.contains { $0.filename == url.lastPathComponent }
        if isDirectory.boolValue || standard {
            let hasMic = fm.fileExists(atPath: mic.path), hasSystem = fm.fileExists(atPath: system.path)
            if hasMic || hasSystem {
                guard hasMic && hasSystem else { throw RecorderError.message("This recording is missing a separate track. Restore both Microphone.m4a and System.m4a before transcribing it.") }
                let a = try AVAudioFile(forReading: mic), b = try AVAudioFile(forReading: system)
                guard a.length > 0, b.length > 0, a.processingFormat.channelCount == 1, b.processingFormat.channelCount == 2,
                      a.processingFormat.sampleRate == b.processingFormat.sampleRate, abs(a.length - b.length) <= 1 else {
                    throw RecorderError.message("The separate tracks do not have matching timelines.")
                }
                return TranscriptionInput(tracks: [.init(source: .microphone, url: mic), .init(source: .system, url: system)], outputDirectory: folder, name: folder.lastPathComponent)
            }
        }
        let single = isDirectory.boolValue ? folder.appendingPathComponent(RecordingTrack.mixed.filename) : url
        let audio = try AVAudioFile(forReading: single)
        guard audio.length > 0, audio.processingFormat.channelCount <= 2 else { throw RecorderError.message("Choose a mono or stereo recording.") }
        return TranscriptionInput(tracks: [.init(source: .mixed, url: single)], outputDirectory: folder, name: single.deletingPathExtension().lastPathComponent)
    }
}

public struct TranscriptWord: Codable, Equatable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let source: TranscriptSource
    public let start: Double
    public let end: Double
    public let text: String
    public let timing: String
    /// nil uses the transcript's automatic name; an empty string explicitly leaves a passage unassigned.
    public let participant: String?
    /// True for a name accepted for a whole voice group. Individual corrections take precedence.
    public let groupAssignment: Bool?
    public let speakerGroup: String?
    public let words: [TranscriptWord]?
    public init(source: TranscriptSource, start: Double, end: Double, text: String, timing: String, participant: String? = nil, speakerGroup: String? = nil, words: [TranscriptWord]? = nil, groupAssignment: Bool? = nil) {
        self.source = source; self.start = start; self.end = end; self.text = text; self.timing = timing
        self.participant = participant; self.speakerGroup = speakerGroup; self.words = words; self.groupAssignment = groupAssignment
    }
    public func speakerLabel(automaticParticipant: String? = nil, participantNames: [String: String] = [:], suggestion: String? = nil) -> String {
        guard source == .system else { return source.label }
        if participant == nil, automaticParticipant?.isEmpty != false, speakerGroup != nil, let suggestion {
            return suggestion + " (suggested)"
        }
        let name = (participant.map { participantNames[$0] ?? $0 } ?? automaticParticipant)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name! : speakerGroup.map { "Speaker " + String($0.dropFirst()) } ?? source.label
    }
}

public struct TranscriptEditing: Codable, Sendable {
    public let parentVersion: String
    public let editedAt: Date
}

public struct Transcript: Codable, Sendable {
    public let version: Int
    public let createdAt: Date
    public let recording: String
    public let modelID: String
    public let modelName: String
    public let modelSHA256: String
    public let engine: String
    public let language: String
    public let sources: [String: String]
    public let segments: [TranscriptSegment]
    // Optional for compatibility with transcripts produced before version 0.4.
    public let speakerBleedReduction: SpeakerBleedReduction?
    public let echoCancellation: EchoCancellationDetails?
    public let editing: TranscriptEditing?
    public let automaticParticipant: String?
    /// Names explicitly chosen for a diarized voice in this version, including voices with no assignable words.
    let reviewedGroupNames: [String: String]?
    public private(set) var speakerSuggestions: [String: SpeakerSuggestion]?

    public init(input: TranscriptionInput, model: SpeechModel, engine: String, language: String, segments: [TranscriptSegment],
                speakerBleedReduction: SpeakerBleedReduction? = nil, echoCancellation: EchoCancellationDetails? = nil,
                automaticParticipant: String? = nil, speakerSuggestions: [String: SpeakerSuggestion] = [:]) throws {
        let allowed = Set(input.tracks.map(\.source))
        guard segments.allSatisfy({ allowed.contains($0.source) && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && ["word", "segment", "chunk"].contains($0.timing) }) else {
            throw RecorderError.message("The transcription worker returned invalid timestamps or track labels.")
        }
        self.automaticParticipant = automaticParticipant ?? CallDetailsStore.singleParticipant(for: input)
        version = self.automaticParticipant != nil || segments.contains(where: { $0.participant != nil }) ? 3 : 2
        createdAt = Date(); recording = input.name
        self.speakerBleedReduction = speakerBleedReduction; self.echoCancellation = echoCancellation
        editing = nil; reviewedGroupNames = nil
        self.speakerSuggestions = speakerSuggestions.isEmpty ? nil : speakerSuggestions
        modelID = model.id; modelName = model.name; modelSHA256 = model.sha256
        self.engine = engine; self.language = language
        sources = Dictionary(uniqueKeysWithValues: input.tracks.map { ($0.source.rawValue, URL(fileURLWithPath: $0.path).lastPathComponent) })
        self.segments = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated().sorted { a, b in a.element.start == b.element.start ? a.offset < b.offset : a.element.start < b.element.start }.map(\.element)
    }
    public var plainText: String {
        let cleanup = speakerBleedReduction.map { "Speaker bleed reduction: \($0.description)\n" } ?? ""
        let edits = editing == nil ? "" : "Manually edited transcript. Edited paragraphs retain their original audio intervals.\n"
        let labels: String
        if segments.contains(where: { $0.speakerGroup != nil }) {
            labels = "Numbered speakers are voices detected on the system track. Names use this call’s participant assignments."
        } else if automaticParticipant != nil || segments.contains(where: { $0.participant != nil }) {
            labels = "Speaker names use participant assignments; unassigned labels follow the recorded tracks."
        } else {
            labels = "Labels follow the recorded tracks. Other participants may include multiple people and system audio."
        }
        let header = "\(recording)\nModel: \(modelName)\n\(cleanup)\(edits)\(labels)\n\n"
        if segments.isEmpty { return header + (editing == nil ? "No speech was detected.\n" : "This edited transcript has no text.\n") }
        return header + segments.map { segment in
            let suggestion = segment.speakerGroup.flatMap { speakerSuggestions?[$0]?.name }
            let speaker = segment.speakerLabel(automaticParticipant: automaticParticipant, suggestion: suggestion)
            return "[\(Self.timestamp(segment.start))] \(speaker): \(segment.text)"
        }.joined(separator: "\n") + "\n"
    }
    public static func timestamp(_ seconds: Double) -> String {
        let value = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    public func save(beside input: TranscriptionInput) throws -> URL {
        try save(in: input.outputDirectory)
    }

    mutating func updateSuggestions(_ suggestions: [String: SpeakerSuggestion], attendees: [CallAttendee]) {
        let reviewed = savedSpeakerNames
        let pending = suggestions.filter { reviewed[$0.key] == nil }.compactMapValues { $0.resolving(in: attendees) }
        speakerSuggestions = pending.isEmpty ? nil : pending
    }
    public func save(in directory: URL) throws -> URL {
        let root = directory.appendingPathComponent("Transcripts", isDirectory: true)
        try PrivateFiles.directory(root)
        let stage = root.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
        try PrivateFiles.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try PrivateFiles.atomicWrite(encoder.encode(self), to: stage.appendingPathComponent("Transcript.json"))
        try PrivateFiles.atomicWrite(Data(plainText.utf8), to: stage.appendingPathComponent("Transcript.txt"))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let final = root.appendingPathComponent(formatter.string(from: createdAt) + "-" + modelID + "-" + UUID().uuidString.prefix(8), isDirectory: true)
        guard renamex_np(stage.path, final.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return final.appendingPathComponent("Transcript.txt")
    }

    public func editingParagraphs(_ text: [String], parentVersion: String, participants: [String?]? = nil,
                                  automaticParticipant: String? = nil, reviewedGroupNames: [String: String]? = nil) throws -> Transcript {
        let paragraphs = paragraphs
        guard text.count == paragraphs.count else { throw RecorderError.message("The transcript structure changed. Reopen the editor.") }
        let participants = participants ?? paragraphs.map(\.participant)
        guard participants.count == paragraphs.count else { throw RecorderError.message("The speaker assignments no longer match this transcript. Reopen the editor.") }
        var segments: [TranscriptSegment] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let replacement = text[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let participant = participants[index]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard paragraph.source == .system || participant == nil else { throw RecorderError.message("Only the separate system-audio track can be assigned to other participants.") }
            if replacement == paragraph.text {
                segments.append(contentsOf: paragraph.segments.map {
                    .init(source: $0.source, start: $0.start, end: $0.end, text: $0.text, timing: $0.timing, participant: participant, speakerGroup: $0.speakerGroup, words: $0.words, groupAssignment: participant == $0.participant ? $0.groupAssignment : nil)
                })
            }
            else if !replacement.isEmpty {
                segments.append(.init(source: paragraph.source, start: paragraph.start, end: paragraph.end, text: replacement, timing: "segment", participant: participant, speakerGroup: paragraph.segments.first?.speakerGroup, groupAssignment: participant == paragraph.participant ? paragraph.segments.first?.groupAssignment : nil))
            }
        }
        return Transcript(original: self, segments: segments, parentVersion: parentVersion, automaticParticipant: automaticParticipant ?? self.automaticParticipant,
                          reviewedGroupNames: reviewedGroupNames ?? savedSpeakerNames)
    }
    init(original: Transcript, segments: [TranscriptSegment], parentVersion: String, automaticParticipant: String?, reviewedGroupNames: [String: String]) {
        self.reviewedGroupNames = reviewedGroupNames.isEmpty ? nil : reviewedGroupNames
        let remaining = original.speakerSuggestions?.filter { reviewedGroupNames[$0.key] == nil }
        self.speakerSuggestions = remaining?.isEmpty == false ? remaining : nil
        let automaticParticipant = automaticParticipant?.isEmpty == true ? nil : automaticParticipant
        version = automaticParticipant != nil || !reviewedGroupNames.isEmpty || segments.contains(where: { $0.participant != nil }) ? 3 : 2
        createdAt = Date(); recording = original.recording
        modelID = original.modelID; modelName = original.modelName; modelSHA256 = original.modelSHA256
        engine = original.engine; language = original.language; sources = original.sources
        speakerBleedReduction = original.speakerBleedReduction; echoCancellation = original.echoCancellation
        self.segments = segments
        editing = .init(parentVersion: parentVersion, editedAt: createdAt)
        self.automaticParticipant = automaticParticipant
    }
}
