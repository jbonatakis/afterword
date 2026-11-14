#if canImport(XCTest)
import XCTest
#endif
import AVFoundation
@testable import RecorderCore

final class LibraryTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("library-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func audio(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600; buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
            try file.write(from: buffer)
        }
        try FileManager.default.moveItem(at: temporary, to: url)
    }
    @discardableResult private func transcript(in folder: URL, name: String, run: String = "run", text: String = "A searchable decision.") throws -> URL {
        let input = TranscriptionInput(tracks: [.init(source: .mixed, url: root.appendingPathComponent(name + ".m4a"))], outputDirectory: folder, name: name)
        let transcript = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "test", language: "auto", segments: [
            .init(source: .mixed, start: 0, end: 0.05, text: text, timing: "word")
        ])
        let directory = folder.appendingPathComponent("Transcripts/" + run)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Transcript.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(transcript)) as? [String: Any])
        json["createdAt"] = "2026-01-01T00:00:00Z"
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    func testParagraphsJoinFragmentsButPreserveSpeakerChangesPausesAndTimings() throws {
        let segments: [TranscriptSegment] = [
            .init(source: .microphone, start: 0, end: 1, text: " First sentence.", timing: "word"),
            .init(source: .microphone, start: 1.1, end: 2, text: "Second sentence. ", timing: "word"),
            .init(source: .system, start: 1.5, end: 3, text: "An overlapping response.", timing: "segment"),
            .init(source: .microphone, start: 3, end: 4, text: "My reply.", timing: "word"),
            .init(source: .microphone, start: 9, end: 10, text: "After a pause.", timing: "word")
        ]
        let paragraphs = TranscriptParagraph.make(from: segments.reversed())
        XCTAssertEqual(paragraphs.count, 4)
        XCTAssertEqual(paragraphs[0].text, "First sentence. Second sentence.")
        XCTAssertEqual(paragraphs[0].segments, Array(segments.prefix(2)))
        XCTAssertEqual(paragraphs.flatMap(\.segments), segments)
        XCTAssertEqual(paragraphs[1].start, 1.5)
        XCTAssertEqual(paragraphs[1].source, .system)
    }
    func testLongTurnsHaveBoundedParagraphsAndEmptyFragmentsAreIgnored() {
        let long = String(repeating: "word ", count: 80)
        let paragraphs = TranscriptParagraph.make(from: [
            .init(source: .system, start: 0, end: 20, text: long, timing: "segment"),
            .init(source: .system, start: 20, end: 40, text: long, timing: "segment"),
            .init(source: .system, start: 40, end: 80, text: "Another thought.", timing: "chunk"),
            .init(source: .system, start: 80, end: 81, text: "  \n", timing: "word")
        ])
        XCTAssertEqual(paragraphs.count, 3)
        XCTAssertEqual(paragraphs.flatMap(\.segments).count, 3)
    }
    func testScannerFindsSplitAndLegacyRecordingsWithoutDuplicateTracksOrStaging() throws {
        let call = root.appendingPathComponent("Call-2026-11-13_12-00-00")
        for track in RecordingTrack.allCases { try audio(call.appendingPathComponent(track.filename)) }
        try audio(root.appendingPathComponent("Call-2026-11-12_10-00-00.m4a"))
        try audio(root.appendingPathComponent(".Call-pending/Mixed.m4a"))
        try audio(root.appendingPathComponent("unrelated/nested/Call/Mixed.m4a"))
        let scan = RecordingLibraryScanner.scan(roots: [root, call, root])
        XCTAssertEqual(scan.recordings.count, 2)
        XCTAssertEqual(scan.recordings[0].name, call.lastPathComponent)
        XCTAssertEqual(scan.recordings[0].tracks.map(\.source), [.mixed, .microphone, .system])
        XCTAssertEqual(scan.recordings[1].tracks.count, 1)
        XCTAssertEqual(try XCTUnwrap(scan.recordings[0].duration), 0.1, accuracy: 0.001)
        XCTAssertTrue(scan.issues.isEmpty)
    }
    func testLegacyTranscriptsAreMatchedToTheirOwnRecording() throws {
        try audio(root.appendingPathComponent("One.m4a")); try audio(root.appendingPathComponent("Two.m4a"))
        try transcript(in: root, name: "One", run: "one", text: "Only the first meeting.")
        try transcript(in: root, name: "Two", run: "two", text: "Only the second meeting.")
        let recordings = RecordingLibraryScanner.scan(roots: [root]).recordings
        let one = try XCTUnwrap(recordings.first { $0.name == "One" })
        let two = try XCTUnwrap(recordings.first { $0.name == "Two" })
        XCTAssertEqual(one.transcripts.count, 1); XCTAssertEqual(two.transcripts.count, 1)
        XCTAssertTrue(one.matches("FIRST meeting")); XCTAssertFalse(two.matches("first meeting"))
    }
    func testAllTranscriptVersionsAreSearchableAndCorruptionIsVisible() throws {
        let call = root.appendingPathComponent("Call-2026-11-13_12-00-00")
        try audio(call.appendingPathComponent("Mixed.m4a"))
        let original = try transcript(in: call, name: call.lastPathComponent, run: "older", text: "Keep the café project.")
        let originalData = try Data(contentsOf: original)
        let invalid = call.appendingPathComponent("Transcripts/newer/Transcript.json")
        try FileManager.default.createDirectory(at: invalid.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: invalid)
        try transcript(in: call, name: call.lastPathComponent, run: ".pending-hidden", text: "Never publish this.")
        let recording = try XCTUnwrap(RecordingLibraryScanner.scan(roots: [root]).recordings.first)
        XCTAssertEqual(recording.transcripts.count, 2)
        XCTAssertNil(recording.latestTranscript?.document)
        XCTAssertNotEqual(recording.latestTranscript?.error, nil)
        XCTAssertTrue(recording.hasTranscript)
        XCTAssertTrue(recording.matches("CAFE project"))
        XCTAssertFalse(recording.matches("Never publish"))
        XCTAssertEqual(recording.matchingPassage("café"), "Keep the café project.")
        XCTAssertEqual(try Data(contentsOf: original), originalData)
    }
    func testMissingFolderIsReportedAndRemovedRecordingDisappears() throws {
        let url = root.appendingPathComponent("Call.m4a")
        try audio(url)
        XCTAssertEqual(RecordingLibraryScanner.scan(roots: [root]).recordings.count, 1)
        try FileManager.default.removeItem(at: url)
        let scan = RecordingLibraryScanner.scan(roots: [root, root.appendingPathComponent("missing")])
        XCTAssertTrue(scan.recordings.isEmpty); XCTAssertEqual(scan.issues.count, 1)
    }
    func testReaderRejectsInvalidTimingsAndUnsupportedVersions() throws {
        let url = try transcript(in: root, name: "Test")
        let original = try Data(contentsOf: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["version"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try Transcript.read(from: url))
        json["version"] = 1
        json["segments"] = [["source": "mixed", "start": -1, "end": 2, "text": "Invalid", "timing": "word"]]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try Transcript.read(from: url))
        try original.write(to: url)
        XCTAssertTrue(try Transcript.read(from: url).readableText.contains("Mixed audio · 00:00:00\nA searchable decision."))
    }
}
