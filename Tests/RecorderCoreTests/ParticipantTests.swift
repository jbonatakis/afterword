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

    func testSingleParticipantIsCapturedForNewTranscriptsAndNeverChangesRecorderOrMixedAudio() throws {
        let recording = try prepare(["Alex"]), version = try XCTUnwrap(recording.latestTranscript)
        let transcript = try XCTUnwrap(version.document)
        XCTAssertEqual(transcript.automaticParticipant, "Alex"); XCTAssertEqual(transcript.version, 3)
        XCTAssertEqual(transcript.paragraphs[1].speakerLabel(automaticParticipant: recording.automaticParticipant(for: version)), "Alex")
        XCTAssertEqual(transcript.paragraphs[0].speakerLabel(automaticParticipant: "Alex"), "Recorder")
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
        XCTAssertEqual(json["version"] as? Int, 4)
        // Removing the participant clears the default without reviving the embedded name.
        try CallDetailsStore.save(.init(title: "Renamed"), for: updated)
        XCTAssertNil(try call().automaticParticipant(for: updated.transcripts[0]))
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
        XCTAssertFalse(refreshed.matches("Sam")); XCTAssertNil(refreshed.matchingPassage("Sam"))
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

    func testReplacingOrRemovingSoleParticipantUpdatesEmbeddedAndFrozenDefaults() throws {
        let initial = try prepare(["Alex"]), version = initial.transcripts[0]
        let original = try Data(contentsOf: version.url)
        for names in [["Alexandra"], [], ["Sam"], ["Sam", "Taylor"]] {
            try CallDetailsStore.save(.init(participants: names), for: call())
            let current = try call()
            let expected = names.isEmpty ? "Other participants" : names[0]
            XCTAssertEqual(current.speakerLabel(for: version.document!.paragraphs[1], version: version), expected)
            XCTAssertTrue(current.readableText(for: version)!.contains("\(expected) · 00:00:02"))
            XCTAssertFalse(current.readableText(for: version)!.contains("Alex ·"))
            XCTAssertEqual(try Data(contentsOf: version.url), original)
        }
    }

    func testVersionTwoStaleDefaultUsesCurrentSoleParticipantWithoutSaving() throws {
        let initial = try prepare(["Alex"]), version = initial.transcripts[0]
        let file = CallDetailsStore.url(for: initial.url, isDirectory: true)
        let data: [String: Any] = ["version": 2, "participants": ["Sam"], "tags": [], "description": "",
                                  "automaticParticipants": [version.runName: "Alex"]]
        try JSONSerialization.data(withJSONObject: data).write(to: file)
        let repaired = try call()
        XCTAssertEqual(repaired.automaticParticipant(for: version), "Sam")
        XCTAssertTrue(repaired.readableText(for: version)!.contains("Sam · 00:00:02"))
        XCTAssertFalse(repaired.matches("Alex"))
        try CallDetailsStore.save(.init(participants: ["Sam", "Taylor"]), for: repaired)
        XCTAssertEqual(try call().automaticParticipant(for: version), "Sam")
    }

    func testRenamingManualSpeakersUpdatesCopySearchAndNewEditsWithoutChangingOriginals() throws {
        let initial = try prepare(["Alex", "Sam"]), version = initial.transcripts[0]
        _ = try CallFileOperations.saveTranscriptEdits(version.document!.paragraphs.map(\.text), version: version, recording: initial,
                                                     participants: [nil, "Alex", nil, "Sam"])
        let assigned = try call(), named = assigned.transcripts.first { $0.document?.editing != nil }!
        let bytes = try Data(contentsOf: named.url)
        try CallDetailsStore.save(.init(participants: ["Alexandra", "Samuel"]), for: assigned, participantRenames: ["Alex": "Alexandra", "Sam": "Samuel"])
        let renamed = try call()
        XCTAssertEqual(renamed.speakerLabel(for: named.document!.paragraphs[1], version: named), "Alexandra")
        XCTAssertEqual(renamed.speakerLabel(for: named.document!.paragraphs[3], version: named), "Samuel")
        XCTAssertTrue(renamed.readableText(for: named)!.contains("Samuel · 00:00:07"))
        XCTAssertEqual(renamed.matchingPassage("Samuel"), "Second answer.")
        XCTAssertEqual(try Data(contentsOf: named.url), bytes)
        var text = named.document!.paragraphs.map(\.text); text[0] = "Corrected greeting."
        let edited = try savedDocument(CallFileOperations.saveTranscriptEdits(text, version: named, recording: renamed))
        XCTAssertEqual(edited.paragraphs[1].participant, "Alexandra")
        XCTAssertEqual(edited.paragraphs[3].participant, "Samuel")
        XCTAssertTrue(edited.plainText.contains("Samuel: Second answer."))
    }

    func testRemovingManualSpeakerClearsAssignmentsAndReusingNameDoesNotRestoreThem() throws {
        let initial = try prepare(["Alex", "Sam"]), version = initial.transcripts[0]
        _ = try CallFileOperations.saveTranscriptEdits(version.document!.paragraphs.map(\.text), version: version, recording: initial,
                                                     participants: [nil, "Alex", nil, "Sam"])
        let named = try call().transcripts.first { $0.document?.editing != nil }!
        try CallDetailsStore.save(.init(participants: ["Sam"]), for: call())
        var current = try call()
        XCTAssertEqual(current.speakerLabel(for: named.document!.paragraphs[1], version: named), "Other participants")
        XCTAssertEqual(current.speakerLabel(for: named.document!.paragraphs[3], version: named), "Sam")
        XCTAssertEqual(current.automaticParticipant(for: version), "Sam")
        try CallDetailsStore.save(.init(participants: ["Sam", "Alex"]), for: current)
        current = try call()
        XCTAssertEqual(current.speakerLabel(for: named.document!.paragraphs[1], version: named), "Other participants")
        let edited = try savedDocument(CallFileOperations.saveTranscriptEdits(named.document!.paragraphs.map(\.text), version: named, recording: current))
        XCTAssertEqual(edited.paragraphs[1].participant, "")
    }

    func testRenamesAreAppliedOnceAndReorderingDoesNotChangeAssignments() throws {
        let initial = try prepare(["Alex"]), version = initial.transcripts[0]
        try CallDetailsStore.save(.init(participants: ["Alex", "Sam"]), for: initial)
        _ = try CallFileOperations.saveTranscriptEdits(version.document!.paragraphs.map(\.text), version: version, recording: call(),
                                                     participants: [nil, "Alex", nil, "Sam"])
        let named = try call().transcripts.first { $0.document?.editing != nil }!
        try CallDetailsStore.save(.init(participants: ["Sam", "Alex"]), for: call())
        XCTAssertEqual(try call().automaticParticipant(for: version), "Alex")
        // Swapping the row names is an explicit rename, not list reordering.
        try CallDetailsStore.save(.init(participants: ["Sam", "Alex"]), for: call(), participantRenames: ["Alex": "Sam", "Sam": "Alex"])
        let swapped = try call()
        XCTAssertEqual(swapped.automaticParticipant(for: version), "Sam")
        XCTAssertEqual(swapped.speakerLabel(for: named.document!.paragraphs[1], version: named), "Sam")
        XCTAssertEqual(swapped.speakerLabel(for: named.document!.paragraphs[3], version: named), "Alex")
        try CallDetailsStore.save(.init(participants: ["Sam", "Taylor"]), for: swapped, participantRenames: ["Alex": "Taylor"])
        XCTAssertEqual(try call().speakerLabel(for: named.document!.paragraphs[3], version: named), "Taylor")
    }

    func testClearedDefaultAndExplicitUnassignedSurviveSavingAndFurtherParticipantChanges() throws {
        let initial = try prepare(["Alex"]), version = initial.transcripts[0]
        try CallDetailsStore.save(.init(), for: initial)
        let edited = try savedDocument(CallFileOperations.saveTranscriptEdits(version.document!.paragraphs.map(\.text), version: version, recording: call(),
                                                                             participants: [nil, "", nil, nil]))
        XCTAssertNil(edited.automaticParticipant)
        XCTAssertFalse(edited.plainText.contains("Alex:"))
        let named = try call().transcripts.first { $0.document?.editing != nil }!
        try CallDetailsStore.save(.init(participants: ["Sam"]), for: call())
        let current = try call()
        XCTAssertEqual(current.speakerLabel(for: named.document!.paragraphs[1], version: named), "Other participants")
        XCTAssertEqual(current.speakerLabel(for: named.document!.paragraphs[3], version: named), "Sam")
        XCTAssertThrowsError(try CallDetailsStore.save(.init(participants: ["Sam"]), for: current, participantRenames: ["Missing": "Sam"]))
    }
    func testAttendanceRemovalClearsAutomaticAndManualLabelsWithoutAssigningRemainingPerson() throws {
        let initial = try prepare(["Alex"]), original = initial.transcripts[0]
        try CallDetailsStore.save(.init(participants: ["Alex", "Sam"]), for: initial)
        let two = try call()
        _ = try CallFileOperations.saveTranscriptEdits(original.document!.paragraphs.map(\.text), version: original, recording: two,
                                                      participants: [nil, "Alex", nil, "Sam"])
        let annotated = try call().transcripts.first { $0.document?.editing != nil }!
        let bytes = try Data(contentsOf: annotated.url)
        var rows = two.details.callAttendees; rows[0].attendance = .absent
        try CallDetailsStore.save(two.details.updatingAttendance(rows), for: call())
        let removed = try call()
        XCTAssertNil(removed.automaticParticipant(for: original))
        XCTAssertEqual(removed.speakerLabel(for: annotated.document!.paragraphs[1], version: annotated), "Other participants")
        XCTAssertEqual(removed.speakerLabel(for: annotated.document!.paragraphs[3], version: annotated), "Sam")
        XCTAssertEqual(try Data(contentsOf: annotated.url), bytes)
        rows[0].attendance = .expected
        try CallDetailsStore.save(removed.details.updatingAttendance(rows), for: removed)
        let restored = try call()
        XCTAssertNil(restored.automaticParticipant(for: original))
        XCTAssertEqual(restored.speakerLabel(for: annotated.document!.paragraphs[1], version: annotated), "Other participants")
        XCTAssertEqual(restored.details.participants, ["Alex", "Sam"])
    }
    func testCalendarIdentityLinksSurviveDetailsEditorRenameRemovalAndRestore() throws {
        let initial = try prepare(["Alex"])
        let alex = CallAttendee(name: "Alex", email: "alex@example.com")
        try CallDetailsStore.save(.init(participants: ["Alex"], attendees: [alex], allowSingleParticipantInference: true), for: initial)
        try CallDetailsStore.save(.init(participants: ["Alexander"]), for: call(), participantRenames: ["Alex": "Alexander"])
        let renamed = try call()
        XCTAssertEqual(renamed.details.callAttendees.first?.id, alex.id)
        XCTAssertEqual(renamed.details.callAttendees.first?.email, "alex@example.com")
        XCTAssertEqual(renamed.details.callAttendees.first?.name, "Alexander")
        try CallDetailsStore.save(.init(participants: []), for: renamed)
        let removed = try call()
        XCTAssertEqual(removed.details.callAttendees.first?.attendance, .absent)
        XCTAssertNil(removed.details.inferredParticipant)
        try CallDetailsStore.save(.init(participants: ["Alexander"]), for: removed)
        let restored = try call()
        XCTAssertEqual(restored.details.callAttendees.first?.id, alex.id)
        XCTAssertNil(restored.details.inferredParticipant)
        XCTAssertNil(restored.automaticParticipant(for: restored.transcripts[0]))
    }

}
