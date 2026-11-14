#if canImport(XCTest)
import XCTest
#endif
import AVFoundation
@testable import RecorderCore

final class ParticipantTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("participant-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func audio(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600; buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
            try file.write(from: buffer)
        }
        try FileManager.default.moveItem(at: temporary, to: url)
    }
    private func call(_ name: String = "Call") throws -> LibraryRecording {
        try XCTUnwrap(RecordingLibraryScanner.scan(roots: [root]).recordings.first { $0.url.lastPathComponent == name })
    }
    private func input(_ name: String = "Call") -> TranscriptionInput {
        let folder = root.appendingPathComponent(name)
        return .init(tracks: [.init(source: .microphone, url: folder.appendingPathComponent("Microphone.m4a")),
                             .init(source: .system, url: folder.appendingPathComponent("System.m4a"))], outputDirectory: folder, name: name)
    }
    private func document(_ input: TranscriptionInput? = nil) throws -> Transcript {
        try .init(input: input ?? self.input(), model: SpeechModel.catalog[0], engine: "fixture", language: "en", segments: [
            .init(source: .microphone, start: 0, end: 1, text: "Hello.", timing: "word"),
            .init(source: .system, start: 2, end: 3, text: "First", timing: "word"),
            .init(source: .system, start: 3, end: 4, text: "answer.", timing: "word"),
            .init(source: .microphone, start: 5, end: 6, text: "A question.", timing: "word"),
            .init(source: .system, start: 7, end: 8, text: "Second answer.", timing: "segment")
        ])
    }
    private func savedDocument(_ textFile: URL) throws -> Transcript {
        try Transcript.read(from: textFile.deletingLastPathComponent().appendingPathComponent("Transcript.json"))
    }
    private func prepare(_ participants: [String] = []) throws -> LibraryRecording {
        try audio(root.appendingPathComponent("Call/Mixed.m4a"))
        if !participants.isEmpty { try CallDetailsStore.save(.init(participants: participants), for: call()) }
        _ = try document().save(beside: input())
        return try call()
    }

    func testSingleParticipantIsCapturedForNewTranscriptsAndNeverChangesYouOrMixedAudio() throws {
        let recording = try prepare(["Alex"]), version = try XCTUnwrap(recording.latestTranscript)
        let transcript = try XCTUnwrap(version.document)
        XCTAssertEqual(transcript.automaticParticipant, "Alex"); XCTAssertEqual(transcript.version, 3)
        XCTAssertEqual(transcript.paragraphs[1].speakerLabel(automaticParticipant: recording.automaticParticipant(for: version)), "Alex")
        XCTAssertEqual(transcript.paragraphs[0].speakerLabel(automaticParticipant: "Alex"), "You")
        XCTAssertTrue(transcript.plainText.contains("Alex: First"))
        XCTAssertTrue(transcript.readableText.contains("Alex · 00:00:02"))
        let mixed = TranscriptSegment(source: .mixed, start: 0, end: 1, text: "Two voices", timing: "segment")
        XCTAssertEqual(mixed.speakerLabel(automaticParticipant: "Alex"), "Mixed audio")
    }
    func testAddingASecondParticipantPreservesExistingAutomaticAssignmentsWithoutRewritingOriginals() throws {
        let initial = try prepare(), original = try XCTUnwrap(initial.latestTranscript)
        let bytes = try Data(contentsOf: original.url)
        try CallDetailsStore.save(.init(participants: ["Alex"]), for: initial)
        let one = try call()
        XCTAssertEqual(one.automaticParticipant(for: one.transcripts[0]), "Alex")
        try CallDetailsStore.save(.init(participants: ["Alex", "Sam"]), for: one)
        let two = try call(), old = two.transcripts[0]
        XCTAssertEqual(two.automaticParticipant(for: old), "Alex")
        XCTAssertEqual(try Data(contentsOf: original.url), bytes)
        XCTAssertTrue(old.document!.readableText(recordingName: two.name, automaticParticipant: two.automaticParticipant(for: old)).contains("Alex · 00:00:07"))
        // A run created after there are two names must not invent a speaker.
        let later = try document(); XCTAssertNil(later.automaticParticipant)
        _ = try later.save(beside: input())
        let refreshed = try call()
        XCTAssertEqual(refreshed.automaticParticipant(for: old), "Alex")
        XCTAssertNil(refreshed.automaticParticipant(for: refreshed.transcripts.first { $0.id != old.id }!))
    }
    func testPreFeatureSingleNameMetadataIsFrozenWhenSecondNameIsAdded() throws {
        let initial = try prepare(), file = CallDetailsStore.url(for: initial.url, isDirectory: true)
        try Data(#"{"version":1,"participants":["Alex"],"tags":[],"description":""}"#.utf8).write(to: file)
        let old = try call()
        XCTAssertEqual(old.automaticParticipant(for: old.transcripts[0]), "Alex")
        try CallDetailsStore.save(.init(participants: ["Sam", "Alex"]), for: old)
        let updated = try call()
        XCTAssertEqual(updated.automaticParticipant(for: updated.transcripts[0]), "Alex")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)
        // A later details edit must retain the frozen association even without names.
        try CallDetailsStore.save(.init(title: "Renamed"), for: updated)
        XCTAssertEqual(try call().automaticParticipant(for: updated.transcripts[0]), "Alex")
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNotEqual(json["automaticParticipants"] as? [String: String], nil)
    }
    func testDifferentPassagesCanBeAssignedIndependentlyAndTimingIsPreserved() throws {
        let recording = try prepare(["Alex", "Sam"]), version = recording.transcripts[0], original = version.document!
        XCTAssertNil(recording.automaticParticipant(for: version))
        let bytes = try Data(contentsOf: version.url)
        let file = try CallFileOperations.saveTranscriptEdits(original.paragraphs.map(\.text), version: version, recording: recording,
                                                            participants: [nil, "Alex", nil, "Sam"])
        let edited = try savedDocument(file)
        XCTAssertEqual(edited.segments.map(\.participant), [nil, "Alex", "Alex", nil, "Sam"])
        XCTAssertEqual(edited.segments.map(\.start), original.segments.map(\.start))
        XCTAssertEqual(edited.segments.map(\.end), original.segments.map(\.end))
        XCTAssertEqual(edited.segments.map(\.timing), original.segments.map(\.timing))
        XCTAssertEqual(edited.segments.map(\.text), original.segments.map(\.text))
        XCTAssertEqual(try Data(contentsOf: version.url), bytes)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("Sam: Second answer."))
        XCTAssertTrue(edited.readableText.contains("Alex · 00:00:02"))
        try CallDetailsStore.save(.init(), for: recording)
        let refreshed = try call()
        XCTAssertTrue(refreshed.matches("Sam")); XCTAssertEqual(refreshed.matchingPassage("Sam"), "Second answer.")
    }
    func testReassigningOnePreviouslyAutomaticPassageLeavesOtherPassagesAlone() throws {
        let initial = try prepare(["Alex"])
        try CallDetailsStore.save(.init(participants: ["Alex", "Sam"]), for: initial)
        let recording = try call(), version = recording.transcripts[0], original = version.document!
        let file = try CallFileOperations.saveTranscriptEdits(original.paragraphs.map(\.text), version: version, recording: recording,
                                                            participants: [nil, nil, nil, "Sam"])
        let edited = try savedDocument(file)
        XCTAssertEqual(edited.automaticParticipant, "Alex")
        XCTAssertEqual(edited.paragraphs[1].speakerLabel(automaticParticipant: edited.automaticParticipant), "Alex")
        XCTAssertEqual(edited.paragraphs[3].speakerLabel(automaticParticipant: edited.automaticParticipant), "Sam")
        var text = edited.paragraphs.map(\.text); text[3] = "Corrected answer."
        let corrected = try edited.editingParagraphs(text, parentVersion: "edited")
        XCTAssertEqual(corrected.paragraphs[3].participant, "Sam")
        XCTAssertEqual(corrected.automaticParticipant, "Alex")
    }
    func testExplicitUnassignedOverridesSingleNameAndSurvivesTextEdits() throws {
        let recording = try prepare(["Alex"]), version = recording.transcripts[0], original = version.document!
        let file = try CallFileOperations.saveTranscriptEdits(original.paragraphs.map(\.text), version: version, recording: recording,
                                                            participants: [nil, "", nil, nil])
        let edited = try savedDocument(file)
        XCTAssertEqual(edited.paragraphs[1].participant, "")
        XCTAssertEqual(edited.paragraphs[1].speakerLabel(automaticParticipant: "Alex"), "Other participants")
        XCTAssertEqual(edited.paragraphs[3].speakerLabel(automaticParticipant: "Alex"), "Alex")
        XCTAssertTrue(edited.readableText.contains("Other participants · 00:00:02"))
    }
    func testParagraphGroupingHonorsAssignedSpeakerBoundaries() {
        let groups = TranscriptParagraph.make(from: [
            .init(source: .system, start: 0, end: 1, text: "Alex speaks.", timing: "word", participant: "Alex"),
            .init(source: .system, start: 1, end: 2, text: "Sam responds.", timing: "word", participant: "Sam"),
            .init(source: .system, start: 2, end: 3, text: "Sam continues.", timing: "word", participant: "Sam")
        ])
        XCTAssertEqual(groups.count, 2); XCTAssertEqual(groups[1].segments.count, 2)
        XCTAssertEqual(groups.map { $0.speakerLabel() }, ["Alex", "Sam"])
    }
    func testInvalidAssignmentsAreRejectedAndOlderTranscriptsStillRead() throws {
        let recording = try prepare(), original = recording.transcripts[0].document!, text = original.paragraphs.map(\.text)
        XCTAssertNil(original.automaticParticipant); XCTAssertTrue(original.segments.allSatisfy { $0.participant == nil })
        XCTAssertThrowsError(try original.editingParagraphs(text, parentVersion: "original", participants: ["Alex", nil, nil, nil]))
        XCTAssertThrowsError(try original.editingParagraphs(text, parentVersion: "original", participants: [nil]))
        XCTAssertEqual(original.version, 2)
    }
    func testLegacySharedFoldersFreezeOnlyTheMatchingCall() throws {
        for name in ["One", "Two"] {
            let url = root.appendingPathComponent(name + ".m4a"); try audio(url)
            let input = TranscriptionInput(tracks: [.init(source: .mixed, url: url)], outputDirectory: root, name: name)
            _ = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "fixture", language: "en", segments: [
                .init(source: .mixed, start: 0, end: 1, text: name, timing: "segment")
            ]).save(beside: input)
        }
        let one = try call("One.m4a"), two = try call("Two.m4a")
        try CallDetailsStore.save(.init(participants: ["Alex"]), for: one)
        try CallDetailsStore.save(.init(participants: ["Alex", "Sam"]), for: one)
        let details = try call("One.m4a").details
        XCTAssertEqual(details.automaticParticipants?.count, 1)
        XCTAssertNil(details.automaticParticipants?[two.transcripts[0].url.deletingLastPathComponent().lastPathComponent])
        XCTAssertNil(try call("Two.m4a").automaticParticipant(for: two.transcripts[0]))
    }
}
