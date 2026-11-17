import Foundation
import Darwin

public struct CallSummaryVersion: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let markdown: String
    public let author: String
    public let sourceTranscript: String?
    public let sourceFingerprint: String?

    public func sourceChanged(in recording: LibraryRecording) -> Bool {
        guard let sourceTranscript else { return false }
        guard recording.detailsError == nil, let latest = recording.latestTranscript, latest.runName == sourceTranscript else { return true }
        return sourceFingerprint != CallSummaryStore.fingerprint(recording: recording, version: latest)
    }
}

public struct CallSummary: Codable, Sendable {
    public let format: Int
    public let versions: [CallSummaryVersion]
    public var current: CallSummaryVersion? { versions.first }
}

/// One atomic document contains the current Markdown and immutable previous versions.
/// Both native edits and MCP writes use the same lock and optimistic revision check.
public enum CallSummaryStore {
    public static let maximumCharacters = 65_536
    private static let maximumFileBytes = 16 * 1_048_576
    public static func url(for recording: URL, isDirectory: Bool) -> URL {
        isDirectory ? recording.appendingPathComponent("Summary.json") : recording.appendingPathExtension("summary.json")
    }
    static func lockURL(for recording: URL, isDirectory: Bool) -> URL {
        let file = url(for: recording, isDirectory: isDirectory)
        return file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".lock")
    }
    public static func load(for recording: URL, isDirectory: Bool) throws -> CallSummary? {
        let file = url(for: recording, isDirectory: isDirectory).standardizedFileURL
        guard file == file.resolvingSymlinksInPath().standardizedFileURL else { throw RecorderError.message("The summary path contains a symbolic link.") }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw RecorderError.message("The summary could not be opened.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumFileBytes else {
            throw RecorderError.message("The summary must be a regular file smaller than 16 MiB.")
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumFileBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumFileBytes else { throw RecorderError.message("The summary exceeds the 16 MiB limit.") }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(CallSummary.self, from: data)
        guard value.format == 1, !value.versions.isEmpty,
              Set(value.versions.map(\.id)).count == value.versions.count,
              value.versions.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.markdown.count <= maximumCharacters }) else {
            throw RecorderError.message("The summary has an unsupported or invalid format. It has not been changed.")
        }
        return value
    }
    static func fingerprint(recording: LibraryRecording, version: LibraryTranscript) -> String? {
        guard recording.detailsError == nil, let document = version.document else { return nil }
        let speakers = document.paragraphs.map { recording.speakerLabel(for: $0, version: version) }
        guard let data = try? AgentJSON.data(["transcript": AgentJSON.object(document), "speakers": speakers]) else { return nil }
        return AgentJSON.hash(data)
    }
    @discardableResult public static func save(_ markdown: String, for recording: LibraryRecording,
                                               source: LibraryTranscript?, author: String = "user",
                                               peopleURL: URL = PeopleDirectory.fileURL,
                                               authorize: () throws -> Void = {}) throws -> CallSummary {
        let markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty, markdown.count <= maximumCharacters, !markdown.contains("\0") else {
            throw RecorderError.message("Enter a summary of 1–65,536 characters without null characters.")
        }
        try authorize()
        try CallFileOperations.validateRecording(recording)
        let file = url(for: recording.url, isDirectory: recording.isDirectory)
        let parent = file.deletingLastPathComponent().standardizedFileURL
        guard parent == parent.resolvingSymlinksInPath().standardizedFileURL else { throw RecorderError.message("The recording folder changed. Refresh before saving.") }
        let dir = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dir >= 0 else { throw RecorderError.message("The recording folder could not be opened.") }
        defer { close(dir) }
        let lock = openat(dir, lockURL(for: recording.url, isDirectory: recording.isDirectory).lastPathComponent, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw RecorderError.message("The summary could not be locked.") }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, flock(lock, LOCK_EX) == 0 else {
            throw RecorderError.message("The summary could not be locked.")
        }
        defer { flock(lock, LOCK_UN) }
        let candidates = RecordingLibraryScanner.discover(roots: [recording.isDirectory ? recording.url : parent], confined: true)
        guard let candidate = candidates.candidates.first(where: { $0.url == recording.url }) else {
            throw RecorderError.message("The call is no longer available. Refresh before saving.")
        }
        let people = (try? PeopleDirectory.load(from: peopleURL)) ?? PeopleDirectory()
        let current = try RecordingLibraryScanner.load(candidate, confined: true, people: people)
        guard current.summaryError == nil else { throw RecorderError.message("The saved summary is unreadable. It has not been overwritten.") }
        let id = try AgentJSON.identity(recording.url)
        guard try AgentCall(recording: current, id: id).revision == AgentCall(recording: recording, id: id).revision else {
            throw RecorderError.message("This call or its summary changed. Refresh and review the latest version before saving. Your draft is kept.")
        }
        let previous = current.summary?.versions ?? []
        let currentSource = source.flatMap { requested in current.transcripts.first { $0.id == requested.id && $0.document != nil } }
        if source != nil && currentSource == nil {
            throw RecorderError.message("The source transcript is no longer available.")
        }
        let sourceName = currentSource?.runName ?? previous.first?.sourceTranscript
        let fingerprint = currentSource.flatMap { self.fingerprint(recording: current, version: $0) } ?? previous.first?.sourceFingerprint
        if let latest = previous.first, latest.markdown == markdown, latest.sourceTranscript == sourceName, latest.sourceFingerprint == fingerprint {
            return current.summary!
        }
        let version = CallSummaryVersion(id: UUID().uuidString, createdAt: Date(), markdown: markdown, author: author,
                                         sourceTranscript: sourceName, sourceFingerprint: fingerprint)
        let result = CallSummary(format: 1, versions: [version] + previous)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        guard data.count <= maximumFileBytes else { throw RecorderError.message("Summary history exceeds the 16 MiB limit. The existing summary has been kept.") }
        // Pin writes to the opened directory, and reject replaced paths before publication.
        var opened = stat(), named = stat()
        guard fstat(dir, &opened) == 0, lstat(parent.path, &named) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              parent == parent.resolvingSymlinksInPath().standardizedFileURL,
              try candidate.currentFingerprint() == candidate.fingerprint else {
            throw RecorderError.message("The call changed while saving. Refresh and retry.")
        }
        try authorize()
        let temporary = ".summary-" + UUID().uuidString + ".tmp"
        let output = openat(dir, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw RecorderError.message("The summary could not be saved.") }
        defer { close(output); unlinkat(dir, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw RecorderError.message("The summary could not be written.") }
                offset += count
            }
        }
        guard fsync(output) == 0, renameat(dir, temporary, dir, file.lastPathComponent) == 0 else {
            throw RecorderError.message("The summary could not be published.")
        }
        _ = fsync(dir)
        return result
    }
}
