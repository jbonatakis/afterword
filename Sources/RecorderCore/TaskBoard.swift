import Foundation
import Darwin

public struct BoardGroup: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
}

public enum BoardAxis: String, Codable, Sendable { case column, swimlane }

public struct BoardReference: Codable, Equatable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable { case call, coding, github }
    public internal(set) var id: String? = UUID().uuidString
    public var source: Source
    public var itemID: String
    public var anchor: String?
    public var label: String
    public var versionID: String?
    public var quote: String?

    enum CodingKeys: String, CodingKey { case id = "reference_id", source, itemID = "item_id", anchor, label, quote, versionID = "version_id" }
    public init(source: Source, itemID: String, anchor: String? = nil, label: String, quote: String? = nil, versionID: String? = nil) {
        self.source = source
        self.itemID = itemID
        self.anchor = anchor
        self.label = label
        self.quote = quote
        self.versionID = versionID
    }
}

public struct BoardTicket: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var notes: String
    public var columnID: String
    public var swimlaneID: String?
    public var references: [BoardReference]
    public fileprivate(set) var originKey: String?

    enum CodingKeys: String, CodingKey {
        case id, title, notes, references, columnID = "column_id", swimlaneID = "swimlane_id", originKey = "origin_key"
    }
    public init(title: String, notes: String = "", columnID: String, swimlaneID: String? = nil,
                references: [BoardReference] = [], originKey: String? = nil) {
        self.id = UUID().uuidString
        self.title = title
        self.notes = notes
        self.columnID = columnID
        self.swimlaneID = swimlaneID
        self.references = references
        self.originKey = originKey
    }
}

public enum BoardTicketField: String, CaseIterable, Sendable {
    case title = "Title", notes = "Notes", column = "Column", swimlane = "Swimlane"

    public func copy(from source: BoardTicket, to target: inout BoardTicket) {
        switch self {
        case .title: target.title = source.title
        case .notes: target.notes = source.notes
        case .column: target.columnID = source.columnID
        case .swimlane: target.swimlaneID = source.swimlaneID
        }
    }

    public func value(in ticket: BoardTicket) -> String? {
        switch self {
        case .title: return ticket.title
        case .notes: return ticket.notes
        case .column: return ticket.columnID
        case .swimlane: return ticket.swimlaneID
        }
    }
}

public struct BoardTicketConflict: Error, Sendable {
    public let latest: BoardTicket
    public let draft: BoardTicket
    public let fields: [BoardTicketField]
}

public struct TaskBoard: Codable, Equatable, Sendable {
    public fileprivate(set) var revision = 0
    public private(set) var name = "Task board"

    public mutating func rename(_ value: String) throws {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(name.count) else { throw AgentFailure("Use a board name between 1 and 120 characters.") }
        self.name = name
    }
    public private(set) var columns = [BoardGroup(id: "todo", name: "To do"),
                                       BoardGroup(id: "in-progress", name: "In progress"),
                                       BoardGroup(id: "done", name: "Done")]
    public private(set) var swimlanes: [BoardGroup] = []
    public private(set) var tickets: [BoardTicket] = []

    /// The MCP token is computed from this copy. The writer counter and legacy
    /// free-form origin keys (which could contain raw source IDs) stay local.
    func projecting(_ resolve: (BoardReference) -> BoardReference?) -> TaskBoard {
        var visible = self
        visible.revision = 0
        for i in visible.tickets.indices {
            visible.tickets[i].references = tickets[i].references.compactMap(resolve)
            if let key = tickets[i].originKey, UUID(uuidString: key) == nil { visible.tickets[i].originKey = nil }
        }
        return visible
    }

    fileprivate var needsReferenceIDs: Bool { tickets.contains { $0.references.contains { $0.id == nil } } }

    fileprivate mutating func assignMissingReferenceIDs() {
        for i in tickets.indices {
            for j in tickets[i].references.indices where tickets[i].references[j].id == nil {
                tickets[i].references[j].id = UUID().uuidString
            }
        }
    }

    public func groups(_ axis: BoardAxis) -> [BoardGroup] { axis == .column ? columns : swimlanes }

    @discardableResult
    public mutating func saveGroup(_ axis: BoardAxis, id: String? = nil, name: String, position: Int? = nil) throws -> String {
        var groups = groups(axis)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(name.count) else { throw AgentFailure("Use a group name between 1 and 120 characters.") }
        var index = groups.endIndex
        if let id {
            guard let current = groups.firstIndex(where: { $0.id == id }) else { throw AgentFailure("Group no longer exists.") }
            index = current
            groups.remove(at: current)
        }
        guard groups.count < 100 else { throw AgentFailure("Each axis supports up to 100 groups.") }
        let target = position ?? index
        guard (0...groups.count).contains(target) else { throw AgentFailure("Group position is out of range.") }
        let group = BoardGroup(id: id ?? UUID().uuidString, name: name)
        groups.insert(group, at: target)
        if axis == .column { columns = groups } else { swimlanes = groups }
        return group.id
    }

