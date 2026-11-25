import Foundation
import Lookback

public struct CodingSession: Codable, Identifiable, Sendable, Equatable {
    public let id, source, title, project: String
    public let branch: String?
    public let started: Date?
    public fileprivate(set) var updated: Date
    // Claude also writes bookkeeping to its transcript. Use this stamp only to detect source changes.
    fileprivate var sourceModified: Date? = nil
    fileprivate var currentTranscriptVersion: Int { source == CodingProvider.codex.rawValue ? 4 : 3 }
    // Legacy archives gain tool evidence when their source is next available.
    var transcriptVersion: Int? = nil
    public var providerName: String { CodingProvider(rawValue: source)?.name ?? source }
}

public typealias CodingTaskNotification = SessionTaskNotification

public struct CodingMessage: Codable, Identifiable, Sendable, Equatable {
    public let id, role, text: String
    public let parentID: String?
    public let timestamp: Date?
    public let tools: [String]

    public internal(set) var toolCalls: [CodingToolCall]? = nil
    public var displayedToolCalls: [CodingToolCall] { toolCalls ?? tools.map(CodingToolCall.init(name:)) }

    public internal(set) var taskNotification: CodingTaskNotification? = nil

    fileprivate var searchText: String {
        guard let taskNotification else { return text }
        let fields = [taskNotification.summary, taskNotification.status, taskNotification.result].compactMap { $0 }
        return fields.isEmpty ? text : fields.joined(separator: "\n\n")
    }

    fileprivate var hasText: Bool { text.contains { !$0.isWhitespace } }
}

public struct CodingHistory: Codable, Sendable, Equatable {
    public fileprivate(set) var session: CodingSession
    public let messages: [CodingMessage]
    public let conversationIDs: [String]
    // Tool evidence belongs to the call, but a later completion has its own activity time.
    var latestToolResult: Date? = nil

    fileprivate var latestClaudeActivity: Date? {
        let latestMessage = messages.lazy.filter {
            ($0.role == "User" || $0.role == "Assistant") && ($0.hasText || !$0.tools.isEmpty)
        }.compactMap(\.timestamp).max()
        return [latestMessage, latestToolResult].compactMap { $0 }.max()
    }

    public var conversation: [CodingMessage] {
        let map = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return conversationIDs.compactMap { map[$0] }
    }
}

public enum CodingProvider: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case pi
    case antigravity

    public var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Google Antigravity"
        case .pi: return "Pi"
        }
    }
    // Keep the original Claude preference for existing archives.
    fileprivate var enabledKey: String {
        switch self {
        case .claudeCode: return "enabled"
        case .codex: return "codexEnabled"
        case .antigravity: return "antigravityEnabled"
        case .pi: return "piEnabled"
        }
    }
}

