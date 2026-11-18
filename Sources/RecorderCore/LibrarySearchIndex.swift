import Foundation
import Darwin
import SQLite3

struct LibraryCandidate {
    let url: URL
    let isDirectory: Bool
    let tracks: [LibraryAudioTrack]
    let transcriptFiles: [URL]
    let nodes: [URL]
    let fingerprint: String
    init(url: URL, isDirectory: Bool, tracks: [LibraryAudioTrack], transcriptFiles: [URL], nodes: [URL]) throws {
        self.url = url; self.isDirectory = isDirectory; self.tracks = tracks
        self.transcriptFiles = transcriptFiles; self.nodes = nodes
        fingerprint = try Self.fingerprint(nodes)
    }
    func currentFingerprint() throws -> String { try Self.fingerprint(nodes) }
    private static func fingerprint(_ nodes: [URL]) throws -> String {
        let values = try nodes.map { url -> String in
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT || errno == ENOTDIR { return url.path + ":missing" }
                throw RecorderError.message("A library file could not be inspected.")
            }
            // ctime detects edits even when an editor preserves size and mtime.
            return "\(url.path):\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
        }
        return AgentJSON.hash(values.joined(separator: "\n"))
    }
}

public struct LibrarySearchHit: Sendable {
    public let recordingID: String
    public let versionID: String?
    public let paragraphIDs: [Int]
    public let snippet: String?
    public let score: Double
    public var summaryMatch: Bool = false
}

/// One bounded passage with shared context, not a separate copy for every hit.
struct LibrarySearchPassage {
    let callID: String
    let versionID: String
    let matchingParagraphs: [Int]
    let context: Range<Int>
    var preview: String? = nil
}

