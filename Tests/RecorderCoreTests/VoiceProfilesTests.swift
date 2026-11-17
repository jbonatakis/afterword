#if canImport(XCTest)
import XCTest
#endif
import Foundation
@testable import RecorderCore

final class VoiceProfilesTests: XCTestCase {
    private let pat = CallAttendee(name: "Pat", email: "pat@example.test")
    private let sam = CallAttendee(name: "Sam", email: "sam@example.test")

    private func clip(_ axis: Int, start: Double = 0) -> VoiceClip {
        var vector = [Float](repeating: 0, count: 256)
        vector[axis] = 1
        return VoiceClip(interval: .init(speaker: "S1", start: start, end: start + 5), vector: vector)
    }

    func testSuggestionsRequireIndependentAgreementAttendanceAndAnotherCall() throws {
        var book = VoiceProfiles()
        try book.remember(clip(0), as: pat, call: "first")
        try book.remember(clip(1, start: 9), as: sam, call: "first")
        let queries = [clip(0), clip(0, start: 12), clip(0, start: 25)]
        var renamed = pat
        renamed.name = "Pat Smith"
        let people = [renamed, sam]
        XCTAssertEqual(book.suggestion(for: queries, among: people, excludingCall: "second")?.name, renamed.name)
        XCTAssertNil(book.suggestion(for: queries, among: people, excludingCall: "first"))
        XCTAssertNil(book.suggestion(for: [clip(0)], among: people, excludingCall: "second"))
        XCTAssertNil(book.suggestion(for: queries + [clip(1, start: 32)], among: people, excludingCall: "second"))
        XCTAssertNil(book.suggestion(for: queries + [clip(2, start: 32)], among: people, excludingCall: "second"))
        renamed.attendance = .absent
        XCTAssertNil(book.suggestion(for: queries, among: [renamed, sam], excludingCall: "second"))
        try book.remember(clip(0), as: sam, call: "other")
        XCTAssertNil(book.suggestion(for: [clip(2), clip(2, start: 20)], among: people, excludingCall: "third"))
    }

    func testClipCorrectionsPersistenceAndForgetting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try VoiceProfiles.update(in: directory) {
            try $0.remember(clip(0), as: pat, call: "a")
            try $0.remember(clip(0), as: pat, call: "a")
        }
        XCTAssertEqual(try VoiceProfiles.load(in: directory).count(for: pat), 1)
        let corrected = try VoiceProfiles.update(in: directory) { try $0.remember(clip(0), as: sam, call: "a") }
        XCTAssertEqual(corrected.count(for: pat), 0)
        XCTAssertEqual(corrected.count(for: sam), 1)
        let file = directory.appendingPathComponent(SpeakerAnalysis.modelID + ".json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        try VoiceProfiles.update(in: directory) { $0.forget(VoiceProfiles.key(for: sam)) }
        XCTAssertTrue(try VoiceProfiles.load(in: directory).people.isEmpty)
    }

