import Foundation
import AVFoundation
import Darwin

public enum RecordingTrack: CaseIterable {
    case mixed, microphone, system
    public var filename: String {
        switch self {
        case .mixed: return "Mixed.m4a"
        case .microphone: return "Microphone.m4a"
        case .system: return "System.m4a"
        }
    }
    public var channels: AVAudioChannelCount { self == .microphone ? 1 : 2 }
    var bitRate: Int { self == .microphone ? 64_000 : 128_000 }
}

public enum Exporter {
    public static func filename(start: Date, offset: Int, suffix: Int = 0) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offset); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Call-\(formatter.string(from: start))\(suffix == 0 ? "" : "-\(suffix)").m4a"
    }
    @discardableResult public static func export(_ store: SessionStore, encoder: ((SessionStore, RecordingTrack, URL) throws -> Void)? = nil) throws -> URL {
        let manifest = store.manifest
        guard manifest.totalFrames > 0 else { throw RecorderError.message("No complete audio is available to export. Recovery files have been retained.") }
        if manifest.status == "delivered", let path = manifest.deliveredPath {
            let existing = URL(fileURLWithPath: path)
            if (try? validateDelivery(existing, manifest: manifest)) != nil {
                if manifest.retainRecoveryFiles != true { try store.removeAfterDelivery() }
                return existing
            }
            // Rebuild an incomplete delivered set from retained PCM; never accept
            // the remaining mix alone or overwrite the earlier delivery.
        }
        let destination = URL(fileURLWithPath: manifest.destination, isDirectory: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let bytesPerSecond = manifest.hasSeparateTracks ? 40_000.0 : 16_000.0
        let expectedBytes = Int64(Double(manifest.totalFrames) / 48_000 * bytesPerSecond) + 12_000_000
        try StorageGuard.check(destination, reserve: StorageGuard.emergencyReserve + expectedBytes)
        let temporary = destination.appendingPathComponent(".Call-\(manifest.id.uuidString)-\(UUID().uuidString)\(manifest.hasSeparateTracks ? "" : ".m4a")", isDirectory: manifest.hasSeparateTracks)
        if manifest.hasSeparateTracks { try PrivateFiles.directory(temporary) }
        else { try PrivateFiles.create(temporary) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try store.setStatus("exporting")
            let tracks: [RecordingTrack] = manifest.hasSeparateTracks ? RecordingTrack.allCases : [.mixed]
            for track in tracks {
                let url = manifest.hasSeparateTracks ? temporary.appendingPathComponent(track.filename) : temporary
                if manifest.hasSeparateTracks { try PrivateFiles.create(url) }
                try (encoder ?? encode)(store, track, url)
            }
            if manifest.hasSeparateTracks, let details = manifest.callDetails {
                try CallDetailsStore.writeInitial(details, to: temporary.appendingPathComponent("CallDetails.json"))
            }
            let stagedMix = manifest.hasSeparateTracks ? temporary.appendingPathComponent(RecordingTrack.mixed.filename) : temporary
            try validateDelivery(stagedMix, manifest: manifest)
            for track in tracks {
                try PrivateFiles.sync(manifest.hasSeparateTracks ? temporary.appendingPathComponent(track.filename) : temporary)
            }
            if manifest.hasSeparateTracks { try PrivateFiles.sync(temporary) }
            var final: URL?
            for suffix in 0..<100_000 {
                let name = filename(start: manifest.startDate, offset: manifest.utcOffsetSeconds, suffix: suffix)
                let candidate = destination.appendingPathComponent(manifest.hasSeparateTracks ? String(name.dropLast(4)) : name, isDirectory: manifest.hasSeparateTracks)
                // Publish the entire validated set atomically, without overwrite.
                if renamex_np(temporary.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { final = candidate; break }
                guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            guard let final else { throw RecorderError.message("No available recording filename.") }
            try PrivateFiles.sync(destination)
            let mixed = manifest.hasSeparateTracks ? final.appendingPathComponent(RecordingTrack.mixed.filename) : final
            try store.delivered(to: mixed)
            if store.manifest.retainRecoveryFiles != true { try store.removeAfterDelivery() }
            return mixed
        } catch {
            store.recordError("Export failed: \(error.localizedDescription)")
            throw error
        }
    }
    static func encode(_ store: SessionStore, track: RecordingTrack, to url: URL) throws {
        guard store.manifest.hasSeparateTracks || track == .mixed else { throw RecorderError.message("This older recording contains only a mixed track.") }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: track.channels,
            AVEncoderBitRateKey: track.bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        // Each writer closes before validation. Every file begins at source frame
        // zero and includes silence and exactly the same uninterrupted prefix.
        let writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let input = AVAudioPCMBuffer(pcmFormat: store.format, frameCapacity: 32_768)!
        let output = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 32_768)!
        for (index, chunk) in store.manifest.chunks.enumerated() {
            guard chunk.sequence == index, Recovery.safeChunkName(chunk.filename, sequence: index) else { throw RecorderError.message("Invalid chunk ordering.") }
            let chunkURL = store.directory.appendingPathComponent(chunk.filename)
            guard PrivateFiles.isRegular(chunkURL) else { throw RecorderError.message("Missing or unsafe recovery chunk.") }
            let reader = try AVAudioFile(forReading: chunkURL, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard Recovery.validPCM(reader, channels: store.manifest.pcmChannels), reader.length == chunk.frames else { throw RecorderError.message("Recovery chunk format/frame count changed.") }
            var remaining = chunk.frames
            while remaining > 0 {
                try reader.read(into: input, frameCount: AVAudioFrameCount(min(Int64(input.frameCapacity), remaining)))
                guard input.frameLength > 0 else { throw RecorderError.message("Unexpected end of recovery chunk.") }
                output.frameLength = input.frameLength
                for frame in 0..<Int(input.frameLength) {
                    if !store.manifest.hasSeparateTracks {
                        output.floatChannelData![0][frame] = input.floatChannelData![0][frame]
                        output.floatChannelData![1][frame] = input.floatChannelData![1][frame]
                    } else {
                        switch track {
                        case .mixed:
                            let pair = FixedMix.sample(microphone: input.floatChannelData![0][frame], left: input.floatChannelData![1][frame], right: input.floatChannelData![2][frame])
                            output.floatChannelData![0][frame] = pair.0; output.floatChannelData![1][frame] = pair.1
                        case .microphone:
                            output.floatChannelData![0][frame] = FixedMix.safe(input.floatChannelData![0][frame])
                        case .system:
                            output.floatChannelData![0][frame] = FixedMix.safe(input.floatChannelData![1][frame])
                            output.floatChannelData![1][frame] = FixedMix.safe(input.floatChannelData![2][frame])
                        }
                    }
                }
                try writer.write(from: output); remaining -= Int64(input.frameLength)
            }
        }
    }
    static func validateDelivery(_ mixed: URL, manifest: SessionManifest) throws {
        guard manifest.hasSeparateTracks else { try validate(mixed, expectedFrames: manifest.totalFrames); return }
        let directory = mixed.deletingLastPathComponent()
        guard mixed.lastPathComponent == RecordingTrack.mixed.filename,
              (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw RecorderError.message("Invalid recording track folder.")
        }
        var lengths: [Int64] = []
        if manifest.callDetails != nil {
            guard PrivateFiles.isRegular(CallDetailsStore.url(for: directory, isDirectory: true)) else {
                throw RecorderError.message("The meeting details were not delivered. Original PCM has been retained.")
            }
            _ = try CallDetailsStore.load(for: directory, isDirectory: true)
        }
        for track in RecordingTrack.allCases {
            lengths.append(try validate(directory.appendingPathComponent(track.filename), expectedFrames: manifest.totalFrames, channels: track.channels))
        }
        guard lengths.max()! - lengths.min()! <= 1 else { throw RecorderError.message("Exported tracks have different durations. Original PCM has been retained.") }
    }
    @discardableResult public static func validate(_ url: URL, expectedFrames: Int64, channels: AVAudioChannelCount = 2) throws -> Int64 {
        guard PrivateFiles.isRegular(url) else { throw RecorderError.message("Missing or unsafe exported track: \(url.lastPathComponent).") }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.fileFormat.streamDescription.pointee
        guard format.mFormatID == kAudioFormatMPEG4AAC, format.mChannelsPerFrame == channels, format.mSampleRate == 48_000,
              abs(file.length - expectedFrames) <= 4_800, file.length > 0 else {
            throw RecorderError.message("Export validation failed: expected \(channels)-channel AAC-LC, 48 kHz and \(expectedFrames) frames; found codec \(format.mFormatID), \(format.mChannelsPerFrame) channels, \(format.mSampleRate) Hz, \(file.length) frames.")
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_024)!
        for position in [Int64(0), max(0, file.length / 2 - 512), max(0, file.length - 1_024)] {
            file.framePosition = position
            let count = AVAudioFrameCount(min(1_024, file.length - position))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength == count else { throw RecorderError.message("Export could not be decoded at frame \(position).") }
            for channel in 0..<Int(channels) {
                for frame in 0..<Int(count) where !buffer.floatChannelData![channel][frame].isFinite {
                    throw RecorderError.message("Export contains invalid decoded samples.")
                }
            }
        }
        return file.length
    }
}
