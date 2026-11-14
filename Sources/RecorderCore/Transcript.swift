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

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let source: TranscriptSource
    public let start: Double
    public let end: Double
    public let text: String
    public let timing: String
    public init(source: TranscriptSource, start: Double, end: Double, text: String, timing: String) {
        self.source = source; self.start = start; self.end = end; self.text = text; self.timing = timing
    }
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

    public init(input: TranscriptionInput, model: SpeechModel, engine: String, language: String, segments: [TranscriptSegment],
                speakerBleedReduction: SpeakerBleedReduction? = nil, echoCancellation: EchoCancellationDetails? = nil) throws {
        let allowed = Set(input.tracks.map(\.source))
        guard segments.allSatisfy({ allowed.contains($0.source) && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && ["word", "segment", "chunk"].contains($0.timing) }) else {
            throw RecorderError.message("The transcription worker returned invalid timestamps or track labels.")
        }
        version = 2; createdAt = Date(); recording = input.name
        self.speakerBleedReduction = speakerBleedReduction; self.echoCancellation = echoCancellation
        modelID = model.id; modelName = model.name; modelSHA256 = model.sha256
        self.engine = engine; self.language = language
        sources = Dictionary(uniqueKeysWithValues: input.tracks.map { ($0.source.rawValue, URL(fileURLWithPath: $0.path).lastPathComponent) })
        self.segments = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated().sorted { a, b in a.element.start == b.element.start ? a.offset < b.offset : a.element.start < b.element.start }.map(\.element)
    }
    public var plainText: String {
        let cleanup = speakerBleedReduction.map { "Speaker bleed reduction: \($0.description)\n" } ?? ""
        let header = "\(recording)\nModel: \(modelName)\n\(cleanup)Labels follow the recorded tracks. Other participants may include multiple people and system audio.\n\n"
        if segments.isEmpty { return header + "No speech was detected.\n" }
        return header + segments.map { "[\(Self.timestamp($0.start))] \($0.source.label): \($0.text)" }.joined(separator: "\n") + "\n"
    }
    public static func timestamp(_ seconds: Double) -> String {
        let value = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    public func save(beside input: TranscriptionInput) throws -> URL {
        let root = input.outputDirectory.appendingPathComponent("Transcripts", isDirectory: true)
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
}
