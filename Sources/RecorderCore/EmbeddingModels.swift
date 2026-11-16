import Foundation
import Darwin

public struct EmbeddingModel: Identifiable, Sendable, Equatable {
    public let asset: SpeechModel
    public let dimensions: Int
    public let pooling: String
    public let queryPrefix: String
    public let minimumSimilarity: Float
    public var id: String { asset.id }
    // Includes preprocessing and chunk format. Never compare incompatible vectors.
    var cacheKey: String { AgentJSON.hash(asset.sha256 + ":turns-v2:" + pooling + ":" + queryPrefix) }
    public static let catalog: [EmbeddingModel] = [
        .init(asset: .init(id: "bge-small", name: "BGE Small", detail: "English · compact and fast", repository: "CompendiumLabs/bge-small-en-v1.5-gguf", revision: "d32f8c040ea3b516330eeb75b72bcc2d3a780ab7", filename: "bge-small-en-v1.5-f16.gguf", bytes: 67308128, sha256: "f0b2fef971e8366438bfd2d9aefea1b0115919389448806d290237f638bae999", licenseURL: URL(string: "https://huggingface.co/BAAI/bge-small-en-v1.5")!), dimensions: 384, pooling: "cls", queryPrefix: "Represent this sentence for searching relevant passages: ", minimumSimilarity: 0.5),
        .init(asset: .init(id: "qwen3-0.6b", name: "Qwen3 Embedding 0.6B", detail: "Multilingual · larger model", repository: "Qwen/Qwen3-Embedding-0.6B-GGUF", revision: "370f27d7550e0def9b39c1f16d3fbaa13aa67728", filename: "Qwen3-Embedding-0.6B-Q8_0.gguf", bytes: 639150592, sha256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439", licenseURL: URL(string: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B")!), dimensions: 1024, pooling: "last", queryPrefix: "Instruct: Given a meeting transcript search query, retrieve relevant passages that answer the query\nQuery: ", minimumSimilarity: 0.35)
    ]
}

public struct EmbeddingSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var modelID = EmbeddingModel.catalog[1].id
    public init() {}
    public var model: EmbeddingModel { EmbeddingModel.catalog.first { $0.id == modelID } ?? EmbeddingModel.catalog[1] }
    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Call Recorder/Embeddings", isDirectory: true) }
    public static func modelRoot(_ directory: URL = directory) -> URL { directory.appendingPathComponent("Models", isDirectory: true) }
    public static func load(directory: URL = directory) throws -> Self {
        let file = directory.appendingPathComponent("Settings.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard EmbeddingModel.catalog.contains(where: { $0.id == value.modelID }) else { throw RecorderError.message("Choose an available search model in Settings.") }
        return value
    }
    public func save(directory: URL = directory) throws {
        try PrivateFiles.directory(directory)
        try PrivateFiles.atomicWrite(JSONEncoder().encode(self), to: directory.appendingPathComponent("Settings.json"))
    }
}

// flock is released automatically on process exit. A recording never waits for
// inference: the helper's controller observes this lease and terminates its child.
public final class EmbeddingPriority {
    private var descriptor: Int32 = -1
    private let fileName: String
    public init() { fileName = "priority.lock" }
    init(fileName: String) { self.fileName = fileName }
    deinit { if descriptor >= 0 { close(descriptor) } }
    public func setBusy(_ busy: Bool, directory: URL = EmbeddingSettings.directory) throws {
        if !busy { if descriptor >= 0 { close(descriptor); descriptor = -1 }; return }
        guard descriptor < 0 else { return }
        try PrivateFiles.directory(directory)
        let fd = open(directory.appendingPathComponent(fileName).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecorderError.message("Could not reserve recording priority.") }
        // Multiple app instances can all hold a shared busy lease.
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { close(fd); throw RecorderError.message("Could not reserve recording priority.") }
        descriptor = fd
    }
    static func isBusy(_ directory: URL, fileName: String = "priority.lock") -> Bool {
        let fd = open(directory.appendingPathComponent(fileName).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) != 0
    }
}

final class EmbeddingRuntime: @unchecked Sendable {
    private var verified: [String: String] = [:] // Accessed only under worker.lock.
    func embed(_ texts: [String], model: EmbeddingModel, directory: URL, cancelled: () -> Bool) throws -> [[Float]] {
        try PrivateFiles.directory(directory)
        let fd = open(directory.appendingPathComponent("worker.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecorderError.message("Embedding worker is unavailable.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw RecorderError.message("Search model is busy; using keyword search.") }
        func stop() -> Bool { cancelled() || EmbeddingPriority.isBusy(directory) }
        guard !stop() else { throw CancellationError() }
        let url = ModelStore.ownedURL(model.asset, root: EmbeddingSettings.modelRoot(directory))
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw RecorderError.message("Download the selected search model in Settings.") }
        let fingerprint = "\(info.st_ino):\(info.st_size):\(info.st_mtimespec):\(info.st_ctimespec)"
        if verified[model.cacheKey] != fingerprint {
            try ModelStore.verify(url, model: model.asset, cancelled: stop)
            verified[model.cacheKey] = fingerprint
        }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/EmbeddingWorker")
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("EmbeddingWorker")
        let helper = FileManager.default.isExecutableFile(atPath: executable.path) ? executable : sibling
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path) else { throw RecorderError.message("The embedding helper is missing. Reinstall the app.") }
        let temporary = directory.appendingPathComponent(".worker-" + UUID().uuidString)
        try PrivateFiles.directory(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("input.json"), output = temporary.appendingPathComponent("output.json")
        try PrivateFiles.atomicWrite(JSONEncoder().encode(texts), to: input)
        let process = Process(); process.executableURL = helper
        process.arguments = [url.path, model.pooling, input.path, output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning {
            if stop() || Date() > deadline {
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if stop() { throw CancellationError() }
                throw RecorderError.message("Search model timed out; using keyword search.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else { throw RecorderError.message("Search model failed; using keyword search. Retry in Settings.") }
        guard !stop() else { throw CancellationError() }
        let data = try Data(contentsOf: output)
        guard data.count < 2_097_152 else { throw RecorderError.message("Invalid embedding response.") }
        let vectors = try JSONDecoder().decode([[Float]].self, from: data)
        guard vectors.count == texts.count, vectors.allSatisfy({ Self.valid($0, dimensions: model.dimensions) }) else { throw RecorderError.message("Invalid embedding response.") }
        return vectors
    }
    static func valid(_ vector: [Float], dimensions: Int) -> Bool {
        vector.count == dimensions && vector.allSatisfy(\.isFinite) && abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.01
    }
}