public struct CodexScope: Hashable, Sendable {
    public let accountID, userID: String
    public init(accountID: String = "", userID: String = "") {
        self.accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct LocalCodexAccount: Identifiable, Sendable {
    public let id: CodexScope
    public let project: String?
    public let lastUsed: Date
    public var shortID: String { String(AgentJSON.hash(id.accountID + "/" + id.userID).prefix(6)) }
}

public enum CodexAccountSelection: Hashable, Sendable {
    case automatic, unscoped, account(CodexScope)

    func resolve(_ accounts: [LocalCodexAccount]) -> CodexScope? {
        switch self {
        case .automatic: return accounts.count == 1 ? accounts[0].id : nil
        case .unscoped: return nil
        case .account(let scope): return scope
        }
    }
}

public struct CodingImportSettings: Sendable {
    public let providers: Set<CodingProvider>
    public let codexAccount: CodexAccountSelection
    public let piSessionsDirectory: URL?
    public let projectSelection: CodingProjectSelection
}

struct CodingPassage: Sendable {
    let messageID, text: String
    let timestamp: Date?
    let archived: Bool
    var toolIndex: Int? = nil
    var eventIndex: Int? = nil

    func sameAnchor(as other: Self) -> Bool { messageID == other.messageID && toolIndex == other.toolIndex && eventIndex == other.eventIndex }
}

public struct CodingHit: Sendable {
    public let session: CodingSession
    let passages: [CodingPassage]
    var lastActivity: Date?
    var toolOnlyMessageCount: Int?

    public var messageID: String? { passages.first?.messageID }
    public var toolIndex: Int? { passages.first?.toolIndex }
    public var eventIndex: Int? { passages.first?.eventIndex }
    public var text: String { passages.first?.text ?? session.title }
    public var timestamp: Date? {
        if let passage = passages.first { return passage.timestamp }
        return lastActivity ?? session.updated
    }
    public var archived: Bool { passages.first?.archived ?? false }
}

public struct CodingBrowseFilter: Equatable, Sendable {
    public var provider: CodingProvider?
    public var project: String?
    public var branch: String?
    public init(provider: CodingProvider? = nil, project: String? = nil, branch: String? = nil) {
        self.provider = provider; self.project = project; self.branch = branch
    }
}

public struct CodingSessionPage: Sendable {
    public struct Cursor: Sendable {
        fileprivate let modified, id: String
    }
    public let sessions: [CodingSession]
    public let revision: String
    public let next: Cursor?
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
        try db.execute("CREATE TABLE IF NOT EXISTS project_folders (path TEXT PRIMARY KEY, included INTEGER NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, project TEXT NOT NULL, modified TEXT NOT NULL, info TEXT NOT NULL, history TEXT NOT NULL)")
        try db.execute("CREATE INDEX IF NOT EXISTS sessions_project ON sessions(project)")
        for (name, prefix) in [("recent", ""), ("project_recent", "project,"),
                               ("provider_recent", "json_extract(info,'$.source'),"), ("branch_recent", "json_extract(info,'$.branch'),")] {
            try db.execute("CREATE INDEX IF NOT EXISTS sessions_\(name) ON sessions(\(prefix) -CAST(modified AS REAL),id)")
        }
        try db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS coding_text USING fts5(session UNINDEXED, message UNINDEXED, stamp UNINDEXED,
              archived UNINDEXED, title, project, branch, body, embed UNINDEXED, tokenize="unicode61 remove_diacritics 2 tokenchars '_'")
            """)
        // Local tool evidence has its own index. Existing MCP readers and embedding jobs only see coding_text.
        try db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS coding_tool_text USING fts5(session UNINDEXED, message UNINDEXED,
              position UNINDEXED, event UNINDEXED, stamp UNINDEXED, archived UNINDEXED, body, tokenize="unicode61 remove_diacritics 2 tokenchars '_'")
            """)
        try migrateClaudeActivityDates()
    }

    private func migrateClaudeActivityDates() throws {
        let pending = "SELECT 1 FROM settings WHERE key='claudeActivityDatesV1'"
        guard try db.rows(pending).isEmpty else { return }
        try db.transaction {
            guard try db.rows(pending).isEmpty else { return }
            let sessions = try db.rows("SELECT id FROM sessions WHERE json_extract(info,'$.source')='claude-code'")
            for row in sessions {
                let history = try history(id: row[0])
                let date = history.latestClaudeActivity ?? history.session.started ?? history.session.updated
                // Preserve pending transcript repairs and allow the next import to recover raw tool result times.
                try db.execute("""
                    UPDATE sessions SET modified=?, info=json_set(info,'$.updated',CAST(? AS REAL)),
                      history=json_set(history,'$.session.updated',CAST(? AS REAL)) WHERE id=?
                    """, [String(date.timeIntervalSince1970), String(date.timeIntervalSinceReferenceDate),
                          String(date.timeIntervalSinceReferenceDate), row[0]])
            }
            if !sessions.isEmpty {
                try db.execute("""
                    UPDATE coding_text SET stamp=(SELECT modified FROM sessions WHERE id=coding_text.session)
                    WHERE message='' AND session IN (SELECT id FROM sessions WHERE json_extract(info,'$.source')='claude-code')
                    """)
                try bumpRevision()
            }
            try db.execute("INSERT INTO settings VALUES ('claudeActivityDatesV1','1')")
        }
    }

    public func settings() throws -> CodingImportSettings {
        let values = try Dictionary(uniqueKeysWithValues: db.rows("SELECT key,value FROM settings").map { ($0[0], $0[1]) })
        let scope = CodexScope(accountID: values["codexAccountID"] ?? "", userID: values["codexUserID"] ?? "")
        let account: CodexAccountSelection = values["codexUnscopedOnly"] == "1" ? .unscoped :
            (scope.accountID.isEmpty ? .automatic : .account(scope))
        return try .init(providers: Set(CodingProvider.allCases.filter { values[$0.enabledKey] == "1" }),
                         codexAccount: account,
                         piSessionsDirectory: values["piSessionsDirectory"].map { URL(fileURLWithPath: $0, isDirectory: true) },
                         projectSelection: projectSelection())
    }