    func testNoOverlappingSpeakersInSampleClips() throws {
        let turns = [SpeakerInterval(speaker: "S1", start: 0, end: 12), .init(speaker: "S2", start: 3, end: 10), .init(speaker: "S1", start: 18, end: 27)]
        let samples = SpeakerAnalysis.sampleIntervals(turns)
        XCTAssertFalse(samples.isEmpty)
        for sample in samples {
            XCTAssertFalse(turns.contains { $0.speaker != sample.speaker && $0.start < sample.end && $0.end > sample.start })
        }
        let timeline = SpeakerTimeline(turns)
        XCTAssertNil(timeline.speaker(from: 3, to: 7))
        XCTAssertEqual(timeline.speaker(from: 18, to: 19), "S1")
    }
    func testManageSavedSampleThroughAliasWithoutSourceAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var people = PeopleDirectory()
        try people.update(.init(id: "p", name: "Pat Morgan", emails: ["primary@example.test", pat.email!]))
        try people.update(.init(id: "s", name: "Sam Lee", emails: [sam.email!]))
        let original = try VoiceProfiles.update(in: folder) { try $0.remember(clip(1, start: 7), as: pat, call: "missing") }
        let sample = try XCTUnwrap(original.references.first)
        XCTAssertEqual(original.reference(for: clip(1, start: 7), call: "missing")?.person, sample.person)
        XCTAssertNil(original.reference(for: clip(1, start: 8), call: "missing"))
        XCTAssertNil(original.reference(for: clip(1, start: 7), call: "different-call"))
        let catalog = PersonVoiceLibrary(profiles: original, directory: people)
        XCTAssertEqual(catalog.items.first?.owner, "person:p")
        XCTAssertNil(catalog.items.first?.audio)
        XCTAssertEqual(original.names(in: people)["person:p"], "Pat Morgan")
        let corrected = try VoiceProfiles.update(in: folder) { try $0.change(sample, to: sam, in: people) }
        XCTAssertEqual(corrected.count(for: pat, in: people), 0)
        XCTAssertEqual(corrected.count(for: sam, in: people), 1)
        let moved = try XCTUnwrap(corrected.references.first)
        XCTAssertEqual(corrected.reference(for: clip(1, start: 7), call: "missing")?.person, "person:s")
        XCTAssertEqual(moved.vector, sample.vector); XCTAssertEqual(moved.id, sample.id)
        XCTAssertEqual(corrected.suggestion(for: [clip(1), clip(1, start: 10)], among: [pat, sam], excludingCall: "another", in: people)?.id, sam.id)
        XCTAssertThrowsError(try VoiceProfiles.update(in: folder) { try $0.change(sample, to: nil, in: people) })
        try VoiceProfiles.update(in: folder) { try $0.change(moved, to: nil, in: people) }
        XCTAssertTrue(try VoiceProfiles.load(in: folder).references.isEmpty)
    }

    func testReviewRestoresLegacyBulkChoicesOnlyWhenUnambiguous() throws {
        let file = URL(fileURLWithPath: "/fixture/review/Transcript.json")
        let input = TranscriptionInput(tracks: [.init(source: .system, url: file)], outputDirectory: file, name: "fixture")
        func segment(_ group: String, _ name: String?, bulk: Bool = true) -> TranscriptSegment {
            .init(source: .system, start: 1, end: 2, text: "Example", timing: "word",
                  participant: name, speakerGroup: group, groupAssignment: bulk ? true : nil)
        }
        let doc = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "test", language: "en", segments: [
            segment("S1", "Pat"), segment("S1", "Pat"), segment("S1", "Sam", bulk: false),
            segment("S2", "Pat"), segment("S2", "Sam"), segment("S3", "Sam", bulk: false),
            segment("S4", "Former attendee"), segment("S5", nil, bulk: false)
        ])
        let version = LibraryTranscript(url: file, document: doc, error: nil, date: Date(), fileModificationDate: Date())
        let details = CallDetails(participants: ["Pat Jones", "Sam"], participantOverrides: [version.runName: ["Pat": "Pat Jones"]])
        XCTAssertEqual(details.savedSpeakerNames(for: version), ["S1": "Pat Jones"])
    }

    func testMixedPhrasesManualAssignmentsAndReviewRoundTrip() throws {
        let source = URL(fileURLWithPath: "/fixture")
        let input = TranscriptionInput(tracks: [.init(source: .system, url: source), .init(source: .microphone, url: source)], outputDirectory: source, name: "fixture")
        let words = [TranscriptWord(text: "One.", start: 0, end: 1), .init(text: "Two.", start: 1, end: 2)]
        let doc = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "test", language: "en", segments: [
            .init(source: .system, start: 0, end: 2, text: "One. Two.", timing: "word", words: words),
            .init(source: .system, start: 3, end: 5, text: "Merged legacy phrase", timing: "word"),
            .init(source: .microphone, start: 8, end: 9, text: "Me.", timing: "word"),
            .init(source: .system, start: 9, end: 10, text: "Manual.", timing: "segment", participant: "Sam")])
        func version(_ doc: Transcript) -> LibraryTranscript { .init(url: source, document: doc, error: nil, date: Date(), fileModificationDate: Date()) }
        let details = CallDetails(participants: ["Pat", "Sam"])
        let analysis = SpeakerAnalysis(model: SpeakerAnalysis.modelID, intervals: [
            .init(speaker: "S1", start: 0, end: 1), .init(speaker: "S2", start: 1, end: 2),
            .init(speaker: "S1", start: 3, end: 4), .init(speaker: "S2", start: 4, end: 5),
            .init(speaker: "S1", start: 9, end: 10)], clips: [])
        let labeled = try SpeakerReview(analysis: analysis, names: ["S1": "Pat"]).applying(to: version(doc), details: details)
        XCTAssertEqual(labeled.segments.map(\.participant), ["Pat", nil, nil, nil, "Sam"])
        XCTAssertEqual(labeled.segments.map(\.speakerGroup), ["S1", "S2", nil, nil, "S1"])
        XCTAssertEqual(labeled.paragraphs.count, 5)
        let second = try SpeakerReview(analysis: analysis, names: ["S1": "Sam"]).applying(to: version(labeled), details: details)
        XCTAssertEqual(second.segments.first?.participant, "Sam")
        let edited = try labeled.editingParagraphs(labeled.paragraphs.map(\.text), parentVersion: "test", participants: ["Sam", nil, nil, nil, "Sam"])
        let reviewed = try SpeakerReview(analysis: analysis, names: ["S1": "Pat"]).applying(to: version(edited), details: details)
        XCTAssertEqual(reviewed.segments.first?.participant, "Sam")
    }
}
