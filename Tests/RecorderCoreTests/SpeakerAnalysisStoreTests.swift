#if canImport(XCTest)
import XCTest
#endif
import Foundation
@testable import RecorderCore

final class SpeakerAnalysisStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateFiles.directory(root)
        try Data("system audio".utf8).write(to: audio)
        try installWorker()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private var audio: URL { root.appendingPathComponent("System.m4a") }
    private var cache: URL { root.appendingPathComponent("cache") }
    private var worker: URL { root.appendingPathComponent("worker") }
    private var store: SpeakerAnalysisStore { .init(directory: cache, worker: worker, models: root) }
    private func installWorker(_ body: String = """
        sleep 0.1
        echo '{"model":"\(SpeakerAnalysis.modelID)","intervals":[],"clips":[]}' > "$3"
        """) throws {
        let script = "#!/bin/sh\necho ran >> \"$1/runs\"\n" + body + "\n"
        try script.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
    }
    private func runs() throws -> Int {
        try String(contentsOf: root.appendingPathComponent("runs")).split(separator: "\n").count
    }
    func testConcurrentRequestsAndLaterReviewReuseEvenAnEmptyAnalysis() throws {
        let store = store, audio = audio
        XCTAssertNil(store.cachedAnalysis(for: audio))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs").path))
        let errors = NSLock()
        var failures = [String]()
        DispatchQueue.concurrentPerform(iterations: 3) { _ in
            do { _ = try store.analysis(for: audio, operation: LocalWorkerOperation()) }
            catch { errors.withLock { failures.append(error.localizedDescription) } }
        }
        XCTAssertTrue(failures.isEmpty)
        try FileManager.default.removeItem(at: worker)
        XCTAssertEqual(store.cachedAnalysis(for: audio)?.intervals, [])
        XCTAssertTrue(try self.store.analysis(for: audio, operation: LocalWorkerOperation()).intervals.isEmpty)
        XCTAssertEqual(try runs(), 1)
        let entry = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: entry.path)[.posixPermissions] as? Int, 0o600)
    }
    func testChangedAudioAndUnusableCacheAreRecomputed() throws {
        func prepare() throws { _ = try store.analysis(for: audio, operation: LocalWorkerOperation()) }
        try prepare()
        let entry = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        let obsolete = try String(contentsOf: entry).replacingOccurrences(of: SpeakerAnalysis.modelID, with: "previous-model")
        try obsolete.write(to: entry, atomically: true, encoding: .utf8)
        try prepare()
        try Data("partial JSON".utf8).write(to: entry)
        try prepare()
        try Data("changed source".utf8).write(to: audio)
        try prepare()
        XCTAssertEqual(try runs(), 4)
    }

    func testRememberSelectedPassageWithoutAutomaticClips() throws {
        _ = try store.analysis(for: audio, operation: LocalWorkerOperation())
        let pat = CallAttendee(name: "Pat", email: "pat@example.test")
        let details = CallDetails(participants: [pat.name], attendees: [pat])
        try CallDetailsStore.writeInitial(details, to: CallDetailsStore.url(for: root, isDirectory: true))
        let input = TranscriptionInput(tracks: [.init(source: .system, url: audio)], outputDirectory: root, name: "Call")
        let segment = TranscriptSegment(source: .system, start: 1.25, end: 6.5, text: "Selected passage.", timing: "word")
        let doc = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "fixture", language: "en", segments: [segment])
        _ = try doc.save(beside: input)
        let call = try XCTUnwrap(RecordingLibraryScanner.scan(roots: [root]).recordings.first)
        let catalog = PersonVoiceLibrary(recordings: [call])
        let passage = try XCTUnwrap(catalog.items.first)
        let profileFolder = root.appendingPathComponent("voices")
        let vector = [Float](repeating: 0.125, count: 256)
        let clip = VoiceClip(interval: .init(speaker: "passage", start: 1.25, end: 6.5), vector: vector)
        let result = SpeakerAnalysis(model: SpeakerAnalysis.modelID, intervals: [], clips: [clip])
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        try installWorker("""
            [ "$#" = 5 ] && [ "$2" = "$1/System.m4a" ] && [ "$4" = 1.25 ] && [ "$5" = 6.5 ] || exit 1
            echo '\(json)' > "$3"
            """)
        func remember(_ item: PersonVoiceLibrary.Item) throws {
            try item.rememberPassage(in: .init(), store: store, profilesDirectory: profileFolder, operation: LocalWorkerOperation())
        }
        try remember(passage)
        try remember(passage)
        let profiles = try VoiceProfiles.load(in: profileFolder)
        XCTAssertEqual(profiles.references.count, 1)
        let reference = try XCTUnwrap(profiles.references.first)
        XCTAssertEqual(reference.start, 1.25)
        XCTAssertEqual(reference.end, 6.5)
        XCTAssertEqual(reference.call, try call.agentID)
        XCTAssertEqual(profiles.suggestion(for: [clip, clip], among: [pat], excludingCall: "future")?.id, pat.id)
        let saved = PersonVoiceLibrary(recordings: [call], profiles: profiles)
        XCTAssertEqual(saved.items.first(where: { $0.id == passage.id })?.rememberedSample?.id, reference.id)
        XCTAssertEqual(saved.items.count, 2)
        XCTAssertEqual(RecordingLibraryScanner.transcripts(in: root).count, 1)
        XCTAssertEqual(store.cachedAnalysis(for: audio)?.clips.count, 0)

        let sam = CallAttendee(name: "Sam")
        try VoiceProfiles.update(in: profileFolder) { try $0.change(reference, to: sam, in: .init()) }
        XCTAssertThrowsError(try remember(passage))
        let corrected = try VoiceProfiles.load(in: profileFolder)
        XCTAssertEqual(corrected.count(for: sam), 1)
        let passageToReassign = try XCTUnwrap(PersonVoiceLibrary(recordings: [call], profiles: corrected).items.first { $0.id == passage.id })
        try FileManager.default.removeItem(at: worker)
        try remember(passageToReassign)
        let restored = try VoiceProfiles.load(in: profileFolder)
        XCTAssertEqual(restored.count(for: pat), 1)
        let rememberedPassage = try XCTUnwrap(PersonVoiceLibrary(recordings: [call], profiles: restored).items.first { $0.id == passage.id })
        try CallDetailsStore.save(CallDetails(participants: [sam.name], attendees: [sam]), for: call)
        XCTAssertThrowsError(try remember(rememberedPassage))
        XCTAssertEqual(try VoiceProfiles.load(in: profileFolder).count(for: sam), 0)
    }

    func testSelectedPassageRejectsShortOrUnmatchedAudio() throws {
        XCTAssertThrowsError(try store.voiceClip(for: audio, from: 4, to: 5, operation: LocalWorkerOperation()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs").path))
        XCTAssertThrowsError(try store.voiceClip(for: audio, from: 4, to: 9, operation: LocalWorkerOperation()))
        XCTAssertEqual(try runs(), 1)
        XCTAssertNil(store.cachedAnalysis(for: audio))
    }

    func testWorkerFailureAndCancellationLeavePreparationRetryable() throws {
        try installWorker("exit 1")
        XCTAssertThrowsError(try store.analysis(for: audio, operation: LocalWorkerOperation()))
        try installWorker("exec sleep 10")
        let operation = LocalWorkerOperation()
        let log = root.appendingPathComponent("runs")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(3)
            while (try? String(contentsOf: log).split(separator: "\n").count) != 2, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            operation.cancel()
        }
        XCTAssertThrowsError(try store.analysis(for: audio, operation: operation))
        XCTAssertTrue(operation.isCancelled)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cache.path).contains { $0.hasSuffix(".json") })
        try installWorker()
        XCTAssertNoThrow(try store.analysis(for: audio, operation: LocalWorkerOperation()))
        XCTAssertEqual(try runs(), 3)
    }
}
