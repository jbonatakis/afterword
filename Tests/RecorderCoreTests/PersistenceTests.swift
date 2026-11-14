#if canImport(XCTest)
import XCTest
#endif
import AVFoundation
@testable import RecorderCore

final class PersistenceTests: XCTestCase {
    var root: URL!
    var destination: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CallRecorderTests-\(UUID().uuidString)")
        destination = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func makeStore(start: Date = Date(), separateTracks: Bool = true) throws -> SessionStore {
        let device = InputDevice(objectID: 1, uid: "test-only", name: "Fixture", channels: ["Mono"], bufferChannels: [1], sampleRate: 48_000)
        let manifest = SessionManifest(startDate: start, input: ResolvedInput(device: device, channel: 0, selection: .systemDefault), formats: [], destination: destination, separateTracks: separateTracks)
        return try SessionStore(root: root.appendingPathComponent("sessions"), manifest: manifest)
    }
    func append(_ store: SessionStore, frames: Int, value: Float = 0.25, frequency: Double? = nil) throws {
        var written = 0
        let buffer = AVAudioPCMBuffer(pcmFormat: store.format, frameCapacity: 8_192)!
        while written < frames {
            let count = min(8_192, frames - written); buffer.frameLength = UInt32(count)
            for f in 0..<count {
                let sample = frequency.map { Float(sin(Double(written + f) * 2 * .pi * $0 / 48_000)) * value } ?? value
                for channel in 0..<Int(store.format.channelCount) { buffer.floatChannelData![channel][f] = sample }
            }
            try store.append(buffer); written += count
        }
    }
    func testChunkBoundariesOrderingAndPrivatePermissions() throws {
        let store = try makeStore()
        try append(store, frames: 480_000, value: 0.125)
        try append(store, frames: 24_000, value: -0.25)
        try store.finish()
        XCTAssertEqual(store.manifest.chunks.map(\.frames), [480_000,24_000])
        let loaded = try Recovery.load(directory: store.directory)
        XCTAssertEqual(loaded.manifest.chunks, store.manifest.chunks)
        for (index, chunk) in loaded.manifest.chunks.enumerated() {
            let url = store.directory.appendingPathComponent(chunk.filename)
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100)!
            try file.read(into: buffer)
            XCTAssertEqual(buffer.floatChannelData![0][50], index == 0 ? 0.125 : -0.25)
            let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
            XCTAssertEqual(mode & 0o777, 0o600)
        }
    }
    func testReconciliationFindsChunkFinalizedBeforeCheckpoint() throws {
        let store = try makeStore()
        let before = try Data(contentsOf: store.directory.appendingPathComponent("manifest.json"))
        try append(store, frames: 480_000)
        try before.write(to: store.directory.appendingPathComponent("manifest.json"), options: .atomic)
        let recovered = try Recovery.load(directory: store.directory)
        XCTAssertEqual(recovered.manifest.chunks.count, 1)
        XCTAssertEqual(recovered.manifest.totalFrames, 480_000)
    }
    func testMalformedManifestAndPathTraversalCannotDeleteFiles() throws {
        let store = try makeStore()
        try append(store, frames: 1_024); try store.finish()
        let url = store.directory.appendingPathComponent("manifest.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object["chunks"] = [["sequence": 0, "filename": "../../outside.caf", "frames": 1_024]]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try Recovery.load(directory: store.directory))
        XCTAssertThrowsError(try store.removeAfterDelivery())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertFalse(Recovery.scan(root: root.appendingPathComponent("sessions")).first!.canRecover)
    }
    func testAACExportValidationAndCollisionNeverOverwrites() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try makeStore(start: start)
        try append(a, frames: 48_000, frequency: 440); try a.finish()
        let urlA = try Exporter.export(a)
        try Exporter.validate(urlA, expectedFrames: 48_000)
        let before = try Data(contentsOf: urlA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory.path))
        let b = try makeStore(start: start)
        try append(b, frames: 48_000, frequency: 880); try b.finish()
        let urlB = try Exporter.export(b)
        XCTAssertNotEqual(urlA, urlB)
        XCTAssertEqual(try Data(contentsOf: urlA), before)
        XCTAssertTrue(urlB.deletingLastPathComponent().lastPathComponent.hasSuffix("-1"))
        XCTAssertThrowsError(try Exporter.validate(urlB, expectedFrames: 100_000))
    }
    func testEncoderFailureRetainsPCMAndCanRetry() throws {
        let store = try makeStore(); try append(store, frames: 48_000, frequency: 440); try store.finish()
        XCTAssertThrowsError(try Exporter.export(store) { _, _, _ in throw RecorderError.message("Injected encoder failure") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("chunk-000000.caf").path))
        let recovered = try Recovery.load(directory: store.directory)
        let output = try Exporter.export(recovered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
    func testMissingMiddleChunkDoesNotConcatenateAcrossGapOrDeleteTail() throws {
        let store = try makeStore(); try append(store, frames: 1_440_000, frequency: 440); try store.finish()
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent("chunk-000001.caf"))
        let recovered = try Recovery.load(directory: store.directory)
        XCTAssertEqual(recovered.manifest.totalFrames, 480_000)
        XCTAssertEqual(recovered.manifest.retainRecoveryFiles, true)
        let output = try Exporter.export(recovered)
        try Exporter.validate(output, expectedFrames: 480_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("chunk-000002.caf").path))
    }
    func testStorageFailuresAndDestinationReplacement() throws {
        let store = try makeStore(); try append(store, frames: 48_000, frequency: 440); try store.finish()
        let bad = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: bad); try store.setDestination(bad)
        XCTAssertThrowsError(try Exporter.export(store))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.path))
        try store.setDestination(destination)
        XCTAssertNoThrow(try Exporter.export(store))
        XCTAssertThrowsError(try StorageGuard.check(destination, reserve: Int64.max))
    }
    func testMicrophoneIntervalsSurviveCheckpoint() throws {
        let store = try makeStore()
        try store.microphone(enabled: true, frame: 0)
        try store.microphone(enabled: false, frame: 100)
        try store.microphone(enabled: false, frame: 200)
        try store.microphone(enabled: true, frame: 300)
        try append(store, frames: 1_024); try store.finish()
        let recovered = try Recovery.load(directory: store.directory)
        XCTAssertEqual(recovered.manifest.microphoneEvents.map(\.frame), [0,100,300])
        XCTAssertEqual(recovered.manifest.microphoneEvents.map(\.enabled), [true,false,true])
    }
    func testEmptySessionCleanupDoesNotDeleteUnfinishedOrUnknownFiles() throws {
        let empty = try makeStore()
        XCTAssertTrue(try empty.discardIfEmpty())
        let unfinished = try makeStore()
        try Data([0]).write(to: unfinished.directory.appendingPathComponent("chunk-000000.open.caf"))
        XCTAssertFalse(try unfinished.discardIfEmpty())
        let unknown = try makeStore()
        try Data([0]).write(to: unknown.directory.appendingPathComponent("keep-me.txt"))
        XCTAssertFalse(try unknown.discardIfEmpty())
    }
}
