import Foundation
import Darwin

/// Shared by transcription and review. Only anonymous, audio-derived results are cached.
public struct SpeakerAnalysisStore: Sendable {
    public static let bundled = SpeakerAnalysisStore(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Afterword/SpeakerAnalysis"),
        worker: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SpeakerWorker"),
        models: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/SpeakerModels"))

    private let directory: URL
    private let worker: URL
    private let models: URL

    public init(directory: URL, worker: URL, models: URL) {
        self.directory = directory; self.worker = worker; self.models = models
    }

    public func analysis(for audio: URL) async throws -> SpeakerAnalysis {
        let operation = LocalWorkerOperation()
        return try await operation.perform { try analysis(for: audio, operation: operation) }
    }

    private struct Source: Equatable {
        let key: String
        let revision: String

        init(_ url: URL) throws {
            var info = stat()
            guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw RecorderError.message("The system audio is no longer available.")
            }
            key = AgentJSON.hash("\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)")
            revision = "1:\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }
    }

    private struct Entry: Codable {
        let revision: String
        let analysis: SpeakerAnalysis
    }

    /// Reading a transcript can reuse diarization without starting a worker.
    public func cachedAnalysis(for audio: URL) -> SpeakerAnalysis? {
        guard let source = try? Source(audio) else { return nil }
        return cachedAnalysis(for: audio, source: source)
    }

    private func cachedAnalysis(for audio: URL, source: Source) -> SpeakerAnalysis? {
        let file = directory.appendingPathComponent(source.key + ".json")
        guard PrivateFiles.isRegular(file), let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.revision == source.revision, entry.analysis.model == SpeakerAnalysis.modelID,
              (try? Source(audio)) == source else { return nil }
        return entry.analysis
    }

    func analysis(for audio: URL, operation: LocalWorkerOperation) throws -> SpeakerAnalysis {
        try operation.checkCancellation()
        let source = try Source(audio)
        if let hit = cachedAnalysis(for: audio, source: source) { return hit }
        try PrivateFiles.directory(directory)
        // A review sheet and a transcription (or another app instance) can request the same audio.
        let fd = open(directory.appendingPathComponent(source.key + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try operation.checkCancellation()
            Thread.sleep(forTimeInterval: 0.1)
        }
        try operation.checkCancellation()
        if let hit = cachedAnalysis(for: audio, source: source) { return hit }
        let result = try runWorker(audio: audio, operation: operation)
        guard try Source(audio) == source else { throw RecorderError.message("System audio changed while speakers were being analyzed. Try again.") }
        let data = try JSONEncoder().encode(Entry(revision: source.revision, analysis: result))
        try operation.publish { try PrivateFiles.atomicWrite(data, to: directory.appendingPathComponent(source.key + ".json")) }
        return result
    }

    private func runWorker(audio: URL, operation: LocalWorkerOperation) throws -> SpeakerAnalysis {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Afterword-Speakers-" + UUID().uuidString)
        try PrivateFiles.directory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Analysis.json")
        let log = folder.appendingPathComponent("diagnostic.txt")
        try PrivateFiles.create(log)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = worker
        child.arguments = [models.path, audio.path, output.path]
        child.environment = ProcessInfo.processInfo.environment.merging(["TMPDIR": folder.path]) { _, new in new }
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = handle
        child.qualityOfService = .utility
        try operation.start(child)
        defer { operation.finish(child) }
        child.waitUntilExit()
        try operation.checkCancellation()
        guard child.terminationStatus == 0 else {
            let message = (try? String(contentsOf: log))?.components(separatedBy: .newlines).last { $0.hasPrefix("Speaker analysis failed.") }
            throw RecorderError.message(message ?? "Speaker analysis stopped before finishing.")
        }
        let result = try JSONDecoder().decode(SpeakerAnalysis.self, from: Data(contentsOf: output))
        guard result.model == SpeakerAnalysis.modelID else { throw RecorderError.message("The speaker worker and app use different models.") }
        return result
    }
}
