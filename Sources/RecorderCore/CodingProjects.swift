import Foundation

public struct CodingProjectSelection: Sendable, Equatable {
    public enum State { case off, mixed, on }
    public let exact: Set<String>
    public let folders: [String: Bool]

    public init() { self.init(exact: [], folders: [:]) }

    init(exact: Set<String>, folders: [String: Bool]) {
        self.exact = exact
        self.folders = folders
    }

    var hasIncludes: Bool { !exact.isEmpty || folders.values.contains(true) }

    // Match directory components without following paths on disk. A discovered
    // project may already have moved by the time its sessions are imported.
    static func path(_ value: String) -> String? {
        guard value.hasPrefix("/"), !value.utf8.contains(0) else { return nil }
        let parts = value.split(separator: "/").filter { $0 != "." }
        guard !parts.contains("..") else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    static func contains(_ path: String, in folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    func inherited(at path: String) -> Bool {
        var cursor = path
        while true {
            if let value = folders[cursor] { return value }
            if cursor == "/" { return false }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
    }

    public func includes(_ value: String) -> Bool {
        guard let path = Self.path(value) else { return false }
        return exact.contains(path) || inherited(at: path)
    }

    public func state(at path: String, hasChildren: Bool) -> State {
        if inherited(at: path) {
            return folders.contains { !$0.value && Self.contains($0.key, in: path) } ? .mixed : .on
        }
        if !hasChildren, exact.contains(path) { return .on }
        let selected = exact.contains { Self.contains($0, in: path) } ||
            folders.contains { $0.value && Self.contains($0.key, in: path) }
        return selected ? .mixed : .off
    }
}

public struct CodingProjectFolder: Identifiable, Sendable {
    public var id: String { path }
    public let path, name: String
    public let children: [CodingProjectFolder]

    public static func tree(paths: Set<String>, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [Self] {
        let paths = Set(paths.compactMap(CodingProjectSelection.path))
        let showRoot = paths.contains("/")
        let homeBranch = "/" + (homeDirectory.split(separator: "/").first.map(String.init) ?? "")
        let showHomeAsRoot = !paths.contains {
            CodingProjectSelection.contains($0, in: homeBranch) && !CodingProjectSelection.contains($0, in: homeDirectory)
        }
        var roots = Set<String>(), children: [String: Set<String>] = [:]
        for path in paths {
            var cursor = path
            while true {
                let parent = (cursor as NSString).deletingLastPathComponent
                if cursor == "/" || (!showRoot && ((showHomeAsRoot && cursor == homeDirectory) || parent == "/")) {
                    roots.insert(cursor)
                    break
                }
                children[parent, default: []].insert(cursor)
                cursor = parent
            }
        }
        func nodes(_ paths: Set<String>) -> [Self] {
            paths.sorted().map { path in
                let name = path == homeDirectory ? "~" : (path == "/" ? "/" : (path as NSString).lastPathComponent)
                return Self(path: path, name: name, children: nodes(children[path] ?? []))
            }
        }
        return nodes(roots)
    }
}