/// Rebuildable, scope-specific cache. JSON remains authoritative. A serialized
/// connection protects app tasks; SQLite transactions protect helper processes.
public final class LibrarySearchIndex: @unchecked Sendable {
    public static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Afterword/Search", isDirectory: true)
    }
    private let peopleURL: URL
    private let roots: [URL]
    private let confined: Bool
    private let db: SearchDatabase
    private var githubArchive: GitHubArchive?
    private var githubShared = false
    private var githubDirectory: URL?
    private var codingArchive: CodingArchive?
    var semantic: SemanticSearchEngine
    private let lock = NSRecursiveLock()
    private var cached: [String: (fingerprint: String, call: AgentCall)] = [:]
    private var loadedCount = 0
    private var scanIssues: [String] = []
    public var lastLoadedCount: Int { lock.lock(); defer { lock.unlock() }; return loadedCount }
    public var issues: [String] { lock.lock(); defer { lock.unlock() }; return scanIssues }

    public init(roots: [URL], confined: Bool = false, directory: URL = LibrarySearchIndex.cacheDirectory, embeddingDirectory: URL? = nil, peopleURL: URL = PeopleDirectory.fileURL) throws {
        self.peopleURL = peopleURL
        semantic = SemanticSearchEngine(directory: embeddingDirectory ?? (directory == Self.cacheDirectory ? EmbeddingSettings.directory : directory.appendingPathComponent("Embeddings")))
        self.roots = roots; self.confined = confined
        let scope = AgentJSON.hash(roots.map { $0.standardizedFileURL.path }.sorted().joined(separator: "\n") + ":\(confined)")
        try PrivateFiles.directory(directory)
        db = try SearchDatabase(url: directory.appendingPathComponent("v2-" + scope + ".sqlite"))
    }

    deinit { semantic.stop() }

    /// Stat every saved delivery, decode/hash only changed calls. No source writes.
    @discardableResult public func synchronize() throws -> [LibraryRecording] {
        lock.lock(); defer { lock.unlock() }
        let discovery = RecordingLibraryScanner.discover(roots: roots, confined: confined)
        scanIssues = discovery.issues
        guard !confined || discovery.issues.isEmpty else { throw RecorderError.message(discovery.issues.joined(separator: "\n")) }
        try db.execute("BEGIN IMMEDIATE")
        do {
            let stored = try db.rows("SELECT id, fingerprint, revision FROM calls")
            let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0[0], $0) })
            var next: [String: (fingerprint: String, call: AgentCall)] = [:]
            let people = discovery.candidates.isEmpty ? PeopleDirectory() : ((try? PeopleDirectory.load(from: peopleURL)) ?? PeopleDirectory())
            loadedCount = 0
            for candidate in discovery.candidates {
                try Task.checkCancellation()
                let id = try AgentJSON.identity(candidate.url)
                if next[id] != nil { continue }
                var prior: AgentCall?
                if let row = byID[id], row[1] == candidate.fingerprint {
                    if let existing = cached[id], existing.fingerprint == row[1], existing.call.revision == row[2] {
                        prior = existing.call
                    } else if let snapshot = try db.rows("SELECT snapshot FROM calls WHERE id = ?", [id]).first?.first,
                              let recording = try? JSONDecoder().decode(LibraryRecording.self, from: Data(snapshot.utf8)) {
                        prior = AgentCall(recording: recording, id: id, revision: row[2])
                    }
                }
                let recording: LibraryRecording
                if let prior {
                    recording = prior.recording.resolvingPeople(people)
                    if recording.directoryLabels == prior.recording.directoryLabels {
                        next[id] = (candidate.fingerprint, prior)
                        continue
                    }
                } else {
                    recording = try RecordingLibraryScanner.load(candidate, confined: confined, people: people)
                }
                let call = try AgentCall(recording: recording, id: id)
                try remove(id)
                let snapshot = String(decoding: try JSONEncoder().encode(recording), as: UTF8.self)
                try db.execute("INSERT INTO calls VALUES (?, ?, ?, ?)", [id, candidate.fingerprint, call.revision, snapshot])
                try index(call)
                next[id] = (candidate.fingerprint, call); loadedCount += 1
            }
            for id in byID.keys where next[id] == nil { try remove(id) }
            try db.execute("COMMIT")
            cached = next
            semantic.refresh(calls, codingArchive: codingArchive, github: githubArchive, shared: githubShared)
            return calls.map(\.recording)
        } catch { try? db.execute("ROLLBACK"); throw error }
    }
    var calls: [AgentCall] {
        lock.lock(); defer { lock.unlock() }
        return cached.values.map(\.call).sorted {
            $0.recording.date == $1.recording.date ? $0.recording.id < $1.recording.id : $0.recording.date > $1.recording.date
        }
    }
    public func stopSemanticSearch() { semantic.stop() }
    public func useCodingArchive(in directory: URL?) throws {
        lock.lock(); defer { lock.unlock() }
        codingArchive = try directory.flatMap { CodingArchive.exists(in: $0) ? try CodingArchive(directory: $0) : nil }
        semantic.refresh(calls, codingArchive: codingArchive, github: githubArchive, shared: githubShared)
    }
    public func codingSearch(_ query: String, keywordOnly: Bool = false, from: Date? = nil,
                             to: Date? = nil, project: String? = nil, branch: String? = nil) throws -> (hits: [CodingHit], status: SemanticSearchStatus) {
        lock.lock(); defer { lock.unlock() }
        guard let codingArchive else { return ([], semanticStatus()) }
        let (candidates, status, _) = keywordOnly ? ([], semanticStatus(), "") : semantic.search(query, allVersions: false)
        return (try codingArchive.matches(query: query, semantic: candidates, from: from, to: to, project: project, branch: branch), status)
    }
    public func useGitHubArchive(in directory: URL?, shared: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let current = directory.flatMap { GitHubArchive.exists(in: $0) ? $0 : nil }
        if current != githubDirectory {
            githubArchive = try current.map { try GitHubArchive(directory: $0) }
            githubDirectory = current
        }
        githubShared = shared
        semantic.refresh(calls, codingArchive: codingArchive, github: githubArchive, shared: shared)
    }
    public func githubSearch(
        _ query: String, keywordOnly: Bool = false, repository: String? = nil, type: String? = nil,
        action: String? = nil, from: Date? = nil, to: Date? = nil
    ) throws -> (hits: [GitHubHit], status: SemanticSearchStatus) {
        lock.lock(); defer { lock.unlock() }
        guard let archive = githubArchive else { return ([], semanticStatus()) }
        let keywords = try archive.search(
            query, shared: githubShared, repository: repository, type: type, action: action, from: from, to: to)
        var status = semanticStatus()
        guard !keywordOnly, !LibrarySearchQuery(query).isEmpty, GitHubReference(query) == nil else { return (keywords, status) }
        let (chunks, actual, _) = semantic.search(query, allVersions: false)
        status = actual
        return (
            try archive.merge(
                query, keywords: keywords, chunks: chunks, shared: githubShared,
                repository: repository, type: type, action: action, from: from, to: to), status
        )
    }
    public func refreshSemanticSearch() {
        lock.lock(); defer { lock.unlock() }
        semantic.refresh(calls, codingArchive: codingArchive, github: githubArchive, shared: githubShared)
    }
    public func retrySemanticSearch() { semantic.retry(); refreshSemanticSearch() }
    public func semanticStatus(allVersions: Bool = false) -> SemanticSearchStatus { semantic.progress(allVersions: allVersions) }
    private func remove(_ id: String) throws {
        try db.execute("DELETE FROM documents WHERE id IN (SELECT key FROM versions WHERE call_id = ?)", [id])
        try db.execute("DELETE FROM passages WHERE key IN (SELECT key FROM versions WHERE call_id = ?)", [id])
        try db.execute("DELETE FROM versions WHERE call_id = ?", [id])
        try db.execute("DELETE FROM calls WHERE id = ?", [id])
    }
    private func index(_ call: AgentCall) throws {
        let recording = call.recording
        let additionalNames = recording.participantDisplayNames.filter { !recording.details.participants.contains($0) }
        let metadata = ([recording.sourceName, recording.details.description] + recording.details.participants + additionalNames + recording.details.tags).joined(separator: "\n")
        let versions: [LibraryTranscript?] = recording.transcripts.isEmpty ? [nil] : recording.transcripts.map { $0 }
        for (position, version) in versions.enumerated() {
            let key = version.map(call.versionID) ?? call.id
            let paragraphs = recording.detailsError == nil ? version?.document?.paragraphs ?? [] : []
            let speakers = version.map { v in paragraphs.map { call.speaker($0, version: v) } } ?? []
            try db.execute("INSERT INTO versions VALUES (?, ?, ?, ?, ?)", [key, call.id, version?.id ?? "", position == 0 ? "1" : "0", String(paragraphs.count)])
            try db.execute("INSERT INTO documents VALUES (?, ?, ?, ?, ?, ?)", [key, recording.name, metadata, speakers.joined(separator: "\n"), paragraphs.map(\.text).joined(separator: " "), recording.summary?.current?.markdown ?? ""])
            for (i, paragraph) in paragraphs.enumerated() {
                try db.execute("INSERT INTO passages VALUES (?, ?, ?, ?)", [key, String(paragraph.id), speakers[i], paragraph.text])
            }
        }
    }
    private func versions(_ query: LibrarySearchQuery, allVersions: Bool, transcriptsOnly: Bool) throws -> [[String]] {
        guard let expression = query.expression else { return [] }
        let rows = try db.rows("""
            SELECT versions.key, call_id, path, paragraph_count, bm25(documents, 0, 5, 2, 1, 1, 2), snippet(documents, 5, '', '', ' … ', 28)
            FROM documents JOIN versions ON versions.key = documents.id
            WHERE documents MATCH ? AND (? = '1' OR latest = 1)
            ORDER BY bm25(documents, 0, 5, 2, 1, 1, 2), call_id, versions.key
            """, [transcriptsOnly ? "{speakers body} : (\(expression))" : expression, allVersions ? "1" : "0"])
        return rows.sorted { a, b in
            let left = Double(a[4]) ?? 0, right = Double(b[4]) ?? 0
            if left != right { return left < right }
            let leftDate = cached[a[1]]?.call.recording.date ?? .distantPast
            let rightDate = cached[b[1]]?.call.recording.date ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            if a[1] != b[1] { return a[1] < b[1] }
            return a[0] < b[0]
        }
    }
    private func evidence(_ query: LibrarySearchQuery) throws -> [String: [(id: Int, text: String)]] {
        guard let expression = query.evidenceExpression else { return [:] }
        let rows = try db.rows("SELECT key, paragraph, snippet(passages, 3, '', '', ' … ', 28) FROM passages WHERE passages MATCH ? ORDER BY CAST(paragraph AS INTEGER)", [expression])
        return Dictionary(grouping: rows, by: { $0[0] }).mapValues { $0.map { (Int($0[1])!, $0[2]) } }
    }
    public func search(_ text: String, allVersions: Bool = false) throws -> [LibrarySearchHit] {
        lock.lock(); defer { lock.unlock() }
        try beginRead(); defer { try? db.execute("ROLLBACK") }
        let query = LibrarySearchQuery(text)
        if query.isEmpty { return calls.map { .init(recordingID: $0.recording.id, versionID: nil, paragraphIDs: [], snippet: nil, score: 0) } }
        let rows = try versions(query, allVersions: allVersions, transcriptsOnly: false)
        guard !rows.isEmpty else { return [] }
        let evidence = try evidence(query)
        var seen = Set<String>()
        return rows.compactMap { row in
            guard seen.insert(row[1]).inserted, let call = cached[row[1]]?.call else { return nil }
            let paragraphs = evidence[row[0]] ?? []
            let summaryMatch = paragraphs.isEmpty && !query.highlightRanges(in: call.recording.summary?.current?.markdown ?? "").isEmpty
            return .init(recordingID: call.recording.id, versionID: summaryMatch || row[2].isEmpty ? nil : row[2], paragraphIDs: paragraphs.map(\.id),
                         snippet: summaryMatch ? "Summary · " + row[5] : paragraphs.first?.text, score: Double(row[4]) ?? 0, summaryMatch: summaryMatch)
        }
    }
    func passages(_ text: String, allVersions: Bool, allowed: Set<String>) throws -> [LibrarySearchPassage] {
        lock.lock(); defer { lock.unlock() }
        try beginRead(); defer { try? db.execute("ROLLBACK") }
        let query = LibrarySearchQuery(text)
        let rows = try versions(query, allVersions: allVersions, transcriptsOnly: true).filter { allowed.contains($0[1]) }
        guard !rows.isEmpty else { return [] }
        let evidence = try evidence(query)
        var result: [LibrarySearchPassage] = []
        for row in rows {
            let ids = evidence[row[0], default: []].map(\.id), count = Int(row[3])!
            var windows: [(range: Range<Int>, matches: [Int])] = []
            for id in ids {
                let window = max(0, id - 1)..<min(count, id + 2)
                if let last = windows.last, window.lowerBound <= last.range.upperBound {
                    windows[windows.count - 1] = (last.range.lowerBound..<max(last.range.upperBound, window.upperBound), last.matches + [id])
                } else { windows.append((window, [id])) }
            }
            // Split long runs into disjoint, bounded pages of context. No repeated
            // neighbors, even if every paragraph matches a common search word.
            for window in windows {
                for start in stride(from: window.range.lowerBound, to: window.range.upperBound, by: 8) {
                    let range = start..<min(start + 8, window.range.upperBound)
                    let matches = window.matches.filter { range.contains($0) }
                    guard !matches.isEmpty else { continue }
                    result.append(.init(callID: row[1], versionID: row[2], matchingParagraphs: matches, context: range))
                }
            }
        }
        return result
    }
    private func beginRead() throws {
        try db.execute("BEGIN")
        do {
            let rows = try db.rows("SELECT id, fingerprint FROM calls")
            guard rows.count == cached.count, rows.allSatisfy({ cached[$0[0]]?.fingerprint == $0[1] }) else {
                throw RecorderError.message("The search index changed in another process. Refresh and retry.")
            }
        } catch { try? db.execute("ROLLBACK"); throw error }
    }
}