    public mutating func deleteGroup(_ axis: BoardAxis, id: String) throws {
        guard groups(axis).contains(where: { $0.id == id }) else { throw AgentFailure("Group no longer exists.") }
        guard !tickets.contains(where: { (axis == .column ? $0.columnID : $0.swimlaneID) == id }) else {
            throw AgentFailure("Move tickets out of this group before deleting it.")
        }
        if axis == .column {
            guard columns.count > 1 else { throw AgentFailure("Keep at least one column on the board.") }
            columns.removeAll { $0.id == id }
        } else { swimlanes.removeAll { $0.id == id } }
    }

    public func ticket(_ id: String) throws -> BoardTicket {
        guard let ticket = tickets.first(where: { $0.id == id }) else { throw AgentFailure("Ticket no longer exists.") }
        return ticket
    }

    @discardableResult
    public mutating func saveTicket(_ draft: BoardTicket, position: Int? = nil) throws -> String {
        var ticket = draft
        var seen: Set<String> = []
        for i in ticket.references.indices {
            if let id = ticket.references[i].id, seen.insert(id).inserted { continue }
            let id = UUID().uuidString
            ticket.references[i].id = id
            seen.insert(id)
        }
        ticket.title = ticket.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...240).contains(ticket.title.count), ticket.notes.count <= 8192 else {
            throw AgentFailure("Use a title of 1–240 characters and notes of up to 8,192 characters.")
        }
        guard ticket.references.allSatisfy({
            !$0.itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.itemID.count <= 512 &&
            !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.count <= 240 &&
            ($0.anchor?.count ?? 0) <= 512 && ($0.quote?.count ?? 0) <= 1500 && ($0.versionID?.count ?? 0) <= 512
        }) else { throw AgentFailure("Supply source references with an item ID and a short label.") }
        if let key = ticket.originKey {
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.count <= 512 else { throw AgentFailure("Invalid origin key.") }
            if let existing = tickets.first(where: { $0.originKey == key && $0.id != ticket.id }) { return existing.id }
        }
        guard columns.contains(where: { $0.id == ticket.columnID }),
              ticket.swimlaneID.map({ id in swimlanes.contains { $0.id == id } }) ?? true else {
            throw AgentFailure("The destination column or swimlane no longer exists.")
        }
        let inCell: (BoardTicket) -> Bool = { $0.columnID == draft.columnID && $0.swimlaneID == draft.swimlaneID }
        let peers = tickets.filter(inCell)
        let previous = peers.firstIndex { $0.id == ticket.id }
        let remaining = peers.filter { $0.id != ticket.id }
        let offset = position ?? previous ?? remaining.count
        guard (0...remaining.count).contains(offset) else { throw AgentFailure("Ticket position is out of range.") }
        if previous == offset, let index = tickets.firstIndex(where: { $0.id == ticket.id }) {
            tickets[index] = ticket
            return ticket.id
        }
        tickets.removeAll { $0.id == ticket.id }
        if offset < remaining.count, let index = tickets.firstIndex(where: { $0.id == remaining[offset].id }) {
            tickets.insert(ticket, at: index)
        } else { tickets.append(ticket) }
        return ticket.id
    }

    public mutating func deleteTicket(_ id: String) throws {
        _ = try ticket(id)
        tickets.removeAll { $0.id == id }
    }
}

/// Both the app and stdio helpers may edit while the other process is running.
/// Readers see an entire snapshot. Writers check its revision under an interprocess lock.
public struct TaskBoardStore: Sendable {
    public let stateDirectory: URL
    public init(stateDirectory: URL = AgentAccessStore.directory) { self.stateDirectory = stateDirectory }
    private var directory: URL { stateDirectory.appendingPathComponent("Board", isDirectory: true) }
    /// Observe the directory because every write atomically replaces the board file.
    public func updates() throws -> AsyncStream<Void> {
        guard try ActivitySourceStore.boardEnabled(directory: stateDirectory) else { throw AgentFailure("Task board is disabled.") }
        try PrivateFiles.directory(directory)
        let fd = open(directory.path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AgentFailure("Could not watch the task board.") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .global(qos: .utility))
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { stream in
            source.setEventHandler { stream.yield(()) }
            source.setCancelHandler { close(fd) }
            stream.onTermination = { _ in source.cancel() }
            source.resume()
            stream.yield(())
        }
    }

