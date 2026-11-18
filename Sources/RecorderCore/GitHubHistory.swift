import Foundation

public struct GitHubIdentity: Codable, Equatable, Sendable {
    public let id, login: String
    public init(id: String, login: String) {
        self.id = id
        self.login = login
    }
}

public struct GitHubRepository: Codable, Identifiable, Equatable, Sendable {
    public let id, name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum GitHubActionKind: String, Codable, CaseIterable, Sendable {
    case opened, comment, review, inline
    public var label: String {
        switch self {
        case .opened: return "Opened"
        case .comment: return "Commented"
        case .review: return "Reviewed"
        case .inline: return "Inline comment"
        }
    }
}

public struct GitHubItem: Codable, Identifiable, Equatable, Sendable {
    public let id, repositoryID, type, title, author, state, url: String
    public let number: Int
}

public struct GitHubPassage: Codable, Identifiable, Equatable, Sendable {
    public let id, actorID, text, url: String
    public let kind: GitHubActionKind
    public let date: Date
    public let edited: Date?
    public let verdict, path: String?
    public let line: Int?
    func excerpt(_ value: String, limit: Int = 450) -> Self {
        .init(
            id: id, actorID: actorID, text: String(value.prefix(limit)), url: url, kind: kind, date: date,
            edited: edited, verdict: verdict, path: path, line: line)
    }
    func embeddingContext(title: String) -> String {
        [String(title.prefix(256)), kind.label, verdict, path].compactMap { $0 }.joined(separator: "\n") + "\n\n"
    }
}

public struct GitHubHit: Identifiable, Sendable {
    public let item: GitHubItem
    public let repository: String
    public let citations: [GitHubPassage]
    public let date: Date
    public let verified: Date?
    public var id: String { item.id }
}

public struct GitHubSelection: Identifiable, Sendable {
    public let repo: GitHubRepository
    public let epoch: String
    public let allHistory, shared, paused: Bool
    public let lastSuccess, checked, lastReplay: Date?
    public let status: String
    public let queued: Int
    public var id: String { repo.id }
}

// A queued page contains only opaque node IDs, cursors and time bounds. Its replacement
// and all contributions from that page commit together.
public enum GitHubJob: Codable, Equatable, Sendable {
    case search(qualifier: String, since: Int, until: Int, cutoff: Int, cursor: String?)
    case comments(since: Int, cursor: String?)
    case reviews(item: String, since: Int, cursor: String?)
    case threads(item: String, since: Int, cursor: String?)
    case thread(id: String, since: Int, cursor: String)
    case nodes(ids: [String], since: Int)
}

public struct GitHubPage {
    public var entries: [(GitHubItem, GitHubPassage)] = []
    public var missing: [String] = []
    public var next: [GitHubJob] = []
    public var partial = false
    public init() {}
}

public struct GitHubWork {
    public let key: String
    public let job: GitHubJob
}

public struct GitHubReference: Equatable {
    public let repository: String?
    public let number: Int
    private static let exact = try! NSRegularExpression(
        pattern: #"^(?:https://github\.com/([\w.-]+/[\w.-]+)/(?:issues|pull)/([0-9]+)(?:[/#?].*)?|(?:([\w.-]+/[\w.-]+))?#([0-9]+))$"#,
        options: .caseInsensitive)
    public init?(_ input: String) {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard let m = Self.exact.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length)) else { return nil }
        func part(_ index: Int) -> String? { m.range(at: index).location == NSNotFound ? nil : s.substring(with: m.range(at: index)) }
        guard let number = Int(part(2) ?? part(4) ?? ""), number > 0 else { return nil }
        self.number = number
        repository = part(1) ?? part(3)
    }
}

