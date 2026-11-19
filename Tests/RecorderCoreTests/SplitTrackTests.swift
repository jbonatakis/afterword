#if canImport(XCTest)
import XCTest
#endif
import AVFoundation
@testable import RecorderCore

final class SplitTrackTests: XCTestCase {
    var root: URL!
    var destination: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SplitTrackTests-\(UUID().uuidString)")
        destination = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func makeStore(separateTracks: Bool = true, callDetails: CallDetails? = nil, balanceMix: Bool = false) throws -> SessionStore {
        let device = InputDevice(objectID: 1, uid: "fixture", name: "Fixture", channels: ["Mic"], bufferChannels: [1], sampleRate: 48_000)
        var manifest = SessionManifest(input: ResolvedInput(device: device, channel: 0, selection: .systemDefault), formats: [], destination: destination, separateTracks: separateTracks, callDetails: callDetails, balanceMix: balanceMix)
        if !separateTracks { manifest.applicationVersion = "0.1.0" }
        return try SessionStore(root: root.appendingPathComponent("sessions"), manifest: manifest)
    }
    func fill(_ store: SessionStore, microphoneEnabled: Bool = true) throws {
        let buffer = AVAudioPCMBuffer(pcmFormat: store.format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        for offset in stride(from: 0, to: 96_000, by: 8_000) {
            for frame in 0..<8_000 {
                let time = offset + frame
                let audible = time >= 4_800 && time < 91_200
                func tone(_ frequency: Double, gain: Float) -> Float {
                    audible ? gain * Float(sin(2 * .pi * frequency * Double(time) / 48_000)) : 0
                }
                buffer.floatChannelData![0][frame] = microphoneEnabled && !(48_000..<72_000).contains(time) ? tone(440, gain: 0.2) : 0
                buffer.floatChannelData![1][frame] = tone(880, gain: 0.4)
                if store.manifest.hasSeparateTracks { buffer.floatChannelData![2][frame] = tone(1_320, gain: 0.3) }
            }
            try store.append(buffer)
        }
        try store.finish()
    }
    func read(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
        try file.read(into: buffer)
        return buffer
    }
    func amplitude(_ buffer: AVAudioPCMBuffer, channel: Int, frequency: Double, start: Int = 9_600) -> Double {
        var real = 0.0, imaginary = 0.0
        for frame in start..<(start + 9_600) {
            let phase = 2 * .pi * frequency * Double(frame) / 48_000
            let value = Double(buffer.floatChannelData![channel][frame])
            real += value * cos(phase); imaginary += value * sin(phase)
        }
        return 2 * hypot(real, imaginary) / 9_600
    }
    func testPersonalScopeSurvivesRecoveryExportAndMetadataEdits() throws {
        let store = try makeStore(callDetails: .init(title: "Appointment"))
        try fill(store)
        try store.setCallScope(.personal)
        let recovered = try Recovery.load(directory: store.directory)
        XCTAssertEqual(recovered.manifest.callDetails?.scope, .personal)
        let audio = try Exporter.export(recovered)
        let folder = audio.deletingLastPathComponent()
        let recording = try XCTUnwrap(RecordingLibraryScanner.scan(roots: [folder]).recordings.first)
        XCTAssertEqual(recording.details.title, "Appointment")
        XCTAssertEqual(recording.details.scope, .personal)
        XCTAssertTrue(try recording.agentSummaryRequest().contains("scope personal"))
        let edited = try CallDetailsStore.save(.init(title: "New title"), for: recording)
        XCTAssertEqual(edited.scope, .personal)
        try CallDetailsStore.setScope(.work, for: recording)
        let current = try CallDetailsStore.load(for: folder, isDirectory: true)
        XCTAssertEqual(current.title, "New title")
        XCTAssertEqual(current.scope, .work)
    }

    func testExportsIsolatedSourcesStereoMixMuteAndMatchingDurations() throws {
        let store = try makeStore(); try fill(store)
        let mixedURL = try Exporter.export(store)
        let folder = mixedURL.deletingLastPathComponent()
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), Set(RecordingTrack.allCases.map(\.filename)))
        let mic = try read(folder.appendingPathComponent("Microphone.m4a"))
        let system = try read(folder.appendingPathComponent("System.m4a"))
        let mix = try read(mixedURL)
        XCTAssertEqual(mic.format.channelCount, 1); XCTAssertEqual(system.format.channelCount, 2)
        XCTAssertEqual(mic.frameLength, system.frameLength); XCTAssertEqual(mic.frameLength, mix.frameLength)
        XCTAssertEqual(Double(mic.frameLength), 96_000, accuracy: 1)
        XCTAssertEqual(amplitude(mic, channel: 0, frequency: 440), 0.2, accuracy: 0.015)
        XCTAssertEqual(amplitude(mic, channel: 0, frequency: 880), 0, accuracy: 0.003)
        XCTAssertEqual(amplitude(mic, channel: 0, frequency: 1_320), 0, accuracy: 0.003)
        XCTAssertEqual(amplitude(system, channel: 0, frequency: 880), 0.4, accuracy: 0.015)
        XCTAssertEqual(amplitude(system, channel: 1, frequency: 1_320), 0.3, accuracy: 0.015)
        XCTAssertEqual(amplitude(system, channel: 0, frequency: 440), 0, accuracy: 0.003)
        XCTAssertEqual(amplitude(system, channel: 1, frequency: 880), 0, accuracy: 0.003)
        XCTAssertEqual(amplitude(mix, channel: 0, frequency: 440), 0.1, accuracy: 0.015)
        XCTAssertEqual(amplitude(mix, channel: 1, frequency: 440), 0.1, accuracy: 0.015)
        XCTAssertEqual(amplitude(mix, channel: 0, frequency: 880), 0.2, accuracy: 0.015)
        XCTAssertEqual(amplitude(mix, channel: 1, frequency: 1_320), 0.15, accuracy: 0.015)
        XCTAssertEqual(amplitude(mic, channel: 0, frequency: 440, start: 57_600), 0, accuracy: 0.0001)
        XCTAssertEqual(amplitude(mix, channel: 0, frequency: 440, start: 57_600), 0, accuracy: 0.003)
        XCTAssertEqual(amplitude(system, channel: 0, frequency: 880, start: 57_600), 0.4, accuracy: 0.015)
        for track in RecordingTrack.allCases {
            let file = folder.appendingPathComponent(track.filename)
            let buffer = try read(file)
            for channel in 0..<Int(buffer.format.channelCount) {
                XCTAssertTrue((0..<3_000).allSatisfy { abs(buffer.floatChannelData![channel][$0]) < 0.005 })
                XCTAssertTrue((93_000..<Int(buffer.frameLength)).allSatisfy { abs(buffer.floatChannelData![channel][$0]) < 0.005 })
            }
            let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue
            XCTAssertEqual(mode & 0o777, 0o600)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
    func testFinalTrackEncoderFailurePublishesNothingAndRecoveryRetriesAllTracks() throws {
        let store = try makeStore(); try fill(store)
        var attempted: [RecordingTrack] = []
        XCTAssertThrowsError(try Exporter.export(store) { store, track, url in
            attempted.append(track)
            if track == .system { throw RecorderError.message("Injected final-track failure") }
            try Exporter.encode(store, track: track, to: url)
        })
        XCTAssertEqual(attempted, [.mixed, .microphone, .system])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("chunk-000000.caf").path))
        let recovered = try Recovery.load(directory: store.directory)
        let url = try Exporter.export(recovered)
        try Exporter.validateDelivery(url, manifest: recovered.manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
    func testVersionOneStereoSessionsRemainRecoverableWithoutInventedSourceTracks() throws {
        let store = try makeStore(separateTracks: false); try fill(store)
        let recovered = try Recovery.load(directory: store.directory)
        XCTAssertEqual(recovered.manifest.version, 1)
        XCTAssertEqual(recovered.format.channelCount, 2)
        let url = try Exporter.export(recovered)
        XCTAssertEqual(url.deletingLastPathComponent().path, destination.path)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Call-"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 1)
        try Exporter.validate(url, expectedFrames: 96_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
    func testMissingDeliveredTrackPreservesPCMAndReexportsCompleteSet() throws {
        let store = try makeStore(); try fill(store)
        // Simulate interruption after the delivery checkpoint but before PCM cleanup.
        let old = destination.appendingPathComponent("EarlierDelivery", isDirectory: true)
        try PrivateFiles.directory(old)
        for track in RecordingTrack.allCases {
            let url = old.appendingPathComponent(track.filename)
            try PrivateFiles.create(url); try Exporter.encode(store, track: track, to: url)
        }
        let oldMix = old.appendingPathComponent("Mixed.m4a")
        try store.delivered(to: oldMix)
        let before = try Data(contentsOf: oldMix)
        try FileManager.default.removeItem(at: old.appendingPathComponent("Microphone.m4a"))
        XCTAssertThrowsError(try store.removeAfterDelivery())
        let recovered = try Recovery.load(directory: store.directory)
        let repaired = try Exporter.export(recovered)
        XCTAssertNotEqual(repaired, oldMix)
        try Exporter.validateDelivery(repaired, manifest: recovered.manifest)
        XCTAssertEqual(try Data(contentsOf: oldMix), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
    func testRecoveryRejectsWrongChannelSchemaAndRetainsOriginalChunk() throws {
        for separate in [true, false] {
            let store = try makeStore(separateTracks: separate)
            let chunk = store.directory.appendingPathComponent("chunk-000000.caf")
            let wrongFormat = separate ? SessionStore.pcmFormat : SessionStore.sourcePCMFormat
            do {
                var settings = wrongFormat.settings; settings[AVLinearPCMIsNonInterleaved] = false
                let file = try AVAudioFile(forWriting: chunk, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100)!
                pcm.frameLength = 100
                for channel in 0..<Int(pcm.format.channelCount) { pcm.floatChannelData![channel].initialize(repeating: 0, count: 100) }
                try file.write(from: pcm)
            }
            let recovered = try Recovery.load(directory: store.directory)
            XCTAssertEqual(recovered.manifest.totalFrames, 0)
            XCTAssertEqual(recovered.manifest.retainRecoveryFiles, true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path))
        }
    }
    func testEntirelyMutedMicrophoneStillExportsSilentTrackOfFullDuration() throws {
        let store = try makeStore(); try fill(store, microphoneEnabled: false)
        let mixedURL = try Exporter.export(store)
        let mic = try read(mixedURL.deletingLastPathComponent().appendingPathComponent("Microphone.m4a"))
        let system = try read(mixedURL.deletingLastPathComponent().appendingPathComponent("System.m4a"))
        XCTAssertEqual(mic.frameLength, system.frameLength)
        XCTAssertTrue((0..<Int(mic.frameLength)).allSatisfy { abs(mic.floatChannelData![0][$0]) < 0.0001 })
        XCTAssertEqual(amplitude(system, channel: 0, frequency: 880), 0.4, accuracy: 0.015)
    }
    func testRecoveredCalendarRecordingPublishesDetailsWithAudioBeforeTranscription() throws {
        let meeting = MeetingReference(occurrenceID: "fixture", title: "One to one", start: Date(timeIntervalSince1970: 1800000000),
                                       end: Date(timeIntervalSince1970: 1800001800), calendar: "Work", joinURL: URL(string: "https://meet.google.com/abc-defg-hij")!)
        let details = CallDetails(title: meeting.title, participants: ["Avery"], attendees: [.init(name: "Avery", email: "avery@example.com")],
                                  allowSingleParticipantInference: true, meeting: meeting)
        let store = try makeStore(callDetails: details); try fill(store)
        let recovered = try Recovery.load(directory: store.directory)
        XCTAssertEqual(recovered.manifest.callDetails, details)
        let mix = try Exporter.export(recovered), folder = mix.deletingLastPathComponent()
        XCTAssertEqual(try CallDetailsStore.load(for: folder, isDirectory: true), details)
        let input = TranscriptionInput(tracks: [.init(source: .system, url: folder.appendingPathComponent("System.m4a"))], outputDirectory: folder, name: "Call")
        XCTAssertEqual(CallDetailsStore.singleParticipant(for: input), "Avery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
    func testMissingDeliveredMeetingDetailsRetainsRecoveryPCM() throws {
        let details = CallDetails(title: "Calendar call", participants: ["Avery"])
        let store = try makeStore(callDetails: details); try fill(store)
        let old = destination.appendingPathComponent("IncompleteMeeting", isDirectory: true)
        try PrivateFiles.directory(old)
        for track in RecordingTrack.allCases {
            let url = old.appendingPathComponent(track.filename)
            try PrivateFiles.create(url); try Exporter.encode(store, track: track, to: url)
        }
        let mixed = old.appendingPathComponent("Mixed.m4a")
        try store.delivered(to: mixed)
        XCTAssertThrowsError(try store.removeAfterDelivery())
        let recovered = try Recovery.load(directory: store.directory)
        let repaired = try Exporter.export(recovered)
        XCTAssertNotEqual(repaired, mixed)
        XCTAssertEqual(try CallDetailsStore.load(for: repaired.deletingLastPathComponent(), isDirectory: true), details)
    }

}
