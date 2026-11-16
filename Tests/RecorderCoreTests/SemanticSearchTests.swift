#if canImport(XCTest)
import XCTest
#endif
import Foundation
@testable import RecorderCore

final class SemanticSearchTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-tests-" + UUID().uuidString)
        try PrivateFiles.directory(root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func call(_ text: [String] = ["The launch needs to wait until the database migration is finished.", "We can ship next week."], participant: String = "Corinne", revision: String = "a") throws -> AgentCall {
        let input = TranscriptionInput(tracks: [.init(source: .microphone, url: root.appendingPathComponent("mic")), .init(source: .system, url: root.appendingPathComponent("system"))], outputDirectory: root, name: "Test")
        let transcript = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "test", language: "en", segments: text.enumerated().map {
            TranscriptSegment(source: $0.offset.isMultiple(of: 2) ? .system : .microphone, start: Double($0.offset * 20), end: Double($0.offset * 20 + 5), text: $0.element, timing: "word")
        })
        var details = CallDetails(); details.participants = [participant]
        let version = LibraryTranscript(url: root.appendingPathComponent("run/Transcript.json"), document: transcript, error: nil, date: .distantPast, fileModificationDate: .distantPast)
        return AgentCall(recording: LibraryRecording(url: root, sourceName: "Test", isDirectory: true, details: details, detailsError: nil, date: .distantPast, duration: 30, tracks: [], transcripts: [version]), id: "call", revision: revision)
    }
    func enable(_ model: EmbeddingModel = EmbeddingModel.catalog[0]) throws {
        var settings = EmbeddingSettings(); settings.enabled = true; settings.modelID = model.id
        try settings.save(directory: root)
        try PrivateFiles.directory(EmbeddingSettings.modelRoot(root))
        try Data().write(to: ModelStore.ownedURL(model.asset, root: EmbeddingSettings.modelRoot(root)))
    }
    func vector(_ model: EmbeddingModel) -> [Float] { [1] + Array(repeating: 0, count: model.dimensions - 1) }
    func settle(_ engine: SemanticSearchEngine) {
        let deadline = Date().addingTimeInterval(3)
        while engine.snapshot(allVersions: true).0.state == "indexing", Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }
    func testDisabledDoesNotCreateCacheOrInvokeModel() throws {
        let engine = SemanticSearchEngine(directory: root) { _, _, _, _ in throw RecorderError.message("Must not run") }
        engine.refresh([try call()])
        let result = engine.search("release delayed", allVersions: false)
        XCTAssertEqual(result.1.state, "disabled")
        XCTAssertEqual(result.1.mode, "keyword")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Vectors-v1.sqlite").path))
    }
    func testMissingModelRemainsKeywordAndDoesNotDownload() throws {
        var settings = EmbeddingSettings(); settings.enabled = true; try settings.save(directory: root)
        let engine = SemanticSearchEngine(directory: root)
        engine.refresh([try call()])
        XCTAssertEqual(engine.search("release", allVersions: false).1.state, "missing_model")
        XCTAssertFalse(FileManager.default.fileExists(atPath: EmbeddingSettings.modelRoot(root).path))
    }
    func testChunkInputsExcludeNamesAndRetainParagraphReferences() throws {
        let first = SemanticChunker.chunks(try call())
        let renamed = SemanticChunker.chunks(try call(participant: "Bellamy", revision: "b"))
        XCTAssertEqual(first.map(\.hash), renamed.map(\.hash))
        XCTAssertEqual(Set(first.flatMap(\.paragraphs)), Set([0, 1]))
        XCTAssertFalse(first.contains { $0.text.contains("Corinne") || $0.text.contains("Bellamy") })
        XCTAssertEqual(first[0].text, "The launch needs to wait until the database migration is finished.\n\nWe can ship next week.")
    }
    func testLongTurnsSplitWithoutLosingTailOrUnicode() {
        let text = "START " + String(repeating: "A sufficiently long sentence with a meaning. ", count: 80) + String(repeating: "漢", count: 1900) + " END"
        let chunks = SemanticChunker.split(text)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 900 })
        XCTAssertTrue(chunks.first!.hasPrefix("START"))
        XCTAssertTrue(chunks.last!.hasSuffix("END"))
        XCTAssertEqual(chunks.joined().filter { $0 == "漢" }.count, 1900)
    }
    func testMetadataChangesReuseVectorsAndTextEditsInvalidate() throws {
        try enable()
        let counter = Counter()
        let engine = SemanticSearchEngine(directory: root) { texts, model, _, _ in
            counter.add(texts.count); return texts.map { _ in self.vector(model) }
        }
        engine.refresh([try call()]); settle(engine)
        XCTAssertEqual(engine.snapshot(allVersions: false).0.state, "ready")
        XCTAssertEqual(counter.value, 3)
        engine.refresh([try call(participant: "Bellamy", revision: "b")]); settle(engine)
        XCTAssertEqual(counter.value, 3)
        engine.refresh([try call(["We already shipped the release."], revision: "c")]); settle(engine)
        XCTAssertEqual(counter.value, 4)
        // A new process reuses the persisted vectors, without an inference call.
        let second = SemanticSearchEngine(directory: root) { _, _, _, _ in throw RecorderError.message("Unexpected inference") }
        second.refresh([try call(["We already shipped the release."], revision: "c")]); settle(second)
        XCTAssertEqual(second.snapshot(allVersions: false).0.state, "ready")
    }
    func testModelSwitchUsesSeparateSpaceAndRebuilds() throws {
        try enable()
        let counter = Counter()
        let engine = SemanticSearchEngine(directory: root) { texts, model, _, _ in counter.add(texts.count); return texts.map { _ in self.vector(model) } }
        let calls = [try call()]
        engine.refresh(calls); settle(engine)
        try enable(EmbeddingModel.catalog[1]); engine.refresh(calls); settle(engine)
        XCTAssertEqual(counter.value, 6)
        XCTAssertEqual(engine.snapshot(allVersions: false).0.model, EmbeddingModel.catalog[1].asset.name)
        try enable(); engine.refresh(calls); settle(engine)
        XCTAssertEqual(counter.value, 6)
    }
    func testRecordingPriorityPausesAcrossInstances() throws {
        try enable()
        let priority = EmbeddingPriority(); try priority.setBusy(true, directory: root)
        XCTAssertTrue(EmbeddingPriority.isBusy(root))
        let engine = SemanticSearchEngine(directory: root) { texts, model, _, _ in texts.map { _ in self.vector(model) } }
        let calls = [try call()]; engine.refresh(calls)
        XCTAssertEqual(engine.snapshot(allVersions: false).0.state, "paused")
        XCTAssertEqual(engine.snapshot(allVersions: false).0.indexed, 0)
        try priority.setBusy(false, directory: root); engine.refresh(calls); settle(engine)
        XCTAssertEqual(engine.snapshot(allVersions: false).0.state, "ready")
    }
    func testInvalidVectorsAreNotStoredAndRetryCanRecover() throws {
        try enable()
        let counter = Counter()
        let engine = SemanticSearchEngine(directory: root) { texts, model, _, _ in
            counter.add(1); return texts.map { _ in counter.value == 1 ? [Float.nan] : self.vector(model) }
        }
        engine.refresh([try call()]); settle(engine)
        XCTAssertEqual(engine.snapshot(allVersions: false).0.state, "error")
        XCTAssertEqual(engine.snapshot(allVersions: false).0.indexed, 0)
        engine.retry(); settle(engine)
        XCTAssertEqual(engine.snapshot(allVersions: false).0.state, "ready")
    }
    func testQueryPrefixAndCachedQueryAndDisable() throws {
        try enable()
        let counter = Counter()
        let engine = SemanticSearchEngine(directory: root) { texts, model, _, _ in
            if texts.first?.hasPrefix(model.queryPrefix) == true { counter.add(1) }
            return texts.map { _ in self.vector(model) }
        }
        let calls = [try call()]; engine.refresh(calls); settle(engine)
        let first = engine.search("release postponed", allVersions: false)
        XCTAssertEqual(first.1.mode, "hybrid"); XCTAssertEqual(first.0.count, 3)
        XCTAssertEqual(engine.search("release postponed", allVersions: false).2, first.2)
        XCTAssertEqual(counter.value, 1)
        try EmbeddingSettings().save(directory: root)
        // Even before refresh, a settings change prevents cached semantic results.
        XCTAssertEqual(engine.search("release postponed", allVersions: false).1.mode, "keyword")
        engine.refresh(calls); XCTAssertEqual(engine.snapshot(allVersions: false).0.state, "disabled")
    }
    func testQueryFailureReportsFallback() throws {
        try enable()
        let engine = SemanticSearchEngine(directory: root) { texts, model, _, _ in
            if texts.first?.hasPrefix(model.queryPrefix) == true { throw RecorderError.message("Model unavailable") }
            return texts.map { _ in self.vector(model) }
        }
        engine.refresh([try call()]); settle(engine)
        let result = engine.search("release", allVersions: false)
        XCTAssertEqual(result.1.mode, "keyword"); XCTAssertTrue(result.0.isEmpty)
        XCTAssertTrue(result.1.message.contains("unavailable"))
    }
    func testQueryLeaseLetsQueriesInterruptBackgroundWork() throws {
        try enable()
        let lease = EmbeddingPriority(fileName: "query.lock")
        try lease.setBusy(true, directory: root)
        let counter = Counter()
        let engine = SemanticSearchEngine(directory: root) { texts, model, _, _ in counter.add(1); return texts.map { _ in self.vector(model) } }
        let calls = [try call()]; engine.refresh(calls)
        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(engine.snapshot(allVersions: false).0.state, "indexing")
        try lease.setBusy(false, directory: root)
        engine.refresh(calls); settle(engine)
        XCTAssertEqual(engine.snapshot(allVersions: false).0.state, "ready")
    }
    func testDisableCancelsInFlightIndexing() throws {
        try enable()
        let started = Counter(), stopped = Counter()
        let engine = SemanticSearchEngine(directory: root) { _, _, _, cancelled in
            started.add(1)
            let deadline = Date().addingTimeInterval(2)
            while !cancelled() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            stopped.add(1); throw CancellationError()
        }
        engine.refresh([try call()])
        let deadline = Date().addingTimeInterval(2)
        while started.value == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        try EmbeddingSettings().save(directory: root); engine.refresh([])
        while stopped.value == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(stopped.value, 1)
        XCTAssertEqual(engine.snapshot(allVersions: false).0.state, "disabled")
        XCTAssertEqual(engine.snapshot(allVersions: false).0.indexed, 0)
    }
    func testRemovingModelStopsSemanticResultsAndProgressChangesRevision() throws {
        try enable()
        let engine = SemanticSearchEngine(directory: root) { texts, model, _, _ in
            Thread.sleep(forTimeInterval: 0.05); return texts.map { _ in self.vector(model) }
        }
        engine.refresh([try call()]); let before = engine.snapshot(allVersions: false).1
        settle(engine); let ready = engine.snapshot(allVersions: false).1
        XCTAssertNotEqual(before, ready)
        XCTAssertEqual(engine.search("release", allVersions: false).1.mode, "hybrid")
        try ModelStore.remove(EmbeddingModel.catalog[0].asset, root: EmbeddingSettings.modelRoot(root))
        XCTAssertEqual(engine.search("release", allVersions: false).1.state, "missing_model")
        XCTAssertEqual(engine.search("release", allVersions: false).1.mode, "keyword")
    }
    func testStoppingAnObsoleteScopeCancelsDerivedWork() throws {
        try enable()
        let started = Counter(), stopped = Counter()
        let engine = SemanticSearchEngine(directory: root) { _, _, _, cancelled in
            started.add(1)
            let deadline = Date().addingTimeInterval(2)
            while !cancelled() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            stopped.add(1); throw CancellationError()
        }
        engine.refresh([try call()])
        let deadline = Date().addingTimeInterval(2)
        while started.value == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        engine.stop()
        while stopped.value == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(stopped.value, 1)
        XCTAssertEqual(engine.snapshot(allVersions: false).0.total, 0)
        XCTAssertEqual(engine.search("release", allVersions: false).1.mode, "keyword")
    }
    func testQuotesRemainHardConstraints() {
        XCTAssertTrue(LibrarySearchQuery("release \"database migration\"").matchesQuotes("The database migration finished."))
        XCTAssertFalse(LibrarySearchQuery("release \"database migration\"").matchesQuotes("Moving the data is done."))
        XCTAssertTrue(LibrarySearchQuery("release").matchesQuotes("Moving the data is done."))
    }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add(_ amount: Int) { lock.lock(); defer { lock.unlock() }; count += amount }
}
