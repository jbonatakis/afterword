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
        let errors = NSLock()
        var failures = [String]()
        DispatchQueue.concurrentPerform(iterations: 3) { _ in
            do { _ = try store.analysis(for: audio, operation: LocalWorkerOperation()) }
            catch { errors.withLock { failures.append(error.localizedDescription) } }
        }
        XCTAssertTrue(failures.isEmpty)
        try FileManager.default.removeItem(at: worker)
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
