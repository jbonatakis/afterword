import Foundation
import CryptoKit

public struct InstalledSpeechModel: Sendable {
    public let url: URL
    public let shared: Bool
}

public enum ModelStore {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Afterword/Models", isDirectory: true)
    }
    public static func ownedURL(_ model: SpeechModel, root: URL = defaultRoot) -> URL {
        root.appendingPathComponent(model.filename)
    }
    public static func find(_ model: SpeechModel, root: URL = defaultRoot,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InstalledSpeechModel? {
        let fm = FileManager.default
        let own = ownedURL(model, root: root)
        if fm.fileExists(atPath: own.path) { return InstalledSpeechModel(url: own, shared: false) }
        let cache = home.appendingPathComponent(".cache/huggingface/hub/models--" + model.repository.replacingOccurrences(of: "/", with: "--") + "/snapshots")
        let snapshots = (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        let handy = home.appendingPathComponent("Library/Application Support/com.pais.handy/models/" + model.filename)
        // Discovery is cheap; verification happens off the main thread before every use.
        for file in [handy] + snapshots.sorted(by: { $0.path < $1.path }).map({ $0.appendingPathComponent(model.filename) }) {
            if let size = try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == model.bytes {
                return InstalledSpeechModel(url: file, shared: true)
            }
        }
        return nil
    }
    public static func verify(_ url: URL, model: SpeechModel, cancelled: () -> Bool = { false }) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        guard try handle.seekToEnd() == UInt64(model.bytes) else {
            throw RecorderError.message("The model download is incomplete. Remove it and download it again.")
        }
        try handle.seek(toOffset: 0)
        var hash = SHA256(); var first = true
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            if cancelled() { throw CancellationError() }
            if first {
                guard data.prefix(4) == Data("GGUF".utf8) else { throw RecorderError.message("This file is not a supported model.") }
                first = false
            }
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == model.sha256 else {
            throw RecorderError.message("The model failed verification. Download a fresh copy in Settings.")
        }
    }
    public static func download(_ model: SpeechModel, root: URL = defaultRoot,
                                progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try PrivateFiles.directory(root)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 7_200
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let delegate = DownloadProgress(expected: model.bytes, progress: progress)
        let (temporary, response) = try await session.download(from: model.downloadURL, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw RecorderError.message("The model server could not complete the download. Try again.")
        }
        let stage = root.appendingPathComponent(".download-" + UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.path)
        progress(nil)
        try verify(stage, model: model, cancelled: { Task.isCancelled })
        try Task.checkCancellation()
        try PrivateFiles.sync(stage)
        let final = ownedURL(model, root: root)
        // Only the recorder's own model file is replaced, after full verification.
        guard rename(stage.path, final.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return final
    }
    public static func remove(_ model: SpeechModel, root: URL = defaultRoot) throws {
        // Never remove models belonging to Handy or Hugging Face.
        try FileManager.default.removeItem(at: ownedURL(model, root: root))
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expected: Int64
    let progress: @Sendable (Double?) -> Void
    init(expected: Int64, progress: @escaping @Sendable (Double?) -> Void) { self.expected = expected; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(min(1, Double(totalBytesWritten) / Double(expected)))
    }
}