public final class GitHubArchive {
    public static let directory = AgentAccessStore.directory.deletingLastPathComponent().appendingPathComponent("GitHub")
    public static func exists(in directory: URL) -> Bool { PrivateFiles.isRegular(directory.appendingPathComponent("History.sqlite")) }
    let db: SearchDatabase
    public init(directory: URL = directory) throws {
        try PrivateFiles.directory(directory)
        db = try SearchDatabase(url: directory.appendingPathComponent("History.sqlite"), durable: true)
        try db.execute("PRAGMA foreign_keys=ON")
        try db.execute("PRAGMA secure_delete=ON")
        try db.execute(
            "CREATE TABLE IF NOT EXISTS account (slot INTEGER PRIMARY KEY CHECK(slot=1), id TEXT NOT NULL, login TEXT NOT NULL, locked INTEGER NOT NULL DEFAULT 0)"
        )
        try db.execute(
            "CREATE TABLE IF NOT EXISTS throttle (account INTEGER PRIMARY KEY REFERENCES account(slot) ON DELETE CASCADE, until REAL NOT NULL)"
        )
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS repos (id TEXT PRIMARY KEY, name TEXT NOT NULL, epoch TEXT NOT NULL, revision TEXT NOT NULL,
            all_history INTEGER DEFAULT 0, shared INTEGER DEFAULT 0, paused INTEGER DEFAULT 0, success REAL, checked REAL, replay REAL,
            started REAL, replaying INTEGER DEFAULT 0, partial INTEGER DEFAULT 0, status TEXT DEFAULT 'Queued')
            """)
        try db.execute(
            "CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, repo TEXT NOT NULL REFERENCES repos(id) ON DELETE CASCADE, number INTEGER NOT NULL, type TEXT NOT NULL, json TEXT NOT NULL)"
        )
        try db.execute("CREATE INDEX IF NOT EXISTS repo_number ON items(repo,number)")
        try db.execute(
            "CREATE TABLE IF NOT EXISTS actions (id TEXT PRIMARY KEY, item TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE, kind TEXT NOT NULL, date REAL NOT NULL, json TEXT NOT NULL)"
        )
        try db.execute("CREATE INDEX IF NOT EXISTS item_actions ON actions(item,date)")
        try db.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS github_text USING fts5(id UNINDEXED,title,body,details, tokenize=\"unicode61 remove_diacritics 2 tokenchars '_'\")"
        )
        try db.execute(
            "CREATE TRIGGER IF NOT EXISTS drop_action AFTER DELETE ON actions BEGIN DELETE FROM github_text WHERE rowid=old.rowid; END"
        )
        try db.execute(
            "CREATE TABLE IF NOT EXISTS jobs (seq INTEGER PRIMARY KEY, repo TEXT NOT NULL REFERENCES repos(id) ON DELETE CASCADE, job TEXT NOT NULL, UNIQUE(repo,job))"
        )
    }
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    static func date(_ value: String) -> Date? { Double(value).map(Date.init(timeIntervalSince1970:)) }
    public var account: GitHubIdentity? {
        get throws { try db.rows("SELECT id,login FROM account").first.map { .init(id: $0[0], login: $0[1]) } }
    }
    public var locked: Bool { get throws { try db.rows("SELECT locked FROM account").first?.first == "1" } }
    public var retryAfter: Date? { get throws { try db.rows("SELECT until FROM throttle").first.flatMap { Self.date($0[0]) } } }
    public func deferRequests(until date: Date) throws {
        try db.execute("INSERT OR REPLACE INTO throttle(account,until) VALUES(1,?)", [String(date.timeIntervalSince1970)])
    }
    public func connect(_ identity: GitHubIdentity, verified: [GitHubRepository]? = nil, now: Date = Date()) throws {
        try db.transaction {
            if let current = try account, current.id != identity.id {
                throw AgentFailure("Reconnect the original GitHub account or disconnect and remove its history first.")
            }
            try db.execute(
                "INSERT INTO account(slot,id,login) VALUES(1,?,?) ON CONFLICT(slot) DO UPDATE SET login=excluded.login,locked=0",
                [identity.id, identity.login])
            if let verified { try applyAccess(verified, now: now) }
        }
    }
    public func lock() throws {
        try db.transaction {
            try db.execute("UPDATE account SET locked=1")
            try db.execute("UPDATE repos SET shared=0, revision=lower(hex(randomblob(16))), epoch=lower(hex(randomblob(16)))")
        }
    }
    public func disconnect() throws {
        try db.transaction {
            try db.execute("DELETE FROM repos")
            try db.execute("DELETE FROM account")
        }
    }
    public func selections() throws -> [GitHubSelection] {
        try db.rows(
            "SELECT id,name,epoch,all_history,shared,paused,success,checked,replay,status,(SELECT COUNT(*) FROM jobs WHERE repo=r.id) FROM repos r ORDER BY name COLLATE NOCASE"
        ).map {
            .init(
                repo: .init(id: $0[0], name: $0[1]), epoch: $0[2], allHistory: $0[3] == "1", shared: $0[4] == "1",
                paused: $0[5] == "1",
                lastSuccess: Self.date($0[6]), checked: Self.date($0[7]), lastReplay: Self.date($0[8]), status: $0[9],
                queued: Int($0[10]) ?? 0)
        }
    }
    public func select(_ repo: GitHubRepository, allHistory: Bool = false) throws {
        guard try account != nil, try !locked else { throw AgentFailure("Connect GitHub first.") }
        try db.execute(
            "INSERT OR IGNORE INTO repos(id,name,epoch,revision,all_history) VALUES(?,?,?,?,?)",
            [repo.id, repo.name, UUID().uuidString, UUID().uuidString, allHistory ? "1" : "0"])
    }
    public func remove(_ id: String) throws { try db.execute("DELETE FROM repos WHERE id=?", [id]) }
    public func share(_ id: String, enabled: Bool) throws {
        try db.execute(
            "UPDATE repos SET shared=?,revision=? WHERE id=? AND EXISTS(SELECT 1 FROM account WHERE locked=0)",
            [enabled ? "1" : "0", UUID().uuidString, id])
    }
    public func pause(_ id: String, enabled: Bool) throws {
        try db.execute("UPDATE repos SET paused=?,epoch=? WHERE id=?", [enabled ? "1" : "0", UUID().uuidString, id])
    }
    public func setDepth(_ id: String, all: Bool) throws {
        try db.transaction {
            try db.execute("DELETE FROM jobs WHERE repo=?", [id])
            try db.execute(
                "UPDATE repos SET all_history=?,epoch=?,started=NULL,replay=NULL,success=NULL,status='Queued' WHERE id=?",
                [all ? "1" : "0", UUID().uuidString, id])
        }
    }
    public func verifyAccess(_ repos: [GitHubRepository], identity: GitHubIdentity, now: Date) throws {
        try db.transaction {
            guard try account?.id == identity.id, try !locked else { throw AgentFailure("GitHub account changed during sync.") }
            try db.execute("UPDATE account SET login=? WHERE id=? AND login<>?", [identity.login, identity.id, identity.login])
            try applyAccess(repos, now: now)
        }
    }
    private func applyAccess(_ repos: [GitHubRepository], now: Date) throws {
        let available = Dictionary(repos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for saved in try selections() {
            if let repo = available[saved.id] {
                try db.execute(
                    "UPDATE repos SET name=?,checked=?,revision=CASE WHEN name<>? THEN ? ELSE revision END WHERE id=?",
                    [repo.name, String(now.timeIntervalSince1970), repo.name, UUID().uuidString, repo.id])
            } else {
                try remove(saved.id)
            }
        }
    }
    public func status(_ text: String, for repo: GitHubSelection) throws {
        try db.execute("UPDATE repos SET status=? WHERE id=? AND epoch=?", [text, repo.id, repo.epoch])
    }
    private func requireCurrent(_ repo: GitHubSelection) throws -> String {
        guard
            let id = try db.rows(
                "SELECT account.id FROM account,repos WHERE locked=0 AND paused=0 AND repos.id=? AND epoch=?", [repo.id, repo.epoch]
            ).first?.first
        else {
            throw AgentFailure("GitHub import selection changed.")
        }
        return id
    }
    private func enqueue(_ jobs: [GitHubJob], repo: String) throws {
        for job in jobs { try db.execute("INSERT OR IGNORE INTO jobs(repo,job) VALUES(?,?)", [repo, try Self.encode(job)]) }
    }
    public func begin(_ repo: GitHubSelection, now: Date) throws {
        try db.transaction {
            _ = try requireCurrent(repo)
            guard try db.rows("SELECT started FROM repos WHERE id=?", [repo.id]).first?.first == "" else { return }
            let replay = repo.lastReplay.map { now.timeIntervalSince($0) >= 7 * 86400 } ?? true
            let floor = repo.allHistory ? 0 : Int(now.timeIntervalSince1970) - 90 * 86400
            let since = replay ? floor : max(floor, Int(repo.lastSuccess?.timeIntervalSince1970 ?? 0) - 2 * 86400)
            let until = Int(now.timeIntervalSince1970)
            try db.execute(
                "UPDATE repos SET started=?,replaying=?,partial=0,status='Syncing' WHERE id=?",
                [String(until), replay ? "1" : "0", repo.id])
            try enqueue(
                ["is:issue author:@me", "is:pr author:@me", "is:pr reviewed-by:@me", "is:pr commenter:@me"].map {
                    .search(qualifier: $0, since: since, until: until, cutoff: floor, cursor: nil)
                } + [.comments(since: since, cursor: nil)], repo: repo.id)
            if replay {
                let ids = try db.rows("SELECT a.id FROM actions a JOIN items i ON i.id=a.item WHERE i.repo=? ORDER BY a.id", [repo.id])
                    .map { $0[0] }
                for i in stride(from: 0, to: ids.count, by: 30) {
                    try enqueue([.nodes(ids: Array(ids[i..<min(i + 30, ids.count)]), since: 0)], repo: repo.id)
                }
            }
        }
    }
    public func next(_ repo: GitHubSelection) throws -> GitHubWork? {
        try db.rows("SELECT seq,job FROM jobs WHERE repo=? ORDER BY seq LIMIT 1", [repo.id]).first.map {
            try .init(key: $0[0], job: Self.decode(GitHubJob.self, $0[1]))
        }
    }
    public func commit(_ page: GitHubPage, work: GitHubWork, repo: GitHubSelection) throws {
        try db.transaction {
            let actor = try requireCurrent(repo)
            guard
                try db.rows("SELECT job FROM jobs WHERE repo=? AND seq=?", [repo.id, work.key]).first?.first == Self.encode(work.job)
            else { throw AgentFailure("This GitHub page was already processed.") }
            var changed = false
            for (item, action) in page.entries where action.actorID == actor && item.repositoryID == repo.id {
                if try save(item, action) { changed = true }
            }
            for id in page.missing {
                if try !db.rows("SELECT 1 FROM actions a JOIN items i ON i.id=a.item WHERE a.id=? AND i.repo=?", [id, repo.id]).isEmpty
                {
                    changed = true
                }
                try db.execute("DELETE FROM actions WHERE id=? AND item IN (SELECT id FROM items WHERE repo=?)", [id, repo.id])
            }
            try db.execute("DELETE FROM items WHERE repo=? AND NOT EXISTS(SELECT 1 FROM actions WHERE item=items.id)", [repo.id])
            try enqueue(page.next, repo: repo.id)
            try db.execute("DELETE FROM jobs WHERE repo=? AND seq=?", [repo.id, work.key])
            if changed { try db.execute("UPDATE repos SET revision=? WHERE id=?", [UUID().uuidString, repo.id]) }
            if page.partial { try db.execute("UPDATE repos SET partial=1 WHERE id=?", [repo.id]) }
            if try next(repo) == nil {
                try db.execute(
                    """
                    UPDATE repos SET success=CASE WHEN partial=0 THEN started ELSE success END,
                    replay=CASE WHEN partial=0 AND replaying=1 THEN started ELSE replay END,started=NULL,
                    status=CASE WHEN partial=1 THEN 'Partial · GitHub search limit' ELSE 'Up to date' END WHERE id=?
                    """, [repo.id])
            }
        }
    }
    private func save(_ item: GitHubItem, _ action: GitHubPassage) throws -> Bool {
        let saved = try db.rows("SELECT json,repo FROM items WHERE id=?", [item.id]).first
        if let saved, saved[1] != item.repositoryID {
            try db.execute("DELETE FROM items WHERE id=?", [item.id])
            try db.execute("UPDATE repos SET revision=? WHERE id=?", [UUID().uuidString, saved[1]])
        }
        let old = saved?.first
        let header = try Self.encode(item)
        if header != old {
            try db.execute(
                "INSERT INTO items VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET repo=excluded.repo,number=excluded.number,type=excluded.type,json=excluded.json",
                [item.id, item.repositoryID, String(item.number), item.type, header])
            try db.execute(
                "UPDATE github_text SET title=? WHERE rowid IN (SELECT rowid FROM actions WHERE item=?)", [item.title, item.id])
        }
        let json = try Self.encode(action)
        if try db.rows("SELECT json FROM actions WHERE id=? AND item=?", [action.id, item.id]).first?.first == json {
            return header != old
        }
        try db.execute(
            "INSERT INTO actions VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET item=excluded.item,kind=excluded.kind,date=excluded.date,json=excluded.json",
            [action.id, item.id, action.kind.rawValue, String(action.date.timeIntervalSince1970), json])
        let row = try db.rows("SELECT rowid FROM actions WHERE id=?", [action.id])[0][0]
        try db.execute("DELETE FROM github_text WHERE rowid=?", [row])
        try db.execute(
            "INSERT INTO github_text(rowid,id,title,body,details) VALUES(?,?,?,?,?)",
            [
                row, action.id, item.title, action.text,
                [action.kind.label, action.verdict, action.path].compactMap { $0 }.joined(separator: " "),
            ])
        return true
    }
    func scope(_ shared: Bool) -> String { "account.locked=0" + (shared ? " AND r.shared=1" : "") }
    public func revision(shared: Bool) throws -> String {
        let rows = try db.rows("SELECT r.id,r.revision FROM repos r,account WHERE \(scope(shared)) ORDER BY r.id")
        return rows.isEmpty ? "" : AgentJSON.hash(try AgentJSON.data(rows))
    }
    public func timeline(_ id: String, shared: Bool) throws -> [GitHubPassage] {
        try db.rows(
            "SELECT a.json FROM actions a JOIN items i ON i.id=a.item JOIN repos r ON r.id=i.repo,account WHERE \(scope(shared)) AND i.id=? ORDER BY a.date,a.id",
            [id]
        ).map { try Self.decode(GitHubPassage.self, $0[0]) }
    }
    public func search(
        _ query: String = "", shared: Bool, repository: String? = nil, type: String? = nil, action: String? = nil, from: Date? = nil,
        to: Date? = nil, itemID: String? = nil, passageID: String? = nil
    ) throws -> [GitHubHit] {
        var conditions = [scope(shared)]
        var bindings: [String] = []
        func add(_ expression: String, _ value: String?) {
            if let value {
                conditions.append(expression)
                bindings.append(value)
            }
        }
        add("r.name=? COLLATE NOCASE", repository)
        add("i.type=?", type)
        add("a.kind=?", action)
        add("i.id=?", itemID)
        add("a.id=?", passageID)
        add("a.date>=?", from.map { String($0.timeIntervalSince1970) })
        add("a.date<?", to.map { String($0.timeIntervalSince1970) })
        var rank = "0"
        var citation = "json_extract(a.json,'$.text')"
        var fts = ""
        if let ref = GitHubReference(query) {
            guard ref.repository != nil || repository != nil else { return [] }
            add("r.name=? COLLATE NOCASE", ref.repository)
            add("i.number=?", String(ref.number))
        } else if !LibrarySearchQuery(query).isEmpty {
            guard let expression = LibrarySearchQuery(query).expression else { return [] }
            fts = " JOIN github_text ON github_text.rowid=a.rowid"
            add("github_text MATCH ?", expression)
            rank =
                "CASE WHEN highlight(github_text,2,char(1),char(2))<>body OR highlight(github_text,3,char(1),char(2))<>details THEN 1 ELSE 0 END"
            citation = "snippet(github_text,2,'','','…',40)"
        }
        // Use scoped passage evidence for ranking. Corpus-wide FTS statistics would
        // let an unshared repository influence the order of shared results.
        let sql = """
            WITH matches AS MATERIALIZED (
                SELECT a.id AS aid,a.item AS parent,a.date AS stamp,\(rank) AS strength,substr(\(citation),1,900) AS excerpt
                FROM actions a JOIN items i ON i.id=a.item JOIN repos r ON r.id=i.repo \(fts),account
                WHERE \(conditions.joined(separator:" AND "))
            ), ranked AS (
                SELECT *,row_number() OVER(PARTITION BY parent ORDER BY strength DESC,stamp DESC,aid) AS position FROM matches
            )
            SELECT i.json,r.name,json_set(a.json,'$.text',ranked.excerpt),r.checked FROM ranked
            JOIN actions a ON a.id=ranked.aid JOIN items i ON i.id=ranked.parent JOIN repos r ON r.id=i.repo
            WHERE ranked.position<=3 ORDER BY ranked.strength DESC,ranked.stamp DESC,ranked.aid
            """
        var order: [String] = []
        var hits: [String: GitHubHit] = [:]
        for row in try db.rows(sql, bindings) {
            let item = try Self.decode(GitHubItem.self, row[0])
            let previous = hits[item.id]
            if let previous, previous.citations.count >= 3 { continue }
            let passage = try Self.decode(GitHubPassage.self, row[2])
            let snippet = passage.excerpt(passage.text)
            if previous == nil { order.append(item.id) }
            hits[item.id] = .init(
                item: item, repository: row[1], citations: (previous?.citations ?? []) + [snippet],
                date: max(previous?.date ?? passage.date, passage.date), verified: Self.date(row[3]))
        }
        return order.compactMap { hits[$0] }
    }
}

extension GitHubArchive {
    func embeddingChunks(shared: Bool) throws -> [SemanticChunk] {
        try db.rows(
            "SELECT r.revision,i.json,a.json FROM actions a JOIN items i ON i.id=a.item JOIN repos r ON r.id=i.repo,account WHERE \(scope(shared)) ORDER BY i.id,a.id"
        ).flatMap { row in
            let header = try Self.decode(GitHubItem.self, row[1])
            let passage = try Self.decode(GitHubPassage.self, row[2])
            let context = passage.embeddingContext(title: header.title)
            let parts = SemanticChunker.split(passage.text)
            return (parts.isEmpty ? [""] : parts).map {
                SemanticChunk(
                    origin: .github(item: header.id, passage: passage.id, revision: row[0]), latest: true, text: context + $0)
            }
        }
    }
    func merge(
        _ query: String, keywords: [GitHubHit], chunks: [(SemanticChunk, Float)], shared: Bool, repository: String?, type: String?,
        action: String?, from: Date?, to: Date?
    ) throws -> [GitHubHit] {
        var byID = Dictionary(uniqueKeysWithValues: keywords.map { ($0.id, $0) })
        var scores = Dictionary(uniqueKeysWithValues: keywords.enumerated().map { ($0.element.id, 1.0 / Double(61 + $0.offset)) })
        var visited = Set<String>()
        var ranked = Set<String>()
        let parsed = LibrarySearchQuery(query)
        for (chunk, _) in chunks {
            guard case .github(let item, let passage, let revision) = chunk.origin, parsed.matchesQuotes(chunk.text),
                visited.insert(passage).inserted,
                byID[item]?.citations.contains(where: { $0.id == passage }) != true || !ranked.contains(item),
                let hit = try search(
                    shared: shared, repository: repository, type: type, action: action, from: from, to: to, itemID: item,
                    passageID: passage
                ).first, let citation = hit.citations.first
            else { continue }
            let context = citation.embeddingContext(title: hit.item.title)
            guard chunk.text.hasPrefix(context) else { continue }
            let excerpt = String(chunk.text.dropFirst(context.count))
            // An edit or permission change can land between vector lookup and citation lookup.
            guard try db.rows("SELECT revision FROM repos WHERE id=?", [hit.item.repositoryID]).first?.first == revision else {
                continue
            }
            let candidate = GitHubHit(
                item: hit.item, repository: hit.repository,
                citations: [citation.excerpt(excerpt, limit: 900)],
                date: hit.date, verified: hit.verified)
            if ranked.insert(item).inserted { scores[item, default: 0] += 1.0 / Double(60 + ranked.count) }
            if let existing = byID[item] {
                if existing.citations.count < 3 && !existing.citations.contains(where: { $0.id == passage }) {
                    byID[item] = .init(
                        item: existing.item, repository: existing.repository, citations: existing.citations + candidate.citations,
                        date: existing.date, verified: existing.verified)
                }
            } else {
                byID[item] = candidate
            }
            if ranked.count >= 80 { break }
        }
        return byID.values.sorted { a, b in
            let l = scores[a.id] ?? 0
            let r = scores[b.id] ?? 0
            return l == r ? a.id < b.id : l > r
        }
    }
}

extension GitHubReference {
    private static let inText = try! NSRegularExpression(
        pattern: #"(?<![\w/.@-])(?:https://github\.com/[\w.-]+/[\w.-]+/(?:pull|issues)/[0-9]+|[\w.-]+/[\w.-]+#[0-9]+)(?![\w-])"#,
        options: .caseInsensitive)
    public static func qualified(in text: String) -> [String] {
        let s = text as NSString
        var seen = Set<String>()
        return inText.matches(in: text, range: NSRange(location: 0, length: s.length)).compactMap { match in
            guard let ref = GitHubReference(s.substring(with: match.range)), let repo = ref.repository else { return nil }
            let key = repo.lowercased() + "#" + String(ref.number)
            return seen.insert(key).inserted ? key : nil
        }
    }
}
