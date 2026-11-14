import Foundation
import AVFoundation
import Darwin

public struct ChunkRecord: Codable, Equatable {
    public var sequence: Int
    public var filename: String
    public var frames: Int64
    public init(sequence: Int, filename: String, frames: Int64) { self.sequence = sequence; self.filename = filename; self.frames = frames }
}
public struct MicrophoneEvent: Codable, Equatable {
    public var frame: Int64
    public var enabled: Bool
}
public struct SessionManifest: Codable {
    // v1 stores a stereo mix; v2 stores mic mono + system stereo on one timeline.
    public var version = 2
    public var id: UUID
    public var startDate: Date
    public var timeZone: String
    public var utcOffsetSeconds: Int
    public var monotonicStart: UInt64
    public var firstSampleTime: Double?
    public var firstHostTime: UInt64?
    public var microphoneSelection: MicrophoneSelection
    public var deviceUID: String
    public var channel: Int
    public var formats: [SourceFormat]
    public var destination: String
    public var chunks: [ChunkRecord] = []
    public var microphoneEvents: [MicrophoneEvent] = []
    public var errors: [String] = []
    public var status = "recording"
    public var deliveredPath: String?
    public var retainRecoveryFiles: Bool?
    public var callDetails: CallDetails?
    public var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    public var applicationVersion = "0.9.0"
    public var clippedSamples: UInt64 = 0
    public var invalidSamples: UInt64 = 0
    public var droppedFrames: UInt64 = 0
    public var totalFrames: Int64 { chunks.reduce(0) { $0 + $1.frames } }
    public var hasSeparateTracks: Bool { version == 2 }
    public var pcmChannels: AVAudioChannelCount { hasSeparateTracks ? 3 : 2 }
    public init(id: UUID = UUID(), startDate: Date = Date(), input: ResolvedInput, formats: [SourceFormat], destination: URL, separateTracks: Bool = true, callDetails: CallDetails? = nil) {
        version = separateTracks ? 2 : 1
        self.id = id; self.startDate = startDate
        timeZone = TimeZone.current.identifier; utcOffsetSeconds = TimeZone.current.secondsFromGMT(for: startDate)
        monotonicStart = mach_absolute_time(); microphoneSelection = input.selection
        deviceUID = input.device.uid; channel = input.channel; self.formats = formats
        self.destination = destination.path
        self.callDetails = callDetails
    }
}

