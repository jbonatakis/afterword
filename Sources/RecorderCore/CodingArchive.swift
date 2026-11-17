import Foundation
import Lookback

public struct CodingSession: Codable, Identifiable, Sendable, Equatable {
    public let id, source, title, project: String
    public let branch: String?
    public let started: Date?
    public let updated: Date
}

public struct CodingMessage: Codable, Identifiable, Sendable {
    public let id, role, text: String
    public let parentID: String?
    public let timestamp: Date?
    public let tools: [String]
}

public struct CodingHistory: Codable, Sendable {
    public let session: CodingSession
    public let messages: [CodingMessage]
    public let conversationIDs: [String]

    public var conversation: [CodingMessage] {
        let map = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return conversationIDs.compactMap { map[$0] }
    }
}

public struct CodingImportSettings: Sendable {
    public let enabled: Bool
    public let projects: [String]
}

public struct CodingHit: Sendable {
    public let session: CodingSession
    public let messageID: String?
    public let text: String
    public let timestamp: Date?
    public let archived: Bool
}

// Each connection has one owner. SQLite transactions coordinate the importer, UI and MCP processes.
public final class CodingArchive {
    public static let directory = AgentAccessStore.directory.deletingLastPathComponent().appendingPathComponent("CodingSessions", isDirectory: true)
    private let db: SearchDatabase
    public static func exists(in directory: URL = directory) -> Bool {
        PrivateFiles.isRegular(directory.appendingPathComponent("History.sqlite"))
    }