final class SearchDatabase {
    private var handle: OpaquePointer?
    init(url: URL, durable: Bool = false) throws {
        // Versioned scope databases are disposable; a corrupt cache can be rebuilt.
        func open() throws {
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
            sqlite3_busy_timeout(handle, 10_000)
            try execute("PRAGMA journal_mode=WAL")
            guard !durable else { return }
            let check = try rows("PRAGMA quick_check")
            guard check.first?.first == "ok" else { throw failure() }
        }
        do { try open() }
        catch {
            let code = sqlite3_errcode(handle)
            sqlite3_close(handle); handle = nil
            guard !durable, code == SQLITE_CORRUPT || code == SQLITE_NOTADB else { throw error }
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
            try open()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard !durable else { return }
        try execute("CREATE TABLE IF NOT EXISTS calls (id TEXT PRIMARY KEY, fingerprint TEXT, revision TEXT, snapshot TEXT)")
        try execute("CREATE TABLE IF NOT EXISTS versions (key TEXT PRIMARY KEY, call_id TEXT, path TEXT, latest INTEGER, paragraph_count INTEGER)")
        try execute("CREATE INDEX IF NOT EXISTS versions_call ON versions(call_id)")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(id UNINDEXED, title, metadata, speakers, body, summary, tokenize=\"unicode61 remove_diacritics 2 tokenchars '_'\")")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(key UNINDEXED, paragraph UNINDEXED, speaker, body, tokenize=\"unicode61 remove_diacritics 2 tokenchars '_'\")")
    }
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    deinit { sqlite3_close(handle) }
    private func failure() -> Error { RecorderError.message("Search index: " + String(cString: sqlite3_errmsg(handle))) }
    func execute(_ sql: String, _ values: [String] = []) throws { _ = try rows(sql, values) }
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw failure() }
        }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }
}
