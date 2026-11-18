import Foundation

public enum ActivitySource: String, Codable, CaseIterable, Sendable {
    case recordings, coding, github
}

/// The app and MCP helper read the same selection. An absent file predates source selection.
public enum ActivitySourceStore {
    public static func load(directory: URL = AgentAccessStore.directory) throws -> Set<ActivitySource>? {
        let url = directory.appendingPathComponent("Sources.json")
        do {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                throw RecorderError.message("The library source settings could not be read.")
            }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Set<ActivitySource>.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public static func save(_ sources: Set<ActivitySource>, directory: URL = AgentAccessStore.directory) throws {
        try PrivateFiles.directory(directory)
        let ordered = ActivitySource.allCases.filter(sources.contains)
        try PrivateFiles.atomicWrite(JSONEncoder().encode(ordered), to: directory.appendingPathComponent("Sources.json"))
    }
}