    private func projectSelection() throws -> CodingProjectSelection {
        let exact = try Set(db.rows("SELECT path FROM projects").compactMap { CodingProjectSelection.path($0[0]) })
        let folders = try Dictionary(uniqueKeysWithValues: db.rows("SELECT path,included FROM project_folders").map { ($0[0], $0[1] == "1") })
        return CodingProjectSelection(exact: exact, folders: folders)
    }
    public func setEnabled(_ value: Bool, for provider: CodingProvider = .claudeCode) throws {
        try db.execute("INSERT OR REPLACE INTO settings VALUES (?,?)", [provider.enabledKey, value ? "1" : "0"])
    }
    public func setPiSessionsDirectory(_ directory: URL?) throws {
        if let directory {
            guard directory.isFileURL else { throw RecorderError.message("Choose a local Pi session folder.") }
            try db.execute("INSERT OR REPLACE INTO settings VALUES ('piSessionsDirectory',?)", [directory.standardizedFileURL.path])
        } else {
            try db.execute("DELETE FROM settings WHERE key='piSessionsDirectory'")
        }
    }
    public func setCodexAccount(_ selection: CodexAccountSelection) throws {
        try db.transaction {
            try db.execute("DELETE FROM settings WHERE key IN ('codexAccountID','codexUserID','codexUnscopedOnly')")
            switch selection {
            case .automatic: break
            case .unscoped: try db.execute("INSERT INTO settings VALUES ('codexUnscopedOnly','1')")
            case .account(let scope):
                try db.execute("INSERT INTO settings VALUES ('codexAccountID',?),('codexUserID',?)", [scope.accountID, scope.userID])
            }
        }
    }
    public func addProject(_ path: String) throws {
        guard let path = CodingProjectSelection.path(path) else { throw RecorderError.message("Select a project with a working directory.") }
        try db.execute("INSERT OR IGNORE INTO projects VALUES (?)", [path])
    }
    public func removeProject(_ path: String) throws {
        try setProjectFolder(path, included: false)
    }

    public func setProjectFolder(_ value: String, included: Bool) throws {
        guard let path = CodingProjectSelection.path(value) else { throw RecorderError.message("Select a folder with an absolute path.") }
        try db.transaction {
            let selection = try projectSelection()
            try saveProjectSelection(selection.settingFolder(path, included: included))
            if !included {
                try removeHistory { CodingProjectSelection.contains($0, in: path) }
            }
        }
    }

    public func applyProjectSelection(_ next: CodingProjectSelection, replacing previous: CodingProjectSelection) throws {
        try db.transaction {
            guard try projectSelection() == previous else {
                throw RecorderError.message("Project selections changed. Review the current folders and apply again.")
            }
            try saveProjectSelection(next)
            if next.removesProjects(from: previous) {
                try removeHistory { previous.includes($0) && !next.includes($0) }
            }
        }
    }

    private func saveProjectSelection(_ selection: CodingProjectSelection) throws {
        try db.execute("DELETE FROM projects")
        try db.execute("DELETE FROM project_folders")
        for path in selection.exact { try db.execute("INSERT INTO projects VALUES (?)", [path]) }
        for (path, included) in selection.folders {
            try db.execute("INSERT INTO project_folders VALUES (?,?)", [path, included ? "1" : "0"])
        }
    }

    private func removeHistory(where excluded: (String) -> Bool) throws {
        for row in try db.rows("SELECT DISTINCT project FROM sessions") {
            guard let path = CodingProjectSelection.path(row[0]), excluded(path) else { continue }
            try db.execute("DELETE FROM coding_tool_text WHERE session IN (SELECT id FROM sessions WHERE project=?)", [row[0]])
            try db.execute("DELETE FROM coding_text WHERE session IN (SELECT id FROM sessions WHERE project=?)", [row[0]])
            try db.execute("DELETE FROM sessions WHERE project=?", [row[0]])
        }
        try bumpRevision()
    }

