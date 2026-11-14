#if canImport(XCTest)
import XCTest
#endif
import AVFoundation
import CryptoKit
@testable import RecorderCore

final class TranscriptionTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("asr-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func audio(_ name: String, channels: AVAudioChannelCount, frames: AVAudioFrameCount = 1600) throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) { buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(frames)) }
        try file.write(from: buffer); return url
    }
    private func fakeModel(_ data: Data) -> SpeechModel {
        SpeechModel(id: "test", name: "Test", detail: "", repository: "test/test", revision: "test", filename: "test.gguf", bytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), licenseURL: URL(string: "https://example.com")!)
    }
    func testModelVerificationRejectsSameSizeCorruptionAndCancellation() throws {
        let data = Data("GGUFvalid-model-fixture".utf8), model = fakeModel(Data("GGUFvalid-model-fixture".utf8))
        let url = root.appendingPathComponent("test.gguf"); try data.write(to: url)
        XCTAssertNoThrow(try ModelStore.verify(url, model: model))
        XCTAssertThrowsError(try ModelStore.verify(url, model: model, cancelled: { true }))
        var corrupt = data; corrupt[10] ^= 1; try corrupt.write(to: url)
        XCTAssertThrowsError(try ModelStore.verify(url, model: model))
        try data.prefix(5).write(to: url)
        XCTAssertThrowsError(try ModelStore.verify(url, model: model))
    }
    func testSharedModelDiscoveryNeverDeletesHandysCopy() throws {
        let data = Data("GGUFvalid-model-fixture".utf8), model = fakeModel(Data("GGUFvalid-model-fixture".utf8))
        let shared = root.appendingPathComponent(".cache/huggingface/hub/models--test--test/snapshots/rev/test.gguf")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        let blob = root.appendingPathComponent("blob"); try data.write(to: blob)
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: blob)
        let owned = root.appendingPathComponent("owned")
        let found = try XCTUnwrap(ModelStore.find(model, root: owned, home: root))
        XCTAssertTrue(found.shared); XCTAssertEqual(found.url.resolvingSymlinksInPath(), shared.resolvingSymlinksInPath())
        XCTAssertThrowsError(try ModelStore.remove(model, root: owned))
        XCTAssertEqual(try Data(contentsOf: shared), data)
    }
    func testSourcePairWinsOverMixedAndRejectsMismatchedTimelines() throws {
        // CAF content uses recorder filenames to exercise resolution independently of AAC codecs.
        let micCAF = try audio("mic.caf", channels: 1), systemCAF = try audio("system.caf", channels: 2)
        let mic = root.appendingPathComponent("Microphone.m4a"), system = root.appendingPathComponent("System.m4a")
        try FileManager.default.moveItem(at: micCAF, to: mic)
        try FileManager.default.moveItem(at: systemCAF, to: system)
        let mixed = root.appendingPathComponent("Mixed.m4a"); try Data().write(to: mixed)
        let input = try TranscriptionInput.resolve(mixed)
        XCTAssertEqual(input.tracks.map(\.source), [.microphone, .system])
        XCTAssertFalse(input.tracks.contains { $0.path == mixed.path })
        try FileManager.default.removeItem(at: system)
        XCTAssertThrowsError(try TranscriptionInput.resolve(root))
        let mismatch = try audio("different.caf", channels: 2, frames: 2000)
        try FileManager.default.moveItem(at: mismatch, to: system)
        XCTAssertThrowsError(try TranscriptionInput.resolve(root))
    }
    func testOldRecordingGetsNoInventedSpeakerIdentity() throws {
        let file = try audio("old.caf", channels: 2)
        let input = try TranscriptionInput.resolve(file)
        XCTAssertEqual(input.tracks.map(\.source), [.mixed])
        let wrong = TranscriptSegment(source: .microphone, start: 0, end: 1, text: "Hello", timing: "word")
        XCTAssertThrowsError(try Transcript(input: input, model: SpeechModel.catalog[0], engine: "test", language: "auto", segments: [wrong]))
    }
    func testMergePreservesOverlapsAndPublishesBothFilesWithoutOverwrite() throws {
        let input = TranscriptionInput(tracks: [.init(source: .microphone, url: root.appendingPathComponent("Microphone.m4a")), .init(source: .system, url: root.appendingPathComponent("System.m4a"))], outputDirectory: root, name: "Test call")
        let rows = [TranscriptSegment(source: .microphone, start: 5, end: 8, text: "My response", timing: "word"), .init(source: .system, start: 4, end: 7, text: "Their question", timing: "segment")]
        let transcript = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "test", language: "auto", segments: rows)
        XCTAssertEqual(transcript.segments.map(\.start), [4, 5]); XCTAssertEqual(transcript.segments.map(\.end), [7, 8])
        let first = try transcript.save(beside: input), second = try transcript.save(beside: input)
        XCTAssertNotEqual(first, second)
        let json = try Data(contentsOf: first.deletingLastPathComponent().appendingPathComponent("Transcript.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Transcript.self, from: json).segments, transcript.segments)
        XCTAssertTrue(try String(contentsOf: first).contains("Other participants: Their question"))
        XCTAssertTrue(try String(contentsOf: second).contains("You: My response"))
        let mode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Transcripts").path).contains { $0.hasPrefix(".pending") })
    }
    func testInvalidTimestampsAreNotPublished() throws {
        let input = try TranscriptionInput.resolve(audio("old.caf", channels: 1))
        for (a, b) in [(-1.0, 2.0), (2.0, 1.0), (Double.nan, 1.0), (0.0, Double.infinity)] {
            XCTAssertThrowsError(try Transcript(input: input, model: SpeechModel.catalog[0], engine: "test", language: "auto", segments: [.init(source: .mixed, start: a, end: b, text: "Invalid", timing: "word")]))
        }
    }
    func testBleedReductionDefaultsOnAndExplicitOffSurvivesReload() throws {
        let name = "CallRecorder-EchoPreferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(SpeakerBleedReduction.preference(in: defaults))
        defaults.set(false, forKey: SpeakerBleedReduction.preferenceKey)
        XCTAssertFalse(SpeakerBleedReduction.preference(in: try XCTUnwrap(UserDefaults(suiteName: name))))
        defaults.set(true, forKey: SpeakerBleedReduction.preferenceKey)
        XCTAssertTrue(SpeakerBleedReduction.preference(in: defaults))
    }
    func testCleanupNeedsSeparateTracksAndHonorsExplicitOff() throws {
        let pair = TranscriptionInput(tracks: [.init(source: .microphone, url: root.appendingPathComponent("Microphone.m4a")), .init(source: .system, url: root.appendingPathComponent("System.m4a"))], outputDirectory: root, name: "Call")
        let old = try TranscriptionInput.resolve(audio("old.caf", channels: 2))
        XCTAssertEqual(SpeakerBleedReduction.resolve(enabled: true, input: pair), .enabled)
        XCTAssertEqual(SpeakerBleedReduction.resolve(enabled: false, input: pair), .disabled)
        XCTAssertEqual(SpeakerBleedReduction.resolve(enabled: true, input: old), .unavailable)
        XCTAssertEqual(SpeakerBleedReduction.resolve(enabled: false, input: old), .disabled)
    }
    func testWorkerCannotSilentlyIgnoreCleanupOrClaimItWithoutMetadata() throws {
        func result(_ json: String) throws -> TranscriptionCompletion { try JSONDecoder().decode(TranscriptionCompletion.self, from: Data(json.utf8)) }
        let off = try result(#"{"engine":"test","speakerBleedReductionApplied":false}"#)
        XCTAssertThrowsError(try off.validate(expected: .enabled))
        XCTAssertNoThrow(try off.validate(expected: .disabled))
        XCTAssertNoThrow(try off.validate(expected: .unavailable))
        let unconfirmed = try result(#"{"engine":"test","speakerBleedReductionApplied":true}"#)
        XCTAssertThrowsError(try unconfirmed.validate(expected: .enabled))
        let on = try result(#"{"engine":"test","speakerBleedReductionApplied":true,"echoCancellation":{"engine":"WebRTC AEC3","sampleRate":16000,"referenceLookaheadMilliseconds":40}}"#)
        XCTAssertNoThrow(try on.validate(expected: .enabled))
        XCTAssertThrowsError(try on.validate(expected: .disabled))
        XCTAssertThrowsError(try result(#"{"engine":"old worker"}"#))
    }
    func testProcessingMetadataRoundTripAndOldTranscriptCompatibility() throws {
        let input = try TranscriptionInput.resolve(audio("old.caf", channels: 1))
        let transcript = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "test", language: "auto", segments: [], speakerBleedReduction: .unavailable)
        XCTAssertTrue(transcript.plainText.contains("Not applied (separate microphone and system tracks required)"))
        let encoded = try JSONEncoder().encode(transcript)
        XCTAssertEqual(try JSONDecoder().decode(Transcript.self, from: encoded).speakerBleedReduction, .unavailable)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "speakerBleedReduction"); legacy.removeValue(forKey: "echoCancellation"); legacy["version"] = 1
        let old = try JSONDecoder().decode(Transcript.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.speakerBleedReduction); XCTAssertNil(old.echoCancellation)
        XCTAssertFalse(old.plainText.contains("Speaker bleed reduction:"))
    }
}