    public init(directory: URL = directory) throws {
        try PrivateFiles.directory(directory)
        db = try SearchDatabase(url: directory.appendingPathComponent("History.sqlite"), durable: true)
        try db.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS projects (path TEXT PRIMARY KEY)")
        try db.execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, project TEXT NOT NULL, modified TEXT NOT NULL, info TEXT NOT NULL, history TEXT NOT NULL)")
        try db.execute("CREATE INDEX IF NOT EXISTS sessions_project ON sessions(project)")
        try db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS coding_text USING fts5(session UNINDEXED, message UNINDEXED, stamp UNINDEXED,
              archived UNINDEXED, title, project, branch, body, embed UNINDEXED, tokenize="unicode61 remove_diacritics 2 tokenchars '_'")
            """)
    }

    public func settings() throws -> CodingImportSettings {
        try .init(enabled: db.rows("SELECT value FROM settings WHERE key='enabled'").first?.first == "1",
                  projects: db.rows("SELECT path FROM projects ORDER BY path").map { $0[0] })
    }
    public func setEnabled(_ value: Bool) throws {
        try db.execute("INSERT OR REPLACE INTO settings VALUES ('enabled',?)", [value ? "1" : "0"])
    }
    public func addProject(_ path: String) throws {
        guard path.hasPrefix("/") else { throw RecorderError.message("Select a project with a working directory.") }
        try db.execute("INSERT OR IGNORE INTO projects VALUES (?)", [path])
    }
    public func removeProject(_ path: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM projects WHERE path=?", [path])
            try db.execute("DELETE FROM coding_text WHERE session IN (SELECT id FROM sessions WHERE project=?)", [path])
            try db.execute("DELETE FROM sessions WHERE project=?", [path])
            try bumpRevision()
        }
    }

    public static func availableProjects(reader: any SessionReader = ClaudeCodeReader()) throws -> [String] {
        Array(Set(try reader.listSessions().compactMap(\.workingDirectory).filter { $0.hasPrefix("/") })).sorted()
    }
    public func synchronize(reader: any SessionReader = ClaudeCodeReader()) throws {
        let options = try settings()
        guard options.enabled, !options.projects.isEmpty else { return }
        let allowed = Set(options.projects)
        let known = try Dictionary(uniqueKeysWithValues: db.rows("SELECT id,modified FROM sessions").map { ($0[0], $0[1]) })
        var failures = 0
        for info in try reader.listSessions() {
            try Task.checkCancellation()
            guard let project = info.workingDirectory, allowed.contains(project) else { continue }
            let id = AgentJSON.hash(info.id.source + "/" + info.id.value)
            let stamp = String(info.modifiedAt.timeIntervalSince1970)
            guard known[id] != stamp else { continue }
            do {
                let source = try reader.readSession(info.id)
                let session = CodingSession(id: id, source: info.id.source, title: info.title, project: project,
                                            branch: info.gitBranch, started: info.createdAt, updated: info.modifiedAt)
                let imported = Self.project(source, session: session)
                try Task.checkCancellation()
                try db.transaction {
                    let current = try settings()
                    guard current.enabled, current.projects.contains(project) else { return }
                    let previous = try db.rows("SELECT modified FROM sessions WHERE id=?", [id]).first?.first
                    guard previous == known[id] else { return } // A newer import won the race.
                    var history = imported
                    if previous != nil {
                        // Rotation can drop pre-compaction rows from the source file. Preserve the archived evidence.
                        let old = try self.history(id: id)
                        let latest = Dictionary(uniqueKeysWithValues: imported.messages.map { ($0.id, $0) })
                        let oldIDs = Set(old.messages.map(\.id))
                        let merged = old.messages.map { latest[$0.id] ?? $0 } + imported.messages.filter { !oldIDs.contains($0.id) }
                        history = CodingHistory(session: session, messages: merged, conversationIDs: imported.conversationIDs)
                    }
                    try db.execute("DELETE FROM coding_text WHERE session=?", [id])
                    try db.execute("INSERT OR REPLACE INTO sessions VALUES (?,?,?,?,?)",
                                   [id, project, stamp, try Self.encode(session), try Self.encode(history)])
                    try index(history)
                    try bumpRevision()
                }
            } catch is CancellationError { throw CancellationError() }
            catch SessionReadError.sessionNotFound { continue }
            catch { failures += 1 }
        }
        if failures > 0 { throw RecorderError.message("Could not import \(failures) coding session(s). Afterword will retry.") }
    }

    private static func project(_ source: SessionHistory, session: CodingSession) -> CodingHistory {
        let parents = Dictionary(source.recordedMessages.map { ($0.id, $0.parentID) }, uniquingKeysWith: { _, last in last })
        var seen = Set<String>()
        let messages = source.recordedMessages.compactMap { message -> CodingMessage? in
            var text: [String] = [], tools: [String] = []
            for block in message.blocks {
                switch block {
                case .text(let value) where message.role != .tool: text.append(value)
                case .toolCall(_, let name, _): tools.append(name)
                default: break
                }
            }
            guard !text.isEmpty || !tools.isEmpty, seen.insert(message.id).inserted else { return nil }
            let role: String
            switch message.role {
            case .user: role = "User"
            case .assistant: role = "Assistant"
            case .system: role = message.isCompactionSummary ? "Compaction summary" : "System"
            case .tool: role = "Tool"
            }
            var parent = message.parentID
            var visited = Set<String>()
            while let id = parent, !seen.contains(id), visited.insert(id).inserted { parent = parents[id] ?? nil }
            return .init(id: message.id, role: role, text: text.joined(separator: "\n\n"), parentID: parent, timestamp: message.timestamp, tools: tools)
        }
        return .init(session: session, messages: messages, conversationIDs: source.conversation.map(\.id).filter(seen.contains))
    }

    private func index(_ history: CodingHistory) throws {
        let info = history.session
        let current = Set(history.conversationIDs)
        try db.execute("INSERT INTO coding_text VALUES (?,?,?,?,?,?,?,?,?)",
                       [info.id, "", String(info.updated.timeIntervalSince1970), "0", info.title, info.project, info.branch ?? "", "", "0"])
        let byID = Dictionary(uniqueKeysWithValues: history.messages.map { ($0.id, $0) })
        func previous(_ message: CodingMessage, role: String) -> CodingMessage? {
            var cursor = message.parentID
            var seen = Set<String>()
            while let id = cursor, seen.insert(id).inserted {
                if let candidate = byID[id], !candidate.text.isEmpty {
                    if candidate.role == role { return candidate }
                    if candidate.role == "User" || candidate.role == "Compaction summary" { break }
                }
                cursor = byID[id]?.parentID
            }
            return nil
        }
        for message in history.messages {
            var context = ""
            if message.role == "Assistant", !message.text.isEmpty, let prompt = previous(message, role: "User") {
                context = String(prompt.text.prefix(220))
            } else if message.role == "User", message.text.count < 60, let proposal = previous(message, role: "Assistant") {
                context = String(proposal.text.suffix(220))
            }
            var pieces = SemanticChunker.split(message.text)
            if pieces.isEmpty && !message.tools.isEmpty { pieces = [""] }
            for piece in pieces {
                let body = [context, piece, message.tools.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: "\n\n")
                try db.execute("INSERT INTO coding_text VALUES (?,?,?,?,?,?,?,?,?)", [
                    info.id, message.id, message.timestamp.map { String($0.timeIntervalSince1970) } ?? "",
                    current.contains(message.id) ? "0" : "1", "", "", "", body, piece.isEmpty ? "0" : "1"])
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private func bumpRevision() throws {
        try db.execute("INSERT OR REPLACE INTO settings VALUES ('revision',?)", [UUID().uuidString])
    }
    var revision: String { get throws { try db.rows("SELECT value FROM settings WHERE key='revision'").first?.first ?? "" } }
    public func sessions() throws -> [CodingSession] {
        try db.rows("SELECT info FROM sessions ORDER BY CAST(modified AS REAL) DESC,id").map {
            try JSONDecoder().decode(CodingSession.self, from: Data($0[0].utf8))
        }
    }
    public func history(id: String) throws -> CodingHistory {
        guard let row = try db.rows("SELECT history FROM sessions WHERE id=?", [id]).first else { throw AgentFailure("Coding session unavailable.") }
        return try JSONDecoder().decode(CodingHistory.self, from: Data(row[0].utf8))
    }
    func embeddingChunks() throws -> [SemanticChunk] {
        try db.rows("SELECT session,message,body,stamp,archived FROM coding_text WHERE embed='1' ORDER BY rowid").flatMap { row in
            SemanticChunker.split(row[2]).map {
                SemanticChunk(origin: .coding(session: row[0], message: row[1], timestamp: Double(row[3]).map(Date.init(timeIntervalSince1970:)), archived: row[4] == "1"), latest: true, text: $0)
            }
        }
    }

    /// During date-based browsing the evidence date belongs to the message, even when a session spans days.
    func browse(from: Date?, to: Date?, project: String?, branch: String?) throws -> [CodingHit] {
        let selected = try sessions().filter { (project == nil || project == $0.project) && (branch == nil || branch == $0.branch) }
        guard from != nil || to != nil else {
            return selected.map { CodingHit(session: $0, messageID: nil, text: $0.title, timestamp: $0.updated, archived: false) }
        }
        let byID = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        var clauses = ["message != ''", "stamp != ''"], values: [String] = []
        if let from { clauses.append("CAST(stamp AS REAL) >= CAST(? AS REAL)"); values.append(String(from.timeIntervalSince1970)) }
        if let to { clauses.append("CAST(stamp AS REAL) < CAST(? AS REAL)"); values.append(String(to.timeIntervalSince1970)) }
        let sql = "SELECT session,message,stamp,archived,substr(body,1,450),min(rowid) FROM coding_text WHERE " +
            clauses.joined(separator: " AND ") + " GROUP BY session,message ORDER BY CAST(stamp AS REAL) DESC,session,message"
        return try db.rows(sql, values).compactMap { row in
            guard let session = byID[row[0]], let date = Double(row[2]) else { return nil }
            return CodingHit(session: session, messageID: row[1], text: row[4], timestamp: Date(timeIntervalSince1970: date), archived: row[3] == "1")
        }
    }

    func matches(query: String, semantic: [(SemanticChunk, Float)], from: Date?, to: Date?, project: String?, branch: String?) throws -> [CodingHit] {
        let parsed = LibrarySearchQuery(query)
        guard let expression = parsed.expression else { return [] }
        let sessions = try Dictionary(uniqueKeysWithValues: sessions().map { ($0.id, $0) })
        var rows: [String: CodingHit] = [:], scores: [String: Double] = [:]
        func add(_ id: String, message: String, date: Date?, archived: Bool, excerpt: String, score: Double, semantic: Bool) -> Bool {
            guard let session = sessions[id], project == nil || session.project == project,
                  branch == nil || session.branch == branch else { return false }
            if let from, date.map({ $0 >= from }) != true { return false }
            if let to, date.map({ $0 < to }) != true { return false }
            let key = id + ":" + message
            if rows[key] == nil {
                rows[key] = CodingHit(session: session, messageID: message.isEmpty ? nil : message,
                                      text: String(excerpt.prefix(450)), timestamp: date, archived: archived)
            }
            if semantic { scores[key, default: 0] += score }
            else { scores[key] = max(scores[key] ?? 0, score) }
            return true
        }
        for (rank,row) in try db.rows("""
            SELECT session,message,stamp,archived,CASE WHEN message='' THEN title ELSE snippet(coding_text,7,'','','…',35) END
            FROM coding_text WHERE coding_text MATCH ? ORDER BY bm25(coding_text),rowid
            """, [expression]).enumerated() {
            _ = add(row[0], message: row[1], date: Double(row[2]).map(Date.init(timeIntervalSince1970:)),
                    archived: row[3] == "1", excerpt: row[4], score: 1.3 / Double(61 + rank), semantic: false)
        }
        var seen = Set<String>()
        for (chunk, _) in semantic {
            guard case let .coding(id, message, date, archived) = chunk.origin else { continue }
            let key = id + ":" + message
            guard !seen.contains(key), parsed.matchesQuotes(chunk.text) else { continue }
            if add(id, message: message, date: date, archived: archived, excerpt: chunk.text, score: 1.0 / Double(61 + seen.count), semantic: true) {
                seen.insert(key)
                if seen.count >= 80 { break }
            }
        }
        return rows.keys.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0, default: 0] > scores[$1, default: 0] }.compactMap { rows[$0] }
    }
}