    public func refresh(discoverProjects: Bool, provider requested: CodingProvider? = nil,
                        readers: [any SessionReader]? = nil, onlySessionID: String? = nil) throws -> (projects: [String], issues: [String], accounts: [LocalCodexAccount]) {
        let options = try settings()
        var projects = Set<String>(), issues: [String] = []
        var accounts: [LocalCodexAccount] = []
        guard discoverProjects || options.projectSelection.hasIncludes else { return ([], [], []) }
        let sources = readers ?? [ClaudeCodeReader(), CodexReader(includeArchived: true), PiReader(sessionsDirectory: options.piSessionsDirectory), AntigravityReader()]
        for var reader in sources {
            guard let provider = CodingProvider(rawValue: reader.source), options.providers.contains(provider),
                  requested == nil || requested == provider else { continue }
            do {
                try Task.checkCancellation()
                if let codex = reader as? CodexReader {
                    let catalog = try codex.catalogSnapshot()
                    accounts = try catalog.localAccounts().map {
                        LocalCodexAccount(id: .init(accountID: $0.accountID, userID: $0.userID ?? ""), project: $0.lastWorkingDirectory, lastUsed: $0.lastModified)
                    }
                    let scope = options.codexAccount.resolve(accounts)
                    reader = catalog.scoped(accountID: scope?.accountID, userID: scope?.userID)
                } else if let claude = reader as? ClaudeCodeReader {
                    reader = try claude.catalogSnapshot()
                } else if let agy = reader as? AntigravityReader {
                    reader = try agy.catalogSnapshot()
                } else if let pi = reader as? PiReader {
                    reader = try pi.catalogSnapshot()
                }
                var infos = try reader.listSessions()
                if let onlySessionID { infos = infos.filter { AgentJSON.hash($0.id.source + "/" + $0.id.value) == onlySessionID } }
                if discoverProjects { projects.formUnion(infos.compactMap(\.workingDirectory).filter { $0.hasPrefix("/") }) }
                if options.projectSelection.hasIncludes { try synchronize(infos, reader: reader, provider: provider, options: options) }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append("\(provider.name): \(error.localizedDescription)") }
        }
        return (projects.sorted(), issues, accounts)
    }

    public func synchronize(reader: any SessionReader) throws {
        let result = try refresh(discoverProjects: false, readers: [reader])
        if !result.issues.isEmpty { throw RecorderError.message(result.issues.joined(separator: "\n")) }
    }