    public func read() throws -> TaskBoard {
        guard try ActivitySourceStore.boardEnabled(directory: stateDirectory) else { throw AgentFailure("Task board is disabled.") }
        let snapshot = try readSnapshot()
        if snapshot.legacy { return try mutate { _ in } }
        return snapshot.board
    }

    /// Upgrade once on launch or before enabling board access. A current board
    /// starts with the sorted envelope key, so launch never decodes all its tickets.
    public func prepareForSharing() throws {
        let file = directory.appendingPathComponent("Board.json")
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return }
            throw AgentFailure("Could not check the task board format.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let prefix = Data(#"{"board":"#.utf8)
        if try handle.read(upToCount: prefix.count) == prefix { return }
        if try readSnapshot().legacy { _ = try locked(requireEnabled: false) { _ in } }
    }

    // Older helpers read a bare TaskBoard and cannot enforce source permissions.
    // Once upgraded, those helpers must fail closed even if their grant is still enabled.
    private struct StoredBoard: Codable {
        let format: Int
        let board: TaskBoard
    }

    private func readSnapshot() throws -> (board: TaskBoard, legacy: Bool) {
        let url = directory.appendingPathComponent("Board.json")
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AgentFailure("Task board could not be read.") }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let board: TaskBoard
            let legacy: Bool
            if let wrapped = try? decoder.decode(StoredBoard.self, from: data) {
                guard wrapped.format == 2 else { throw AgentFailure("Unsupported task board format.") }
                board = wrapped.board
                legacy = board.needsReferenceIDs
            } else {
                board = try decoder.decode(TaskBoard.self, from: data)
                legacy = true
            }
            guard !board.columns.isEmpty else { throw AgentFailure("The saved board is missing its columns.") }
            return (board, legacy)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (TaskBoard(), false)
        }
    }

    @discardableResult
    public func change(expectedRevision: Int, _ edit: (inout TaskBoard) throws -> Void) throws -> TaskBoard {
        try mutate(expectedRevision: expectedRevision, edit)
    }

    /// Apply only the fields the user edited, comparing with the latest ticket under the writer lock.
    public func save(_ draft: BoardTicket, original: BoardTicket?) throws -> TaskBoard {
        try mutate { board in
            guard let original else {
                if let existing = board.tickets.first(where: { $0.id == draft.id }) {
                    guard existing == draft else { throw AgentFailure("This ticket already exists.") }
                    return
                }
                _ = try board.saveTicket(draft)
                return
            }
            guard original.id == draft.id else { throw AgentFailure("The draft belongs to a different ticket.") }
            let latest = try board.ticket(original.id)
            var merged = latest
            var conflicts: [BoardTicketField] = []
            for field in BoardTicketField.allCases {
                let baseline = field.value(in: original), mine = field.value(in: draft), saved = field.value(in: latest)
                guard mine != baseline else { continue }
                if saved != baseline && saved != mine { conflicts.append(field) }
                field.copy(from: draft, to: &merged)
            }
            guard conflicts.isEmpty else { throw BoardTicketConflict(latest: latest, draft: merged, fields: conflicts) }
            _ = try board.saveTicket(merged)
        }
    }

    func mutate(expectedRevision: Int? = nil, _ edit: (inout TaskBoard) throws -> Void) throws -> TaskBoard {
        guard try ActivitySourceStore.boardEnabled(directory: stateDirectory) else { throw AgentFailure("Task board is disabled.") }
        return try locked(expectedRevision: expectedRevision, requireEnabled: true, edit)
    }

    private func locked(expectedRevision: Int? = nil, requireEnabled: Bool, _ edit: (inout TaskBoard) throws -> Void) throws -> TaskBoard {
        try PrivateFiles.directory(directory)
        let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AgentFailure("Could not open the task board lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AgentFailure("Could not lock the task board.") }
        defer { flock(fd, LOCK_UN) }
        if requireEnabled, try !ActivitySourceStore.boardEnabled(directory: stateDirectory) { throw AgentFailure("Task board is disabled.") }
        let snapshot = try readSnapshot()
        var current = snapshot.board
        let migrate = snapshot.legacy
        if migrate { current.assignMissingReferenceIDs() }
        if let expectedRevision, expectedRevision != current.revision { throw AgentFailure("The board changed. Read the latest board and retry your edit.") }
        var next = current
        try edit(&next)
        guard current != next || migrate else { return current }
        if current != next { next.revision += 1 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFiles.atomicWrite(encoder.encode(StoredBoard(format: 2, board: next)), to: directory.appendingPathComponent("Board.json"))
        return next
    }
}