enum PrivateFiles {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static func create(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        Darwin.close(fd)
    }
    static func sync(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".manifest-\(UUID().uuidString).tmp")
        try create(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try sync(url.deletingLastPathComponent())
    }
    static func isRegular(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

public final class SessionStore {
    public static let chunkFrames: Int64 = 480_000
    public static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    // Channel order is part of the v2 disk format, not a speaker layout:
    // 0 = selected microphone, 1 = system left, 2 = system right.
    public static let sourcePCMFormat = PCMFormats.make(sampleRate: 48_000, channels: 3)!
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Call Recorder/Sessions", isDirectory: true)
    }
    public let directory: URL
    public private(set) var manifest: SessionManifest
    public var format: AVAudioFormat { manifest.hasSeparateTracks ? Self.sourcePCMFormat : Self.pcmFormat }
    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var currentFrames: Int64 = 0
    private lazy var scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768)!
    private var lastStorageCheck = Date.distantPast
    public init(root: URL = SessionStore.defaultRoot, manifest: SessionManifest) throws {
        self.manifest = manifest
        try PrivateFiles.directory(root)
        directory = root.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw RecorderError.message("Session already exists.") }
        try PrivateFiles.directory(directory)
        try checkpoint()
    }
    init(directory: URL, manifest: SessionManifest) { self.directory = directory; self.manifest = manifest }
    public func checkpoint() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try PrivateFiles.atomicWrite(encoder.encode(manifest), to: directory.appendingPathComponent("manifest.json"))
    }
    public func setTimeline(sampleTime: Double, hostTime: UInt64) throws {
        if manifest.firstSampleTime == nil {
            manifest.firstSampleTime = sampleTime; manifest.firstHostTime = hostTime; try checkpoint()
        }
    }
    public func microphone(enabled: Bool, frame: Int64) throws {
        guard manifest.microphoneEvents.last?.enabled != enabled else { return }
        manifest.microphoneEvents.append(MicrophoneEvent(frame: frame, enabled: enabled)); try checkpoint()
    }
    public func recordError(_ message: String, droppedFrames: UInt64 = 0) {
        manifest.errors.append(message); manifest.droppedFrames = droppedFrames
        try? checkpoint() // On a full disk, preserve earlier checkpoints/chunks without masking the original error.
    }
    public func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format == format else { throw RecorderError.message("Spool received an unexpected PCM format.") }
        if Date().timeIntervalSince(lastStorageCheck) >= 2 {
            try StorageGuard.check(directory, reserve: StorageGuard.emergencyReserve)
            try StorageGuard.check(URL(fileURLWithPath: manifest.destination), reserve: StorageGuard.emergencyReserve)
            lastStorageCheck = Date()
        }
        var offset = 0
        while offset < Int(buffer.frameLength) {
            if currentFile == nil {
                let url = directory.appendingPathComponent(String(format: "chunk-%06d.open.caf", manifest.chunks.count))
                try PrivateFiles.create(url)
                currentURL = url
                var settings = format.settings
                settings[AVLinearPCMIsNonInterleaved] = false // CAF on disk is interleaved; worker buffers remain planar.
                currentFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                currentFrames = 0
            }
            let count = min(Int(scratch.frameCapacity), Int(buffer.frameLength) - offset, Int(Self.chunkFrames - currentFrames))
            scratch.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(format.channelCount) { scratch.floatChannelData![channel].update(from: buffer.floatChannelData![channel] + offset, count: count) }
            try currentFile!.write(from: scratch)
            currentFrames += Int64(count); offset += count
            if currentFrames == Self.chunkFrames { try finishChunk() }
        }
    }
    private func finishChunk() throws {
        guard let url = currentURL else { return }
        currentFile = nil // AVAudioFile closes/finalizes the independent CAF before the checkpoint.
        try PrivateFiles.sync(url)
        let filename = String(format: "chunk-%06d.caf", manifest.chunks.count)
        let completed = directory.appendingPathComponent(filename)
        guard renamex_np(url.path, completed.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        manifest.chunks.append(ChunkRecord(sequence: manifest.chunks.count, filename: filename, frames: currentFrames))
        currentURL = nil; currentFrames = 0
        try checkpoint()
    }
    public func finish(snapshot: PipelineSnapshot = PipelineSnapshot()) throws {
        try finishChunk()
        manifest.clippedSamples = snapshot.clippedSamples; manifest.invalidSamples = snapshot.invalidSamples
        manifest.droppedFrames = snapshot.droppedFrames; manifest.status = "ready"
        try checkpoint()
    }
    public func setDestination(_ url: URL) throws { manifest.destination = url.path; try checkpoint() }
    public func setStatus(_ status: String) throws { manifest.status = status; try checkpoint() }
    public func delivered(to url: URL) throws { manifest.status = "delivered"; manifest.deliveredPath = url.path; try checkpoint() }
    @discardableResult public func discardIfEmpty() throws -> Bool {
        guard manifest.chunks.isEmpty, currentURL == nil, currentFile == nil,
              directory.lastPathComponent == manifest.id.uuidString else { return false }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.allSatisfy({ $0 == "manifest.json" || ($0.hasPrefix(".manifest-") && $0.hasSuffix(".tmp")) }) else { return false }
        try FileManager.default.removeItem(at: directory)
        return true
    }
    public func removeAfterDelivery() throws {
        guard manifest.status == "delivered", let path = manifest.deliveredPath,
              PrivateFiles.isRegular(URL(fileURLWithPath: path)), directory.lastPathComponent == manifest.id.uuidString,
              (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              manifest.retainRecoveryFiles != true else {
            throw RecorderError.message("Recovery files were retained because delivery could not be confirmed.")
        }
        let delivered = URL(fileURLWithPath: path)
        if manifest.hasSeparateTracks {
            let folder = delivered.deletingLastPathComponent()
            let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard delivered.lastPathComponent == RecordingTrack.mixed.filename,
                  properties.isDirectory == true, properties.isSymbolicLink != true,
                  RecordingTrack.allCases.allSatisfy({ PrivateFiles.isRegular(folder.appendingPathComponent($0.filename)) }) else {
                throw RecorderError.message("Recovery files were retained because one or more separate tracks are missing.")
            }
            if manifest.callDetails != nil {
                guard PrivateFiles.isRegular(CallDetailsStore.url(for: folder, isDirectory: true)) else {
                    throw RecorderError.message("Recovery files were retained because meeting details are missing.")
                }
                _ = try CallDetailsStore.load(for: folder, isDirectory: true)
            }
        }
        let expected = Set(manifest.chunks.map(\.filename) + ["manifest.json"])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.allSatisfy({ expected.contains($0) || ($0.hasPrefix(".manifest-") && $0.hasSuffix(".tmp")) }) else {
            throw RecorderError.message("Delivered audio was validated, but additional recovery files were retained for inspection.")
        }
        try FileManager.default.removeItem(at: directory)
    }
}

public struct RecoveryCandidate: Identifiable {
    public var id: String { directory.lastPathComponent }
    public let directory: URL
    public let startDate: Date?
    public let explanation: String
    public let canRecover: Bool
}

public enum Recovery {
    public static func scan(root: URL = SessionStore.defaultRoot) -> [RecoveryCandidate] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        return entries.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { url in
            do {
                let store = try load(directory: url)
                return RecoveryCandidate(directory: url, startDate: store.manifest.startDate,
                                         explanation: store.manifest.errors.last ?? "Interrupted recording. The unfinished tail may be missing (up to one 10-second chunk plus queued audio).",
                                         canRecover: store.manifest.totalFrames > 0 && !(store.manifest.status == "delivered" && store.manifest.retainRecoveryFiles == true))
            } catch {
                return RecoveryCandidate(directory: url, startDate: nil, explanation: "Recovery files retained: \(error.localizedDescription)", canRecover: false)
            }
        }.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }
    public static func load(directory: URL) throws -> SessionStore {
        let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw RecorderError.message("Invalid session directory.") }
        let url = directory.appendingPathComponent("manifest.json")
        guard PrivateFiles.isRegular(url), (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 < 10_000_000 else { throw RecorderError.message("Missing or oversized manifest.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(SessionManifest.self, from: Data(contentsOf: url))
        guard [1, 2].contains(manifest.version), manifest.id.uuidString == directory.lastPathComponent, manifest.chunks.count < 100_000,
              manifest.chunks.allSatisfy({ $0.sequence >= 0 && $0.frames > 0 && $0.frames <= SessionStore.chunkFrames && safeChunkName($0.filename, sequence: $0.sequence) }) else {
            throw RecorderError.message("Unsupported or malformed manifest. Original files have been preserved.")
        }
        guard Set(manifest.chunks.map(\.sequence)).count == manifest.chunks.count else { throw RecorderError.message("Duplicate chunk sequence in manifest.") }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var reconciled: [ChunkRecord] = []
        var issue: String?
        for sequence in 0..<100_000 {
            let saved = manifest.chunks.first { $0.sequence == sequence }
            let complete = String(format: "chunk-%06d.caf", sequence)
            let open = String(format: "chunk-%06d.open.caf", sequence)
            let name = names.contains(complete) ? complete : (names.contains(open) ? open : nil)
            guard let name else {
                if saved != nil || names.contains(where: { $0.hasPrefix("chunk-") && $0 > complete }) { issue = "A chunk is missing. Only the uninterrupted prefix will be exported; later files remain in recovery." }
                break
            }
            let fileURL = directory.appendingPathComponent(name)
            guard PrivateFiles.isRegular(fileURL), let file = try? AVAudioFile(forReading: fileURL), validPCM(file, channels: manifest.pcmChannels), file.length > 0,
                  file.length <= SessionStore.chunkFrames else {
                issue = "The unfinished or damaged tail could not be decoded. The valid prefix is recoverable; original files are retained."; break
            }
            if let saved, saved.frames != file.length { issue = "A chunk's frame count changed. Its decodable prefix is included; the original remains available." }
            reconciled.append(ChunkRecord(sequence: sequence, filename: name, frames: file.length))
            if name == open { issue = "Recovered a readable unfinished chunk. Its tail may be missing."; break }
        }
        manifest.chunks = reconciled
        if let issue, !manifest.errors.contains(issue) { manifest.errors.append(issue); manifest.retainRecoveryFiles = true }
        if manifest.status == "recording" { manifest.errors.append("Recording was interrupted; the final tail may be missing.") }
        return SessionStore(directory: directory, manifest: manifest)
    }
    static func safeChunkName(_ name: String, sequence: Int) -> Bool {
        name == String(format: "chunk-%06d.caf", sequence) || name == String(format: "chunk-%06d.open.caf", sequence)
    }
    static func validPCM(_ file: AVAudioFile, channels: AVAudioChannelCount = 2) -> Bool {
        let f = file.fileFormat.streamDescription.pointee
        return f.mFormatID == kAudioFormatLinearPCM && f.mSampleRate == 48_000 && f.mChannelsPerFrame == channels && f.mBitsPerChannel == 32 && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
    }
}
