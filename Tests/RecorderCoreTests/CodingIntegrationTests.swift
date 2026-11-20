#if canImport(XCTest)
import XCTest
#endif
import Foundation
import Lookback
@testable import RecorderCore

final class CodingIntegrationTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let project = "/projects/example"
    private var source: URL { root.appendingPathComponent("source") }
    private var file: URL { source.appendingPathComponent("example/00000000-0000-4000-a000-000000000001.jsonl") }
    private var archived: URL { root.appendingPathComponent("CodingSessions") }
    private var reader: ClaudeCodeReader { ClaudeCodeReader(projectsDirectory: source) }
    private let transcript = #"""
    {"type":"user","uuid":"old","cwd":"/projects/example","timestamp":"2026-11-01T09:00:00Z","message":{"content":"Earlier migration notes"}}
    {"type":"system","uuid":"boundary","logicalParentUuid":"old"}
    {"type":"user","uuid":"summary","parentUuid":"boundary","isCompactSummary":true,"message":{"content":"Earlier context"}}
    {"type":"user","uuid":"request","parentUuid":"summary","timestamp":"2026-11-05T09:00:00Z","message":{"content":"Delay device restarts during meetings"}}
    {"type":"assistant","uuid":"tool","parentUuid":"request","timestamp":"2026-11-05T09:01:00Z","message":{"id":"response","content":[{"type":"tool_use","id":"run","name":"Read","input":{"private":"SecretInputToken"}}]}}
    {"type":"user","uuid":"result","parentUuid":"tool","message":{"content":[{"type":"tool_result","tool_use_id":"run","content":"SecretOutputToken"}]}}
    {"type":"assistant","uuid":"reply","parentUuid":"result","timestamp":"2026-11-05T09:03:00Z","gitBranch":"device-guard","message":{"content":"Shipped the restart guard."}}
    {"type":"custom-title","customTitle":"Device reliability"}
    """#

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(transcript.utf8).write(to: file)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func imported() throws -> CodingArchive {
        let archive = try CodingArchive(directory: archived)
        try archive.setEnabled(true)
        try archive.addProject(project)
        try archive.synchronize(reader: reader)
        return archive
    }

    private var codexHome: URL { root.appendingPathComponent("codex-home") }
    private let threadID = "00000000-0000-4000-a000-000000000001"
    private func writeRollout(_ id: String, project: String, archived: Bool = false, header: [String: Any] = [:], rows: String = "") throws {
        let folder = codexHome.appendingPathComponent(archived ? "archived_sessions" : "sessions/2026/01/02")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta = header
        meta["id"] = id
        meta["cwd"] = project
        let first = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": meta])
        try (first + Data(("\n" + rows).utf8)).write(to: folder.appendingPathComponent("rollout-2026-01-02-\(id).jsonl"))
    }

    func testCodexRollbackSearchCitationsAndIndependentOptIn() throws {
        let rows = #"""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"initial"}}
        {"type":"response_item","payload":{"type":"message","id":"prompt","role":"user","content":[{"type":"input_text","text":"Compare two tile designs"}]}}
        {"type":"response_item","payload":{"type":"message","id":"answer","role":"assistant","content":[{"type":"output_text","text":"The abandoned mosaic was blue."}]}}
        {"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"revised"}}
        {"type":"response_item","payload":{"type":"message","id":"prompt","role":"user","content":[{"type":"input_text","text":"Choose the final tile design"}]}}
        {"type":"response_item","payload":{"type":"function_call","id":"tool","call_id":"read","name":"inspect_tile","arguments":"SecretArgument"}}
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"read","output":"SecretResult"}}
        {"type":"response_item","payload":{"type":"message","id":"answer","role":"assistant","content":[{"type":"output_text","text":"The selected tile is amber."}]}}
        """#
        try writeRollout(threadID, project: project, rows: rows)
        let store = try imported()
        let sources: [any SessionReader] = [reader, CodexReader(homeDirectory: codexHome, includeArchived: true)]
        func refresh() throws { XCTAssertTrue(try store.refresh(discoverProjects: true, readers: sources).issues.isEmpty) }
        try refresh()
        XCTAssertEqual(try store.sessions().map(\.source), ["claude-code"])
        try store.setEnabled(true, for: .codex)
        try refresh()
        let sessions = try store.sessions()
        XCTAssertEqual(Set(sessions.map(\.source)), ["claude-code", "codex"])
        XCTAssertEqual(Set(sessions.map(\.id)).count, 2)
        let id = try XCTUnwrap(sessions.first { $0.source == "codex" }).id
        let history = try store.history(id: id)
        XCTAssertEqual(history.conversation.map(\.text), ["Choose the final tile design", "", "The selected tile is amber."])
        XCTAssertEqual(history.conversation[1].tools, ["inspect_tile"])
        XCTAssertEqual(Set(history.messages.map(\.id)).count, 5)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(history), as: UTF8.self).contains("Secret"))
        let chunks = try store.embeddingChunks()
        XCTAssertTrue(chunks.contains { $0.text.contains("Choose the final tile design") && $0.text.contains("The selected tile is amber.") })

        try AgentAccessStore.save(.init(enabled: true), directory: root)
        let agent = AgentLibrary(directory: root)
        XCTAssertThrowsError(try agent.call("get_coding_session", arguments: ["session_id": id]))
        try AgentAccessStore.save(.init(enabled: true, allowCodingSessions: true), directory: root)
        for (term, view) in [("mosaic", "recorded"), ("amber", "conversation")] {
            let found = try agent.call("search_activity", arguments: ["query": term, "source": "coding", "mode": "keyword"])
            let hit = try XCTUnwrap((found["items"] as? [[String: Any]])?.first)
            XCTAssertEqual(hit["source"] as? String, "codex")
            XCTAssertEqual(hit["view"] as? String, view)
            let messageID = try XCTUnwrap(hit["message_id"] as? String)
            let page = try agent.call("get_coding_session", arguments: ["session_id": id, "view": view, "message_id": messageID, "limit": 1])
            let message = try XCTUnwrap((page["items"] as? [[String: Any]])?.first)
            XCTAssertTrue((message["text"] as? String)?.contains(term) == true)
        }

        // A rename touches only the thread index. Pausing Codex leaves Claude running.
        let page = try agent.call("get_coding_session", arguments: ["session_id": id, "limit": 1])
        let oldPageRevision = try XCTUnwrap(page["revision"] as? String)
        let revision = try store.revision
        try store.setEnabled(false, for: .codex)
        try Data(#"{"id":"00000000-0000-4000-a000-000000000001","thread_name":"New tile name"}"#.utf8)
            .write(to: codexHome.appendingPathComponent("session_index.jsonl"))
        try refresh()
        XCTAssertEqual(try store.revision, revision)
        try store.setEnabled(true, for: .codex)
        try refresh()
        XCTAssertEqual(try store.history(id: id).session.title, "New tile name")
        XCTAssertThrowsError(try agent.call("get_coding_session", arguments: ["session_id": id, "expected_revision": oldPageRevision]))
        let renamed = try store.revision
        try refresh()
        XCTAssertEqual(try store.revision, renamed)
        try store.removeProject(project)
        XCTAssertTrue(try store.sessions().isEmpty)
        XCTAssertTrue(try store.embeddingChunks().isEmpty)
    }

    func testCodexArchivedAndAccountScopedProjectDiscovery() throws {
        let store = try CodingArchive(directory: archived)
        try store.setEnabled(true, for: .codex)
        try store.addProject(project)
        try writeRollout(threadID, project: project, archived: true)
        try writeRollout("00000000-0000-4000-a000-000000000002", project: "/projects/scoped",
                         header: ["account_scoped": true, "creator_account_id": "a", "creator_user_id": "u"])
        func discover() throws -> [String] {
            let result = try store.refresh(discoverProjects: true, readers: [CodexReader(homeDirectory: codexHome, includeArchived: true)])
            XCTAssertTrue(result.issues.isEmpty)
            return result.projects
        }
        XCTAssertEqual(try discover(), [project, "/projects/scoped"])
        try writeRollout("00000000-0000-4000-a000-000000000003", project: "/projects/other",
                         header: ["account_scoped": true, "creator_account_id": "a", "creator_user_id": "another"])
        XCTAssertEqual(try discover(), [project])
        try store.setCodexAccount(.unscoped)
        XCTAssertEqual(try discover(), [project])
        try store.setCodexAccount(.account(.init(accountID: "a", userID: "u")))
        XCTAssertEqual(try discover(), [project, "/projects/scoped"])
        XCTAssertEqual(try store.sessions().map(\.project), [project])
        try store.addProject("/projects/scoped")
        _ = try discover()
        XCTAssertEqual(Set(try store.sessions().map(\.project)), [project, "/projects/scoped"])
    }

    func testFolderRulesIncludeFutureProjectsAndPersistChildExceptions() throws {
        let store = try CodingArchive(directory: archived)
        try store.setEnabled(true)
        try store.setEnabled(true, for: .codex)
        let codex = CodexReader(homeDirectory: codexHome)
        let parent = "/projects"
        let subfolder = project + "/nested"
        try writeRollout(threadID, project: subfolder)
        try writeRollout("00000000-0000-4000-a000-000000000002", project: "/projects-other")
        func refresh(_ store: CodingArchive) throws {
            XCTAssertTrue(try store.refresh(discoverProjects: false, readers: [reader, codex]).issues.isEmpty)
        }

        // The old table granted this path exactly, even though it is a parent.
        try store.addProject(parent)
        try refresh(store)
        XCTAssertTrue(try store.sessions().isEmpty)
        XCTAssertEqual(try store.settings().projectSelection.state(at: parent, hasChildren: true), .mixed)

        try store.setProjectFolder(parent, included: true)
        try refresh(store)
        XCTAssertEqual(Set(try store.sessions().map(\.project)), [project, subfolder])
        XCTAssertEqual(Set(try store.sessions().map(\.source)), ["claude-code", "codex"])
        XCTAssertEqual(try store.settings().projectSelection.state(at: parent, hasChildren: true), .on)
        try store.setProjectFolder(project, included: false)
        XCTAssertTrue(try store.sessions().isEmpty)
        XCTAssertTrue(try store.embeddingChunks().isEmpty)
        XCTAssertEqual(try store.settings().projectSelection.state(at: parent, hasChildren: true), .mixed)
        let reopened = try CodingArchive(directory: archived)
        try writeRollout("00000000-0000-4000-a000-000000000003", project: "/projects/future")
        try refresh(reopened)
        XCTAssertEqual(try reopened.sessions().map(\.project), ["/projects/future"])

        try reopened.setProjectFolder(subfolder, included: true)
        try refresh(reopened)
        XCTAssertEqual(Set(try reopened.sessions().map(\.project)), [subfolder, "/projects/future"])
        try reopened.setProjectFolder(parent, included: false)
        XCTAssertTrue(try reopened.settings().projectSelection.folders.isEmpty)
        XCTAssertTrue(try reopened.settings().projectSelection.exact.isEmpty)
        try refresh(reopened)
        XCTAssertTrue(try reopened.sessions().isEmpty)
        try reopened.setProjectFolder(subfolder, included: true)
        try refresh(reopened)
        XCTAssertEqual(try reopened.sessions().map(\.project), [subfolder])
    }

    func testProjectTreeGroupsPathsByDirectoryComponents() throws {
        let home = "/Users/example"
        let paths: Set<String> = [home + "/repos/one", home + "/repos/two/child", home + "/repos-old", "/tmp/fixture"]
        let tree = CodingProjectFolder.tree(paths: paths, homeDirectory: home)
        XCTAssertEqual(tree.map(\.name), ["~", "tmp"])
        let folders = try XCTUnwrap(tree.first).children
        XCTAssertEqual(folders.map(\.name), ["repos", "repos-old"])
        XCTAssertEqual(folders.first?.children.map(\.name), ["one", "two"])
        XCTAssertEqual(folders.first?.children.last?.children.first?.path, home + "/repos/two/child")
        let store = try CodingArchive(directory: archived)
        try store.setProjectFolder(home + "/repos/", included: true)
        let selection = try store.settings().projectSelection
        XCTAssertTrue(selection.includes(home + "/repos//two/child"))
        XCTAssertFalse(selection.includes(home + "/repos-old"))
        XCTAssertFalse(selection.includes(home + "/repos/../repos-old"))
        XCTAssertThrowsError(try store.setProjectFolder("relative/path", included: true))
        let absolute = CodingProjectFolder.tree(paths: paths.union(["/", "/Users"]), homeDirectory: home)
        XCTAssertEqual(absolute.map(\.path), ["/"])
    }

    func testFolderBatchPreservesHistoryUntilApplyAndKeepsIncludedChildren() throws {
        let store = try imported()
        try store.setEnabled(true, for: .codex)
        let other = "/projects/other"
        try writeRollout(threadID, project: other)
        let saved = try store.settings().projectSelection
        let both = saved.settingFolder("/projects", included: true)
        XCTAssertFalse(both.removesProjects(from: saved))
        try store.applyProjectSelection(both, replacing: saved)
        try store.synchronize(reader: CodexReader(homeDirectory: codexHome))
        let originalSessions = try store.sessions()
        XCTAssertEqual(Set(originalSessions.map(\.project)), [project, other])

        let draft = both.settingFolder("/projects", included: false)
            .settingFolder(project, included: true)
            .settingFolder("/new/repo", included: true)
        XCTAssertTrue(draft.removesProjects(from: both))
        XCTAssertEqual(try store.settings().projectSelection, both)
        XCTAssertEqual(try store.sessions(), originalSessions)

        try store.applyProjectSelection(draft, replacing: both)
        XCTAssertEqual(try store.settings().projectSelection, draft)
        XCTAssertEqual(try store.sessions(), originalSessions.filter { $0.project == project })
        XCTAssertFalse(try store.history(id: XCTUnwrap(store.sessions().first).id).messages.isEmpty)
        XCTAssertThrowsError(try store.applyProjectSelection(.init(), replacing: both))
        XCTAssertEqual(try store.settings().projectSelection, draft)
        XCTAssertEqual(try store.sessions().count, 1)
    }

    func testSavedPagesUseStableTiesAndFilterBeforeLimiting() throws {
        XCTAssertTrue(try CodingArchive.sessionPage(in: archived).sessions.isEmpty)
        XCTAssertFalse(CodingArchive.exists(in: archived))
        let archive = try imported()
        try archive.setEnabled(true, for: .codex)
        try archive.setProjectFolder("/projects", included: true)
        for n in 1...6 {
            try writeRollout(String(format: "00000000-0000-4000-a000-%012d", n), project: "/projects/other")
        }
        try archive.synchronize(reader: CodexReader(homeDirectory: codexHome))
        let db = try SearchDatabase(url: archived.appendingPathComponent("History.sqlite"), durable: true)
        try db.execute("UPDATE sessions SET modified='100.125'")
        let expected = try archive.sessions()
        var ids: [String] = []
        var cursor: CodingSessionPage.Cursor?
        repeat {
            let page = try CodingArchive.sessionPage(in: archived, after: cursor, limit: 2)
            ids += page.sessions.map(\.id)
            cursor = page.next
            XCTAssertEqual(page.revision, try archive.revision)
        } while cursor != nil
        XCTAssertEqual(ids, expected.map(\.id))
        let filtered = try CodingArchive.sessionPage(in: archived, filter: .init(provider: .claudeCode, project: project, branch: "device-guard"), limit: 1)
        XCTAssertEqual(filtered.sessions.map(\.source), ["claude-code"])
        XCTAssertNil(filtered.next)
        let plan = try db.rows("EXPLAIN QUERY PLAN SELECT info FROM sessions WHERE -CAST(modified AS REAL) >= -CAST(? AS REAL) AND (-CAST(modified AS REAL),id) > (-CAST(? AS REAL),?) ORDER BY -CAST(modified AS REAL),id LIMIT 201", ["100.125", "100.125", "id"])
        XCTAssertTrue(plan.contains { $0.last?.contains("SEARCH sessions USING INDEX sessions_recent") == true })
        XCTAssertFalse(plan.contains { $0.last?.contains("TEMP B-TREE") == true })
    }

    func testOptInArchiveViewsAndCleanup() throws {
        let store = try CodingArchive(directory: archived)
        try store.synchronize(reader: reader)
        XCTAssertTrue(try store.sessions().isEmpty)
        try store.setEnabled(true)
        try store.synchronize(reader: reader)
        XCTAssertTrue(try store.sessions().isEmpty)
        XCTAssertEqual(try store.refresh(discoverProjects: true, readers: [reader]).projects, [project])
        try store.addProject(project)
        try store.synchronize(reader: reader)
        let session = try XCTUnwrap(store.sessions().first)
        let history = try store.history(id: session.id)
        XCTAssertEqual(history.messages.map(\.id), ["old", "summary", "request", "tool", "reply"])
        XCTAssertEqual(history.conversation.map(\.id), ["summary", "request", "tool", "reply"])
        XCTAssertEqual(history.conversation[2].tools, ["Read"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(history), as: UTF8.self).contains("Secret"))
        let revision = try store.revision
        try store.synchronize(reader: reader)
        XCTAssertEqual(try store.revision, revision)
        try FileManager.default.removeItem(at: file)
        try store.synchronize(reader: reader)
        XCTAssertEqual(try store.history(id: session.id).conversationIDs, history.conversationIDs)
        try store.removeProject(project)
        XCTAssertThrowsError(try store.history(id: session.id))
        XCTAssertTrue(try store.embeddingChunks().isEmpty)
    }

    func testRotatedSourceRetainsEarlierEvidenceAndChangesCurrentView() throws {
        let archive = try imported()
        let id = try XCTUnwrap(archive.sessions().first).id
        let row = #"{"type":"user","uuid":"next","cwd":"/projects/example","timestamp":"2026-11-07T09:01:00Z","message":{"content":"Move to the next issue"}}"#
        try Data(row.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(100)], ofItemAtPath: file.path)
        try archive.synchronize(reader: reader)
        let history = try archive.history(id: id)
        XCTAssertEqual(history.conversationIDs, ["next"])
        XCTAssertTrue(history.messages.contains { $0.id == "reply" })
        let old = try archive.matches(query: "migration", semantic: [], from: nil, to: nil, project: project, branch: nil)
        XCTAssertEqual(old.first?.messageID, "old")
        XCTAssertEqual(old.first?.archived, true)
    }

    func testCodingOnlySourceAndLiveSourceChanges() throws {
        let archive = try imported()
        let id = try XCTUnwrap(archive.sessions().first).id
        try AgentAccessStore.save(.init(enabled: true, folders: ["/missing-recordings"], allowCodingSessions: true), directory: root)
        let service = AgentLibrary(directory: root)
        try ActivitySourceStore.save([.coding], directory: root)
        XCTAssertEqual(try service.call("search_activity", arguments: ["source": "coding"])["total"] as? Int, 1)
        try ActivitySourceStore.save([], directory: root)
        XCTAssertThrowsError(try service.call("get_coding_session", arguments: ["session_id": id]))
        XCTAssertEqual(try service.call("search_activity", arguments: [:])["total"] as? Int, 0)
        try ActivitySourceStore.save([.coding], directory: root)
        XCTAssertEqual(try service.call("search_activity", arguments: ["source": "coding"])["total"] as? Int, 1)
    }

    func testAgentAccessRevocationCitationsAndDateFilters() throws {
        let archive = try imported()
        let id = try XCTUnwrap(archive.sessions().first).id
        // Simulate the settings that shipped before coding integration.
        try Data(#"{"version":1,"enabled":true,"folders":[]}"#.utf8).write(to: root.appendingPathComponent("Access.json"))
        let service = AgentLibrary(directory: root)
        func search(_ fields: [String: Any]) throws -> [[String: Any]] {
            try XCTUnwrap(service.call("search_activity", arguments: fields)["items"] as? [[String: Any]])
        }
        XCTAssertTrue(try search(["query": "restart"]).isEmpty)
        XCTAssertThrowsError(try service.call("get_coding_session", arguments: ["session_id": id]))
        try AgentAccessStore.save(.init(enabled: true, allowCodingSessions: true), directory: root)
        XCTAssertEqual(try search(["query": "migration", "from": "2026-11-01T00:00:00Z", "to": "2026-11-02T00:00:00Z"]).first?["message_id"] as? String, "old")
        XCTAssertTrue(try search(["query": "migration", "from": "2026-11-02T00:00:00Z"]).isEmpty)
        XCTAssertEqual(try search(["source": "coding", "from": "2026-11-01T00:00:00Z", "to": "2026-11-02T00:00:00Z"]).first?["message_id"] as? String, "old")
        XCTAssertEqual(try search([:]).first?["session_id"] as? String, id)
        XCTAssertTrue(try search(["query": "restart", "branch": "another"]).isEmpty)
        XCTAssertTrue(try search(["query": "SecretOutputToken"]).isEmpty)
        XCTAssertTrue(try search(["query": "SecretInputToken"]).isEmpty)
        let result = try service.call("get_coding_session", arguments: ["session_id": id, "message_id": "old", "view": "recorded", "limit": 1])
        XCTAssertEqual((result["items"] as? [[String: Any]])?.first?["text"] as? String, "Earlier migration notes")
        XCTAssertEqual(result["next_offset"] as? Int, 1)
        try AgentAccessStore.save(.init(enabled: true), directory: root)
        XCTAssertThrowsError(try service.call("get_coding_session", arguments: ["session_id": id]))
        XCTAssertTrue(try search(["query": "restart"]).isEmpty)
    }

    func testSemanticOnlyCodingHitUsesModelAndRespectsQuotes() throws {
        let archive = try imported()
        let model = EmbeddingModel.catalog[0]
        let settingsDirectory = root.appendingPathComponent("embeddings")
        var settings = EmbeddingSettings()
        settings.enabled = true; settings.modelID = model.id
        try settings.save(directory: settingsDirectory)
        try PrivateFiles.directory(EmbeddingSettings.modelRoot(settingsDirectory))
        try Data().write(to: ModelStore.ownedURL(model.asset, root: EmbeddingSettings.modelRoot(settingsDirectory)))
        let index = try LibrarySearchIndex(roots: [], directory: root.appendingPathComponent("search"), embeddingDirectory: settingsDirectory)
        index.semantic = SemanticSearchEngine(directory: settingsDirectory) { texts, model, _, _ in
            texts.map { _ in [1] + Array(repeating: 0, count: model.dimensions - 1) }
        }
        try index.useCodingArchive(in: archived)
        let deadline = Date().addingTimeInterval(5)
        while index.semanticStatus().state == "indexing" && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(try index.codingSearch("rebooting", keywordOnly: true).hits.isEmpty)
        let semantic = try index.codingSearch("rebooting")
        XCTAssertEqual(semantic.status.mode, "hybrid")
        XCTAssertEqual(semantic.hits.count, 1)
        let hit = try XCTUnwrap(semantic.hits.first)
        let saved = try archive.history(id: hit.session.id)
        XCTAssertEqual(hit.passages.count, 3)
        for passage in hit.passages {
            XCTAssertTrue(saved.messages.contains { $0.id == passage.messageID && !$0.text.isEmpty })
        }
        XCTAssertTrue(try index.codingSearch(#""an unrelated exact phrase""#).hits.isEmpty)
        try archive.removeProject(project)
        index.refreshSemanticSearch()
        XCTAssertTrue(try index.codingSearch("rebooting").hits.isEmpty)
        index.stopSemanticSearch()
    }

    func testDateBrowseGroupsToolActivityAndKeepsOriginalCitations() throws {
        _ = try imported()
        try AgentAccessStore.save(.init(enabled: true, allowCodingSessions: true), directory: root)
        let service = AgentLibrary(directory: root)
        func browse(_ from: String, _ to: String) throws -> [[String: Any]] {
            let result = try service.call("search_activity", arguments: ["source": "coding", "project": project, "from": from, "to": to])
            return try XCTUnwrap(result["items"] as? [[String: Any]])
        }
        let items = try browse("2026-11-05T09:00:00Z", "2026-11-05T09:04:00Z")
        XCTAssertEqual(items.count, 1)
        let overview = try XCTUnwrap(items.first)
        XCTAssertEqual(overview["message_id"] as? String, "reply")
        XCTAssertEqual(overview["text"] as? String, "Shipped the restart guard.")
        XCTAssertEqual(overview["tool_only_message_count"] as? Int, 1)
        let more = try XCTUnwrap(overview["more_passages"] as? [[String: Any]])
        XCTAssertEqual(more.compactMap { $0["message_id"] as? String }, ["request"])
        let justTools = try XCTUnwrap(browse("2026-11-05T09:01:00Z", "2026-11-05T09:03:00Z").first)
        XCTAssertEqual(justTools["tool_only_message_count"] as? Int, 1)
        XCTAssertEqual(justTools["last_activity_at"] as? String, "2026-11-05T09:01:00Z")
        XCTAssertNil(justTools["message_id"])
        XCTAssertTrue(try browse("2026-11-05T09:04:00Z", "2026-11-06T00:00:00Z").isEmpty)
        let detail = try service.call("get_coding_session", arguments: ["session_id": try XCTUnwrap(overview["session_id"] as? String),
                                                                       "message_id": "tool", "limit": 1])
        XCTAssertEqual((detail["items"] as? [[String: Any]])?.first?["tools"] as? [String], ["Read"])
    }

    func testSessionTitlesRankAlongsidePassagesAndRepeatedMatchesShareOneResult() throws {
        let other = file.deletingLastPathComponent().appendingPathComponent("00000000-0000-4000-a000-000000000002.jsonl")
        let named = transcript.replacingOccurrences(of: "Device reliability", with: "Meeting guard")
        let incidental = transcript.replacingOccurrences(of: "Earlier migration notes", with: "Meeting guard")
            .replacingOccurrences(of: "Delay device restarts during meetings", with: "Meeting guard")
            .replacingOccurrences(of: "Shipped the restart guard.", with: "Meeting guard")
        try Data(named.utf8).write(to: other)
        try Data(incidental.utf8).write(to: file)
        let archive = try imported()
        let chunks = try archive.embeddingChunks()
        let title = try XCTUnwrap(chunks.first {
            guard case .coding(_, "", _, _) = $0.origin else { return false }
            return $0.text == "Meeting guard"
        })
        let weaker = chunks.filter {
            guard case let .coding(_, id, _, _) = $0.origin else { return false }
            return !id.isEmpty && $0.text.contains("Meeting guard")
        }
        let lexical = try archive.matches(query: #""meeting guard""#, semantic: [], from: nil, to: nil, project: project, branch: nil)
        XCTAssertEqual(lexical.map { $0.session.title }, ["Meeting guard", "Device reliability"])
        let incidentalHit = try XCTUnwrap(lexical.last)
        XCTAssertEqual(Set(incidentalHit.passages.map(\.messageID)).count, 3)
        let supporting = try XCTUnwrap(chunks.first {
            guard case let .coding(id, "reply", _, _) = $0.origin else { return false }
            return id == lexical.first?.session.id
        })
        let titleOnly = try archive.matches(query: "occupied room", semantic: [(title, 0.12)], from: nil, to: nil, project: project, branch: nil)
        XCTAssertEqual(titleOnly.first?.session.title, "Meeting guard")
        XCTAssertNil(titleOnly.first?.messageID)
        // Several stronger individual excerpts lose to a session with independent title and passage evidence.
        let semantic: [(SemanticChunk, Float)] = weaker.map { ($0, 0.25) } + [(supporting, 0.19), (title, 0.12)]
        let results = try archive.matches(query: "occupied room", semantic: semantic, from: nil, to: nil, project: project, branch: nil)
        XCTAssertEqual(results.map { $0.session.title }, ["Meeting guard", "Device reliability"])
        XCTAssertEqual(results.first?.messageID, "reply")
        XCTAssertTrue(try archive.matches(query: #""occupied room""#, semantic: semantic, from: nil, to: nil, project: project, branch: nil).isEmpty)

        try AgentAccessStore.save(.init(enabled: true, allowCodingSessions: true), directory: root)
        let service = AgentLibrary(directory: root)
        var args: [String: Any] = ["source": "coding", "query": "meeting guard", "mode": "keyword", "limit": 1]
        let first = try service.call("search_activity", arguments: args)
        XCTAssertEqual(first["total"] as? Int, 2)
        args["offset"] = try XCTUnwrap(first["next_offset"] as? Int)
        args["expected_revision"] = try XCTUnwrap(first["library_revision"] as? String)
        let second = try service.call("search_activity", arguments: args)
        XCTAssertEqual((second["items"] as? [[String: Any]])?.first?["session_id"] as? String, incidentalHit.session.id)
        XCTAssertNil(second["next_offset"])
    }
}
