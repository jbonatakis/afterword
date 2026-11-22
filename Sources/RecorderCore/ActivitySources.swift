import Foundation

public enum ActivitySource: String, Codable, CaseIterable, Sendable {
    case recordings, coding, github, board

    public static let feedSources: Set<Self> = [.recordings, .coding, .github]
}

/// The app and MCP helper read the same selection. An absent file predates source selection.
public enum ActivitySourceStore {
    // Keep the experimental flag separate so stable builds can still read the same Sources.json.
    static func boardEnabled(directory: URL) throws -> Bool {
        let url = directory.appendingPathComponent("BoardEnabled.json")
        do {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                throw RecorderError.message("The task board setting could not be read.")
            }
            return try JSONDecoder().decode(Bool.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    public static func load(directory: URL = AgentAccessStore.directory) throws -> Set<ActivitySource>? {
        let url = directory.appendingPathComponent("Sources.json")
        do {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                throw RecorderError.message("The library source settings could not be read.")
            }
            let data = try Data(contentsOf: url)
            var sources = try JSONDecoder().decode(Set<ActivitySource>.self, from: data).intersection(ActivitySource.feedSources)
            if try boardEnabled(directory: directory) { sources.insert(.board) }
            return sources
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public static func save(_ sources: Set<ActivitySource>, directory: URL = AgentAccessStore.directory) throws {
        try PrivateFiles.directory(directory)
        let previous = try load(directory: directory)
        let feed = sources.intersection(ActivitySource.feedSources)
        let board = sources.contains(.board)
        let wasEnabled = try boardEnabled(directory: directory)
        func saveBoardFlag() throws {
            try PrivateFiles.atomicWrite(JSONEncoder().encode(board), to: directory.appendingPathComponent("BoardEnabled.json"))
            AgentAccessStore.notifyToolsChanged()
        }
        // Revoke first and grant last when the setup screen changes several sources at once.
        if wasEnabled && !board { try saveBoardFlag() }
        if previous?.intersection(ActivitySource.feedSources) != feed {
            let ordered = ActivitySource.allCases.filter(feed.contains)
            try PrivateFiles.atomicWrite(JSONEncoder().encode(ordered), to: directory.appendingPathComponent("Sources.json"))
        }
        if !wasEnabled && board {
            try TaskBoardStore(stateDirectory: directory).prepareForSharing()
            try saveBoardFlag()
        }
    }
}
