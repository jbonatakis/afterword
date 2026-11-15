import Foundation
import CryptoKit
import Darwin

public struct AgentAccessConfiguration: Codable, Equatable {
    public var version = 1
    public var enabled: Bool
    public var folders: [String]
    public init(enabled: Bool = false, folders: [String] = []) {
        self.enabled = enabled; self.folders = folders
    }
}

/// Shared by the app and its stdio helper. Read on every tool call, never cached.
public enum AgentAccessStore {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Call Recorder/MCP", isDirectory: true)
    }
    public static func load(directory: URL = directory) throws -> AgentAccessConfiguration {
        let url = directory.appendingPathComponent("Access.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        guard PrivateFiles.isRegular(url) else { throw AgentFailure("Agent access settings are unreadable.") }
        let value = try JSONDecoder().decode(AgentAccessConfiguration.self, from: Data(contentsOf: url))
        guard value.version == 1, value.folders.allSatisfy({ $0.hasPrefix("/") }) else {
            throw AgentFailure("Agent access settings have an unsupported format.")
        }
        return value
    }
    public static func save(_ value: AgentAccessConfiguration, directory: URL = directory) throws {
        try PrivateFiles.directory(directory)
        var value = value
        value.folders = Array(Set(value.folders.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })).sorted()
        try PrivateFiles.atomicWrite(JSONEncoder().encode(value), to: directory.appendingPathComponent("Access.json"))
    }
}

struct AgentFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AgentJSON {
    static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    static func identity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw AgentFailure("A call changed during scanning. Retry the request.") }
        // Stable across title changes, process restarts and same-volume moves; no source-file writes.
        return hash("\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)")
    }
}

/// Durable, content-addressed checkpoints contain IDs and revisions, never transcript text.
/// Each consumer keeps its own cursor; reading changes does not consume them for others.
final class AgentCheckpoints {
    struct Snapshot: Codable { let scope: String; let calls: [String: String] }
    struct Page: Codable { let before: String?; let after: String; let offset: Int }
    let directory: URL
    init(directory: URL) { self.directory = directory.appendingPathComponent("Checkpoints", isDirectory: true) }
    func changes(current: [String: String], scope: String, cursor: String?, pageToken: String?, limit: Int) throws -> [String: Any] {
        try PrivateFiles.directory(directory)
        let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AgentFailure("Could not open change checkpoints.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AgentFailure("Could not lock change checkpoints.") }
        defer { flock(fd, LOCK_UN) }
        let page: Page
        let after: Snapshot
        if let pageToken {
            guard cursor == nil, let data = Data(base64Encoded: pageToken),
                  let decoded = try? JSONDecoder().decode(Page.self, from: data), decoded.offset >= 0 else {
                throw AgentFailure("Invalid page_token. Use either cursor or page_token.")
            }
            page = decoded; after = try read(page.after)
            guard after.scope == scope else { throw AgentFailure("Access settings changed. Start get_changes again.") }
        } else {
            after = Snapshot(scope: scope, calls: current)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(after), id = AgentJSON.hash(data)
            try PrivateFiles.atomicWrite(data, to: directory.appendingPathComponent(id + ".json"))
            page = Page(before: cursor, after: id, offset: 0)
        }
        let before = try page.before.map { try read($0).calls } ?? [:]
        let changed = Set(before.keys).union(after.calls.keys).sorted().compactMap { id -> [String: Any]? in
            guard before[id] != after.calls[id] else { return nil }
            var item: [String: Any] = ["call_id": id, "change": after.calls[id] == nil ? "removed" : (before[id] == nil ? "added" : "updated")]
            if let revision = after.calls[id] { item["revision"] = revision }
            return item
        }
        guard page.offset <= changed.count else { throw AgentFailure("Invalid change page offset.") }
        let end = min(changed.count, page.offset + limit)
        var result: [String: Any] = ["changes": Array(changed[page.offset..<end]), "total": changed.count]
        if end < changed.count {
            result["next_page_token"] = try JSONEncoder().encode(Page(before: page.before, after: page.after, offset: end)).base64EncodedString()
        } else { result["cursor"] = page.after }
        // Keep checkpoint pagination usable for 30 days. An expired cursor fails explicitly.
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if file.pathExtension == "json", file.lastPathComponent != page.after + ".json",
               let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return result
    }
    private func read(_ id: String) throws -> Snapshot {
        guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw AgentFailure("Invalid change cursor.") }
        let url = directory.appendingPathComponent(id + ".json")
        guard PrivateFiles.isRegular(url), let data = try? Data(contentsOf: url), AgentJSON.hash(data) == id,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            throw AgentFailure("Change cursor is unavailable or expired. Call get_changes without a cursor to obtain a full baseline.")
        }
        // Active pagination must not lose an old baseline during cleanup.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return snapshot
    }
}