    private func synchronize(_ infos: [SessionInfo], reader: any SessionReader, provider: CodingProvider, options: CodingImportSettings) throws {
        guard !infos.isEmpty else { return }
        let rows = try db.rows("SELECT id,info FROM sessions WHERE json_extract(info,'$.source')=?", [provider.rawValue])
        let known = Dictionary(uniqueKeysWithValues: rows.map { ($0[0], $0[1]) })
        var failures = 0
        for info in infos {
            try Task.checkCancellation()
            guard let project = info.workingDirectory, options.projectSelection.includes(project) else { continue }
            let id = AgentJSON.hash(info.id.source + "/" + info.id.value)
            do {
                let old = try known[id].map { try JSONDecoder().decode(CodingSession.self, from: Data($0.utf8)) }
                var session = CodingSession(id: id, source: info.id.source, title: info.title, project: project,
                                            branch: info.gitBranch, started: info.createdAt, updated: info.modifiedAt)
                session.transcriptVersion = session.currentTranscriptVersion
                if provider == .claudeCode {
                    session.sourceModified = info.modifiedAt
                    session.updated = old?.updated ?? info.createdAt ?? info.modifiedAt
                }
                // Codex can rename a thread in its index without modifying the rollout.
                if old == session { continue }
                let source = try reader.readSession(info.id)
                if let metadata = source.info, metadata.workingDirectory != project { continue }
                let imported = Self.project(source, session: session)
                try Task.checkCancellation()
                try db.transaction {
                    let current = try settings()
                    guard current.providers.contains(provider), current.projectSelection.includes(project),
                          provider != .codex || current.codexAccount == options.codexAccount,
                          provider != .pi || current.piSessionsDirectory == options.piSessionsDirectory else { return }
                    let previous = try db.rows("SELECT info FROM sessions WHERE id=?", [id]).first?.first
                    guard previous == known[id] else { return } // A newer import won the race.
                    var history = imported
                    let saved = previous == nil ? nil : try self.history(id: id)
                    if let old = saved {
                        // Rotation can drop pre-compaction rows from the source file. Preserve the archived evidence.
                        let latest = Dictionary(uniqueKeysWithValues: imported.messages.map { ($0.id, $0) })
                        let oldIDs = Set(old.messages.map(\.id))
                        let merged = old.messages.map { latest[$0.id] ?? $0 } + imported.messages.filter { !oldIDs.contains($0.id) }
                        history = CodingHistory(session: session, messages: merged, conversationIDs: imported.conversationIDs)
                        history.latestToolResult = [old.latestToolResult, imported.latestToolResult].compactMap { $0 }.max()
                    }
                    if provider == .claudeCode {
                        if let activity = history.latestClaudeActivity { history.session.updated = activity }
                        if var prior = saved, old?.transcriptVersion == session.transcriptVersion {
                            prior.session.sourceModified = session.sourceModified
                            if prior == history {
                                // A bookkeeping write needs a new import stamp, but the feed and search index are current.
                                let info = try Self.encode(history.session)
                                try db.execute("UPDATE sessions SET info=?,history=json_set(history,'$.session',json(?)) WHERE id=?",
                                               [info, info, id])
                                return
                            }
                        }
                    }
                    if previous != nil {
                        try db.execute("DELETE FROM coding_text WHERE session=?", [id])
                        try db.execute("DELETE FROM coding_tool_text WHERE session=?", [id])
                    }
                    try db.execute("INSERT OR REPLACE INTO sessions VALUES (?,?,?,?,?)",
                                   [id, project, String(history.session.updated.timeIntervalSince1970),
                                    try Self.encode(history.session), try Self.encode(history)])
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
        let nativeIDs = Set(source.recordedMessages.map(\.id))
        var nearestVisible: [String: String] = [:]
        var occurrences: [String: Int] = [:]
        var idsByPosition: [Int: String] = [:]
        var messages: [CodingMessage] = []
        // Resolve by provider call ID, independent of completion order. Replayed branches can reuse
        // IDs; an ambiguous result is less trustworthy than showing the invocation alone.
        var callIDs = Set<String>(), ambiguous = Set<String>()
        var results: [String: (Data?, Bool)] = [:]
        for message in source.recordedMessages {
            for block in message.blocks {
                switch block {
                case let .toolCall(id, _, _):
                    if !callIDs.insert(id).inserted { ambiguous.insert(id) }
                case let .toolResult(id, content, error):
                    if results.updateValue((content, error), forKey: id) != nil { ambiguous.insert(id) }
                default: break
                }
            }
        }
        for (position, message) in source.recordedMessages.enumerated() {
            var text: [String] = [], calls: [CodingToolCall] = []
            for block in message.blocks {
                switch block {
                case .text(let value) where message.role != .tool: text.append(value)
                case let .toolCall(id, name, input):
                    let unique = !id.isEmpty && !ambiguous.contains(id)
                    let completion = unique ? message.toolEvents.first {
                        $0.id == id && (name == $0.name || name == "functions." + $0.name)
                    } : nil
                    var call = CodingToolCall(name: name, input: input, project: session.project, provider: session.source,
                                              commandCompletion: completion?.name == "exec_command" ? completion?.inputJSON : nil)
                    let reply = unique ? results[id] : nil
                    if reply != nil || completion != nil {
                        call.receive(output: reply?.0 ?? completion?.outputJSON, isError: reply?.1 == true || completion?.isError == true,
                                     reportedExit: completion?.exitCode)
                    }
                    if call.action == .script {
                        let events = message.toolEvents.filter { $0.id != id }
                        if !events.isEmpty {
                            call.events = events.map { CodingToolCall(event: $0, project: session.project, provider: session.source) }
                        }
                    }
                    calls.append(call)
                default: break
                }
            }
            let parent = message.parentID.flatMap { nearestVisible[$0] }
            guard !text.isEmpty || !calls.isEmpty || message.taskNotification != nil else {
                nearestVisible[message.id] = parent
                continue
            }
            // Rollbacks can reuse a native ID. Keep the original citation for the first occurrence.
            var occurrence = occurrences[message.id, default: 0] + 1
            var id = message.id
            if occurrence > 1 {
                id = "\(message.id)#\(occurrence)"
                while nativeIDs.contains(id) { occurrence += 1; id = "\(message.id)#\(occurrence)" }
            }
            occurrences[message.id] = occurrence
            idsByPosition[position] = id
            nearestVisible[message.id] = id
            let role: String
            switch message.role {
            case .user: role = message.taskNotification == nil ? "User" : "Task notification"
            case .assistant: role = "Assistant"
            case .system: role = message.isCompactionSummary ? "Compaction summary" : "System"
            case .tool: role = "Tool"
            }
            messages.append(.init(id: id, role: role, text: text.joined(separator: "\n\n"), parentID: parent, timestamp: message.timestamp, tools: calls.map(\.name),
                                  toolCalls: calls.isEmpty ? nil : calls,
                                  taskNotification: message.taskNotification))
        }
        var conversationIDs: [String] = []
        var activeParents: [String: String] = [:]
        var previous: String?
        for message in source.transcript {
            if message.isCompactionSummary { previous = nil }
            guard let position = message.recordedIndex, let id = idsByPosition[position] else { continue }
            if let notice = message.taskNotification, notice.status == "completed", notice.result == nil { continue }
            conversationIDs.append(id)
            activeParents[id] = previous
            previous = id
        }
        // Codex supplies an ordered active branch without parent IDs. Use that order for search context.
        if session.source == CodingProvider.codex.rawValue {
            messages = messages.map {
                CodingMessage(id: $0.id, role: $0.role, text: $0.text, parentID: activeParents[$0.id], timestamp: $0.timestamp, tools: $0.tools,
                              toolCalls: $0.toolCalls, taskNotification: $0.taskNotification)
            }
        }
        var history = CodingHistory(session: session, messages: messages, conversationIDs: conversationIDs)
        if session.source == CodingProvider.claudeCode.rawValue {
            history.latestToolResult = source.recordedMessages.lazy.filter { $0.role == .tool && $0.taskNotification == nil }
                .compactMap(\.timestamp).max()
        }
        return history
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
            for (index, call) in (message.toolCalls ?? []).enumerated() {
                func insert(_ evidence: CodingToolCall, event: String) throws {
                    try db.execute("INSERT INTO coding_tool_text VALUES (?,?,?,?,?,?,?)", [
                        info.id, message.id, String(index), event, message.timestamp.map { String($0.timeIntervalSince1970) } ?? "",
                        current.contains(message.id) ? "0" : "1", evidence.searchText])
                }
                try insert(call, event: "")
                for (position, event) in (call.events ?? []).enumerated() {
                    try insert(event, event: String(position))
                }
            }
            var pieces = SemanticChunker.split(message.searchText)
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
    public var revision: String { get throws { try db.rows("SELECT value FROM settings WHERE key='revision'").first?.first ?? "" } }
    public func sessionProjects() throws -> [String] {
        try db.rows("SELECT DISTINCT project FROM sessions ORDER BY project").map { $0[0] }
    }
    public func sessionBranches() throws -> [String] {
        try db.rows("SELECT DISTINCT json_extract(info,'$.branch') AS branch FROM sessions WHERE branch IS NOT NULL ORDER BY branch").map { $0[0] }
    }

    /// A short read transaction keeps the cursor and rows on one revision even during an import.
    public static func sessionPage(in directory: URL, filter: CodingBrowseFilter = .init(),
                                   after cursor: CodingSessionPage.Cursor? = nil, limit: Int = 200) throws -> CodingSessionPage {
        guard limit > 0 && limit < Int.max else { throw RecorderError.message("Invalid coding session page size.") }
        guard exists(in: directory) else { return .init(sessions: [], revision: "", next: nil) }
        let db = try SearchDatabase(reading: directory.appendingPathComponent("History.sqlite"))
        try db.execute("BEGIN")
        let revision = try db.rows("SELECT value FROM settings WHERE key='revision'").first?.first ?? ""
        var clauses: [String] = [], values: [String] = []
        for (column, value) in [("project", filter.project), ("json_extract(info,'$.source')", filter.provider?.rawValue),
                                ("json_extract(info,'$.branch')", filter.branch)] {
            if let value { clauses.append(column + "=?"); values.append(value) }
        }
        if let cursor {
            // SQLite needs the scalar bound to seek into an expression index for the tuple comparison.
            clauses.append("-CAST(modified AS REAL) >= -CAST(? AS REAL) AND (-CAST(modified AS REAL),id) > (-CAST(? AS REAL),?)")
            values += [cursor.modified, cursor.modified, cursor.id]
        }
        let predicate = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let rows = try db.rows("SELECT info,modified,id FROM sessions" + predicate + " ORDER BY -CAST(modified AS REAL),id LIMIT ?",
                               values + [String(limit + 1)])
        try db.execute("COMMIT")
        let page = rows.prefix(limit)
        let decoder = JSONDecoder()
        let sessions = try page.map { try decoder.decode(CodingSession.self, from: Data($0[0].utf8)) }
        let next = rows.count > limit ? page.last.map { CodingSessionPage.Cursor(modified: $0[1], id: $0[2]) } : nil
        return .init(sessions: sessions, revision: revision, next: next)
    }
    public func sessions() throws -> [CodingSession] {
        try db.rows("SELECT info FROM sessions ORDER BY CAST(modified AS REAL) DESC,id").map {
            try JSONDecoder().decode(CodingSession.self, from: Data($0[0].utf8))
        }
    }
    public func history(id: String) throws -> CodingHistory {
        try Self.history(in: db, id: id)
    }
    public static func history(in directory: URL, id: String) throws -> CodingHistory {
        guard exists(in: directory) else { throw AgentFailure("Coding session unavailable.") }
        return try history(in: SearchDatabase(reading: directory.appendingPathComponent("History.sqlite")), id: id)
    }
    /// A selected legacy session can be opened before the background replay reaches it.
    /// Use the normal account and project grants, and read back the winning import transaction.
    public static func historyForDisplay(in directory: URL, id: String, readers: [any SessionReader]? = nil) throws -> CodingHistory {
        let saved = try history(in: directory, id: id)
        guard (saved.session.transcriptVersion ?? 0) < saved.session.currentTranscriptVersion,
              saved.messages.contains(where: { !$0.tools.isEmpty }),
              let provider = CodingProvider(rawValue: saved.session.source),
              let archive = try? CodingArchive(directory: directory) else { return saved }
        // Enrichment is best effort. A missing source still has a readable archived conversation.
        _ = try? archive.refresh(discoverProjects: false, provider: provider, readers: readers, onlySessionID: id)
        try Task.checkCancellation()
        return try archive.history(id: id)
    }

    private static func history(in db: SearchDatabase, id: String) throws -> CodingHistory {
        guard let row = try db.rows("SELECT history FROM sessions WHERE id=?", [id]).first else { throw AgentFailure("Coding session unavailable.") }
        return try JSONDecoder().decode(CodingHistory.self, from: Data(row[0].utf8))
    }
    func embeddingChunks() throws -> [SemanticChunk] {
        try db.rows("""
            SELECT session,message,CASE WHEN message='' THEN title ELSE body END,stamp,archived
            FROM coding_text WHERE message='' OR embed='1' ORDER BY rowid
            """).flatMap { row in
            SemanticChunker.split(row[2]).map {
                SemanticChunk(origin: .coding(session: row[0], message: row[1], timestamp: Double(row[3]).map(Date.init(timeIntervalSince1970:)), archived: row[4] == "1"), latest: true, text: $0)
            }
        }
    }

    /// Date bounds apply to activity inside a session, which can span several days.
    func browse(from: Date?, to: Date?, project: String?, branch: String?) throws -> [CodingHit] {
        let selected = try sessions().filter { (project == nil || project == $0.project) && (branch == nil || branch == $0.branch) }
        guard from != nil || to != nil else {
            return selected.map { CodingHit(session: $0, passages: []) }
        }
        var clauses = ["message != ''", "stamp != ''"], values: [String] = []
        if let from { clauses.append("CAST(stamp AS REAL) >= CAST(? AS REAL)"); values.append(String(from.timeIntervalSince1970)) }
        if let to { clauses.append("CAST(stamp AS REAL) < CAST(? AS REAL)"); values.append(String(to.timeIntervalSince1970)) }
        let active = Set(try db.rows("SELECT DISTINCT session FROM coding_text WHERE " + clauses.joined(separator: " AND "), values).map { $0[0] })
        // Read excerpts from the original messages. Search chunks can include context from a different day.
        return try selected.filter { active.contains($0.id) }.compactMap { session in
            let history = try history(id: session.id)
            let messages = history.messages.filter {
                guard let date = $0.timestamp, !$0.tools.isEmpty || $0.hasText else { return false }
                return (from.map { date >= $0 } ?? true) && (to.map { date < $0 } ?? true)
            }.sorted { $0.timestamp! > $1.timestamp! }
            guard let latest = messages.first else { return nil }
            let prose = messages.filter(\.hasText)
            let current = Set(history.conversationIDs)
            // Lead with the latest exchange and include the request that opened this period of work.
            let choices = [prose.first, prose.first { $0.role == "Assistant" }, prose.last { $0.role == "User" }]
            var seen = Set<String>()
            let passages = choices.compactMap { $0 }.filter { seen.insert($0.id).inserted }.map {
                CodingPassage(messageID: $0.id, text: String($0.searchText.prefix(450)), timestamp: $0.timestamp, archived: !current.contains($0.id))
            }
            return CodingHit(session: session, passages: passages, lastActivity: latest.timestamp,
                             toolOnlyMessageCount: messages.count - prose.count)
        }
    }

    func matches(query: String, semantic: [(SemanticChunk, Float)], from: Date?, to: Date?, project: String?, branch: String?, includeToolEvidence: Bool = true) throws -> [CodingHit] {
        let parsed = LibrarySearchQuery(query)
        guard let expression = parsed.expression else { return [] }
        let selected = try sessions().filter { (project == nil || project == $0.project) && (branch == nil || branch == $0.branch) }
        let sessions = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        func eligible(_ id: String, _ date: Date?) -> Bool {
            guard sessions[id] != nil else { return false }
            if let from, date.map({ $0 >= from }) != true { return false }
            if let to, date.map({ $0 < to }) != true { return false }
            return true
        }

        var matches: [String: CodingSessionMatches] = [:]
        var keywordCount = 0
        let prose = try db.rows("""
            SELECT session,message,stamp,archived,CASE WHEN message='' THEN title ELSE snippet(coding_text,7,'','','…',35) END,'',''
            FROM coding_text WHERE coding_text MATCH ? ORDER BY bm25(coding_text,0,0,0,0,4,1,1,1),rowid
            """, [expression])
        let tools = includeToolEvidence ? try db.rows("""
            SELECT session,message,stamp,archived,snippet(coding_tool_text,6,'','','…',35),position,event
            FROM coding_tool_text WHERE coding_tool_text MATCH ? ORDER BY bm25(coding_tool_text),rowid
            """, [expression]) : []
        // Interleave the two ranked lists. BM25 scores from separate corpora aren't comparable.
        func record(_ row: [String]) {
            let id = row[0], date = Double(row[2]).map(Date.init(timeIntervalSince1970:))
            guard eligible(id, date) else { return }
            if matches[id]?.keywordRank == nil {
                matches[id, default: .init()].keywordRank = keywordCount
                keywordCount += 1
            }
            if row[1].isEmpty {
                matches[id]?.titleMatch = parsed.matches(row[4], allowPrefixes: false)
            } else {
                let passage = CodingPassage(messageID: row[1], text: String(row[4].prefix(450)), timestamp: date, archived: row[3] == "1", toolIndex: Int(row[5]), eventIndex: Int(row[6]))
                matches[id]?.addKeyword(passage)
            }
        }

        for rank in 0..<max(prose.count, tools.count) {
            if tools.indices.contains(rank) { record(tools[rank]) }
            if prose.indices.contains(rank) { record(prose[rank]) }
        }

        for (chunk, weight) in semantic {
            guard case let .coding(id, message, date, archived) = chunk.origin, eligible(id, date),
                  message.isEmpty || matches[id]?.canAddSemantic(message) != false,
                  parsed.matchesQuotes(chunk.text) else { continue }
            if message.isEmpty {
                matches[id, default: .init()].titleWeight = max(weight, matches[id]?.titleWeight ?? 0)
            } else {
                let passage = CodingPassage(messageID: message, text: String(chunk.text.prefix(450)), timestamp: date, archived: archived)
                matches[id, default: .init()].addSemantic(passage, weight: weight)
            }
        }
        let semanticOrder = matches.filter { $0.value.semanticWeight != nil }.sorted { a, b in
            let left = a.value.semanticWeight ?? 0, right = b.value.semanticWeight ?? 0
            return left == right ? a.key < b.key : left > right
        }
        for (rank, entry) in semanticOrder.prefix(80).enumerated() { matches[entry.key]?.semanticRank = rank }
        return matches.filter { $0.value.keywordRank != nil || $0.value.semanticRank != nil }.sorted { a, b in
            if a.value.titleMatch != b.value.titleMatch { return a.value.titleMatch }
            if a.value.score != b.value.score { return a.value.score > b.value.score }
            return a.key < b.key
        }.map { id, match in CodingHit(session: sessions[id]!, passages: match.passages) }
    }
}

// Fuse the best evidence from each channel once per session. Repeating the same topic
// over many messages cannot increase a session's score or consume more result slots.
private struct CodingSessionMatches {
    var keywordRank: Int?
    var semanticRank: Int?
    var titleMatch = false
    var titleWeight: Float?
    private var passageWeight: Float?
    private var keywords: [CodingPassage] = []
    private var concepts: [CodingPassage] = []
    private static let excerptLimit = 3

    mutating func addKeyword(_ passage: CodingPassage) {
        if keywords.count < Self.excerptLimit && !keywords.contains(where: { $0.sameAnchor(as: passage) }) {
            keywords.append(passage)
        }
    }
    func canAddSemantic(_ id: String) -> Bool {
        concepts.count < Self.excerptLimit && !concepts.contains { $0.messageID == id }
    }
    mutating func addSemantic(_ passage: CodingPassage, weight: Float) {
        passageWeight = max(passageWeight ?? 0, weight)
        concepts.append(passage)
    }
    var semanticWeight: Float? {
        guard titleWeight != nil || passageWeight != nil else { return nil }
        return (titleWeight ?? 0) + (passageWeight ?? 0)
    }

    private static func score(keyword: Int?, semantic: Int?) -> Double {
        (keyword.map { 1.3 / Double(61 + $0) } ?? 0) + (semantic.map { 1 / Double(61 + $0) } ?? 0)
    }
    var score: Double { Self.score(keyword: keywordRank, semantic: semanticRank) }
    var passages: [CodingPassage] {
        let semantic = semanticRank == nil ? [] : concepts
        let unique = keywords + semantic.filter { concept in !keywords.contains { $0.sameAnchor(as: concept) } }
        func rank(_ passage: CodingPassage) -> Double {
            Self.score(keyword: keywords.firstIndex { $0.sameAnchor(as: passage) },
                       semantic: semantic.firstIndex { $0.sameAnchor(as: passage) })
        }
        return Array(unique.sorted { rank($0) > rank($1) }.prefix(Self.excerptLimit))
    }
}
