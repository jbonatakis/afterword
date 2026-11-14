#if canImport(XCTest)
import XCTest
#endif
import AVFoundation
@testable import RecorderCore

final class CallManagementTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("call-management-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func audio(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative), temporary = root.appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600; buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
            try file.write(from: buffer)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: url)
        return url
    }
    private func call(_ name: String) throws -> LibraryRecording {
        try XCTUnwrap(RecordingLibraryScanner.scan(roots: [root]).recordings.first { $0.url.lastPathComponent == name })
    }
    @discardableResult private func transcript(_ audio: URL) throws -> URL {
        let resolved = try TranscriptionInput.resolve(audio)
        let input = TranscriptionInput(tracks: [.init(source: .mixed, url: audio),
            .init(source: .microphone, url: audio.deletingLastPathComponent().appendingPathComponent("Microphone.m4a")),
            .init(source: .system, url: audio.deletingLastPathComponent().appendingPathComponent("System.m4a"))],
            outputDirectory: resolved.outputDirectory, name: resolved.name)
        let document = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "fixture", language: "en", segments: [
            .init(source: .microphone, start: 0, end: 1, text: "First", timing: "word"),
            .init(source: .microphone, start: 1, end: 2, text: "thought.", timing: "word"),
            .init(source: .system, start: 1.5, end: 4, text: "Other speaker.", timing: "segment"),
            .init(source: .microphone, start: 8, end: 10, text: "Remove this.", timing: "segment")
        ])
        return try document.save(beside: input).deletingLastPathComponent().appendingPathComponent("Transcript.json")
    }
    private func fixtureTrash(_ url: URL) throws -> URL {
        let trash = root.appendingPathComponent(".trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    func testDetailsPersistNormalizeAndSearchWithoutRenamingAudioOrTranscripts() throws {
        let audio = try audio("Call/Mixed.m4a"), json = try transcript(audio)
        let bytes = try Data(contentsOf: audio), original = try Data(contentsOf: json)
        let before = try call("Call")
        try CallDetailsStore.save(.init(title: "  Product planning  ", participants: [" Jack ", "Alex", "jack"],
                                        tags: [" roadmap", "Roadmap", "", "Q4"], description: " Decisions and next steps \n"), for: before)
        let after = try call("Call")
        XCTAssertEqual(after.id, before.id); XCTAssertEqual(after.name, "Product planning")
        XCTAssertEqual(after.sourceName, "Call")
        XCTAssertEqual(after.details.participants, ["Jack", "Alex"]); XCTAssertEqual(after.details.tags, ["roadmap", "Q4"])
        XCTAssertEqual(after.details.description, "Decisions and next steps")
        for query in ["product", "Alex", "roadmap", "next steps", "Call"] { XCTAssertTrue(after.matches(query)) }
        XCTAssertEqual(try Data(contentsOf: audio), bytes); XCTAssertEqual(try Data(contentsOf: json), original)
        XCTAssertTrue(try Transcript.read(from: json).readableText(recordingName: after.name).hasPrefix("Product planning\n"))
    }
    func testUnreadableOrNewerDetailsAreVisibleAndNeverOverwritten() throws {
        _ = try audio("Call/Mixed.m4a")
        let recording = try call("Call"), file = CallDetailsStore.url(for: recording.url, isDirectory: true)
        for bytes in [Data("invalid".utf8), Data(#"{"version":99,"title":"Future","participants":[],"tags":[],"description":""}"#.utf8)] {
            try bytes.write(to: file)
            let scanned = try call("Call")
            XCTAssertNotEqual(scanned.detailsError, nil); XCTAssertEqual(scanned.name, "Call")
            XCTAssertThrowsError(try CallDetailsStore.save(.init(title: "Replace"), for: recording))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }
    func testEditsPreserveOriginalProvenanceSourcesAndAudioIntervals() throws {
        let audio = try audio("Call/Mixed.m4a"), json = try transcript(audio)
        let bytes = try Data(contentsOf: json), recording = try call("Call")
        let version = try XCTUnwrap(recording.latestTranscript), original = try XCTUnwrap(version.document)
        let text = ["A corrected thought.", original.paragraphs[1].text, "   "]
        let saved = try CallFileOperations.saveTranscriptEdits(text, version: version, recording: recording)
        let edited = try Transcript.read(from: saved.deletingLastPathComponent().appendingPathComponent("Transcript.json"))
        XCTAssertEqual(try Data(contentsOf: json), bytes)
        XCTAssertEqual(edited.segments.count, 2)
        XCTAssertEqual(edited.segments[0], .init(source: .microphone, start: 0, end: 2, text: "A corrected thought.", timing: "segment"))
        XCTAssertEqual(edited.segments[1], original.segments[2])
        XCTAssertEqual(edited.modelSHA256, original.modelSHA256); XCTAssertEqual(edited.sources, original.sources)
        XCTAssertEqual(edited.engine, original.engine)
        XCTAssertEqual(edited.editing?.parentVersion, json.deletingLastPathComponent().lastPathComponent)
        XCTAssertTrue(try String(contentsOf: saved, encoding: .utf8).contains("Manually edited"))
        XCTAssertEqual(try call("Call").transcripts.count, 2)
        XCTAssertTrue(try call("Call").latestTranscript?.document?.editing != nil)
        let unchanged = try original.editingParagraphs(original.paragraphs.map(\.text), parentVersion: "original")
        XCTAssertEqual(unchanged.segments, original.segments)
    }
    func testStaleEditAndMismatchedParagraphCountsAreRejected() throws {
        let json = try transcript(audio("Call/Mixed.m4a")), recording = try call("Call")
        let version = try XCTUnwrap(recording.latestTranscript), original = try XCTUnwrap(version.document)
        XCTAssertThrowsError(try original.editingParagraphs([], parentVersion: "original"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        object["segments"] = []
        try JSONSerialization.data(withJSONObject: object).write(to: json)
        XCTAssertThrowsError(try CallFileOperations.saveTranscriptEdits(original.paragraphs.map(\.text), version: version, recording: recording))
        XCTAssertEqual(try call("Call").transcripts.count, 1)
    }
    func testLegacyFilesWithSameBasenameKeepDistinctDetailsAndTranscripts() throws {
        let first = try audio("Call.m4a"), second = try audio("Call.wav")
        _ = try transcript(first); _ = try transcript(second)
        let a = try call("Call.m4a"), b = try call("Call.wav")
        try CallDetailsStore.save(.init(title: "First call"), for: a)
        try CallDetailsStore.save(.init(title: "Second call"), for: b)
        XCTAssertEqual(try call("Call.m4a").name, "First call"); XCTAssertEqual(try call("Call.wav").name, "Second call")
        XCTAssertEqual(a.transcripts.count, 1); XCTAssertEqual(b.transcripts.count, 1)
        XCTAssertThrowsError(try CallFileOperations.transcriptDirectory(b.transcripts[0], for: a))
        // A newer run must be included even when the UI snapshot predates it.
        let newer = try transcript(first)
        let plan = try CallFileOperations.trashPlan(for: a)
        XCTAssertEqual(plan.urls.count, 4)
        XCTAssertTrue(plan.urls.map { $0.standardizedFileURL.path }.contains(newer.deletingLastPathComponent().standardizedFileURL.path))
        try CallFileOperations.moveToTrash(plan, trash: fixtureTrash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try call("Call.wav").transcripts.count, 1)
        XCTAssertEqual(try call("Call.wav").name, "Second call")
    }
    func testPartialTrashFailureRestoresPreviouslyMovedItems() throws {
        _ = try transcript(audio("Call.m4a"))
        let recording = try call("Call.m4a")
        try CallDetailsStore.save(.init(title: "Keep me"), for: recording)
        let plan = try CallFileOperations.trashPlan(for: recording)
        let snapshots = try plan.urls.prefix(2).map { try Data(contentsOf: $0) }
        var count = 0
        XCTAssertThrowsError(try CallFileOperations.moveToTrash(plan) { url in
            count += 1
            if count == 3 { throw RecorderError.message("Injected trash failure") }
            return try self.fixtureTrash(url)
        })
        XCTAssertEqual(count, 3)
        XCTAssertEqual(try plan.urls.prefix(2).map { try Data(contentsOf: $0) }, snapshots)
        XCTAssertEqual(try call("Call.m4a").name, "Keep me")
        XCTAssertEqual(try call("Call.m4a").transcripts.count, 1)
    }
    func testCallTrashMovesWholeFolderAndVersionTrashLeavesOtherVersionsAndAudio() throws {
        let audio = try audio("Call/Mixed.m4a")
        _ = try transcript(audio); _ = try transcript(audio)
        var recording = try call("Call")
        try CallDetailsStore.save(.init(title: "Meeting"), for: recording)
        let plan = try CallFileOperations.trashPlan(for: recording.transcripts[0], recording: recording)
        try CallFileOperations.moveToTrash(plan, trash: fixtureTrash)
        recording = try call("Call")
        XCTAssertEqual(recording.transcripts.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let full = try CallFileOperations.trashPlan(for: recording)
        XCTAssertEqual(full.urls, [recording.url])
        var moved: URL?
        try CallFileOperations.moveToTrash(full) { url in moved = try self.fixtureTrash(url); return moved! }
        XCTAssertTrue(RecordingLibraryScanner.scan(roots: [root]).recordings.isEmpty)
        try FileManager.default.moveItem(at: XCTUnwrap(moved), to: recording.url)
        XCTAssertEqual(try call("Call").name, "Meeting"); XCTAssertEqual(try call("Call").transcripts.count, 1)
    }
    func testTrashRejectsUnrelatedFilesAndLinkedTranscriptFolders() throws {
        let audio = try audio("Call/Mixed.m4a"), json = try transcript(audio)
        let recording = try call("Call"), version = try XCTUnwrap(recording.latestTranscript)
        let extra = recording.url.appendingPathComponent("Unrelated.txt")
        try Data("keep".utf8).write(to: extra)
        XCTAssertThrowsError(try CallFileOperations.trashPlan(for: recording))
        try FileManager.default.removeItem(at: extra)
        let run = json.deletingLastPathComponent(), extraRun = run.appendingPathComponent("Keep.txt")
        try Data("keep".utf8).write(to: extraRun)
        XCTAssertThrowsError(try CallFileOperations.trashPlan(for: version, recording: recording))
        let actual = root.appendingPathComponent(".actual-run")
        try FileManager.default.moveItem(at: run, to: actual)
        try FileManager.default.createSymbolicLink(at: run, withDestinationURL: actual)
        XCTAssertThrowsError(try CallFileOperations.transcriptDirectory(version, for: recording))
        XCTAssertFalse(CallFileOperations.contains(recording.url, root.appendingPathComponent("Call-again/Mixed.m4a")))
        XCTAssertTrue(CallFileOperations.contains(recording.url, audio))
    }
    func testSavingToRemovedCallCannotRecreateTheFolder() throws {
        _ = try audio("Call/Mixed.m4a")
        let recording = try call("Call")
        try FileManager.default.removeItem(at: recording.url)
        XCTAssertThrowsError(try CallDetailsStore.save(.init(title: "Gone"), for: recording))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.url.path))
    }
}
