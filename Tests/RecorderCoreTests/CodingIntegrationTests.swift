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

    func testBoardCitationTracksCodingGrantMessageAndImportedProject() throws {
        let archive = try imported()
        let session = try XCTUnwrap(archive.sessions().first)
        let message = try XCTUnwrap(archive.history(id: session.id).messages.first { $0.text == "Shipped the restart guard." })
        let ref = BoardReference(source: .coding, itemID: session.id, anchor: message.id, label: session.title, quote: message.text)
        try ActivitySourceStore.save([.coding, .board], directory: root)
        var grants = AgentAccessConfiguration(enabled: true)
        grants.allowBoardManagement = true
        try AgentAccessStore.save(grants, directory: root)
        let ticket = BoardTicket(title: "Follow up", columnID: "todo", references: [ref])
        let store = TaskBoardStore(stateDirectory: root)
        _ = try store.save(ticket, original: nil)
        let agent = AgentLibrary(directory: root)
        func refs() throws -> [[String: Any]] {
            let row = try XCTUnwrap(agent.call("get_board_ticket", arguments: ["ticket_id": ticket.id])["ticket"] as? [String: Any])
            return try XCTUnwrap(row["references"] as? [[String: Any]])
        }
        XCTAssertTrue(try refs().isEmpty)
        grants.allowCodingSessions = true
        try AgentAccessStore.save(grants, directory: root)
        XCTAssertEqual(try refs().first?["quote"] as? String, message.text)
        let token = try agent.call("get_board", arguments: [:])["revision"]!
        for (anchor, quote) in [(message.id, "made up"), ("missing", message.text)] {
            XCTAssertThrowsError(try agent.call("add_board_reference", arguments: ["ticket_id": ticket.id, "source": "coding",
                "item_id": session.id, "anchor": anchor, "quote": quote, "expected_revision": token]))
        }
        try archive.removeProject(project)
        XCTAssertTrue(try refs().isEmpty)
        XCTAssertEqual(try store.read().ticket(ticket.id), ticket)
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

    func testPiStoreSelectionBranchCitationsAndPause() throws {
        let store = try CodingArchive(directory: archived)
        let folder = root.appendingPathComponent("PiStore", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("custom.jsonl")
        let log = #"""
        {"type":"session","version":3,"id":"named","cwd":"/projects/example"}
        {"type":"message","id":"ask","parentId":null,"message":{"role":"user","content":"Describe the sundial."}}
        {"type":"message","id":"draft","parentId":"ask","message":{"role":"assistant","content":[{"type":"text","text":"Try a pendulum."}]}}
        {"type":"model_change","id":"meta","parentId":"ask"}
        {"type":"message","id":"tool","parentId":"meta","message":{"role":"assistant","content":[{"type":"thinking","thinking":"PrivateThought"},{"type":"toolCall","id":"t","name":"inspect","arguments":{"q":"PrivateArg"}}]}}
        {"type":"message","id":"result","parentId":"tool","message":{"role":"toolResult","toolCallId":"t","content":[{"type":"text","text":"PrivateOutput"}]}}
        {"type":"compaction","id":"summary","parentId":"result","firstKeptEntryId":"summary","summary":"Measured the dial."}
        {"type":"message","id":"reply","parentId":"summary","message":{"role":"assistant","content":[{"type":"text","text":"Use the gnomon."}]}}
        {"type":"session_info","id":"name","parentId":"reply","name":"Dial"}
        """#
        try Data(log.utf8).write(to: file)
        try Data(log.replacingOccurrences(of: project, with: "/projects/excluded").utf8)
            .write(to: folder.appendingPathComponent("excluded.jsonl"))
        try store.setPiSessionsDirectory(folder)
        try store.addProject(project)
        func refresh() throws -> [String] {
            let result = try store.refresh(discoverProjects: true, provider: .pi)
            XCTAssertTrue(result.issues.isEmpty)
            return result.projects
        }
        XCTAssertTrue(try refresh().isEmpty)
        try store.setEnabled(true, for: .pi)
        XCTAssertEqual(try refresh(), [project, "/projects/excluded"])
        let sessions = try store.sessions()
        XCTAssertEqual(sessions.map(\.providerName), ["Pi"])
        let id = try XCTUnwrap(sessions.first).id
        let history = try store.history(id: id)
        XCTAssertEqual(history.conversationIDs, ["ask", "tool", "summary", "reply"])
        XCTAssertEqual(history.conversation[1].tools, ["inspect"])
        XCTAssertEqual(history.conversation[1].parentID, "ask")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(history), as: UTF8.self).contains("Private"))
        XCTAssertEqual(try CodingArchive.sessionPage(in: archived, filter: .init(provider: .pi)).sessions.map(\.id), [id])
        let revision = try store.revision
        _ = try refresh()
        XCTAssertEqual(try store.revision, revision)

        try AgentAccessStore.save(.init(enabled: true, allowCodingSessions: true), directory: root)
        let agent = AgentLibrary(directory: root)
        for (term, view, anchor) in [("pendulum", "recorded", "draft"), ("gnomon", "conversation", "reply")] {
            let result = try agent.call("search_activity", arguments: ["source": "coding", "query": term, "mode": "keyword"])
            let hit = try XCTUnwrap((result["items"] as? [[String: Any]])?.first)
            XCTAssertEqual(hit["source"] as? String, "pi")
            XCTAssertEqual(hit["view"] as? String, view)
            XCTAssertEqual(hit["message_id"] as? String, anchor)
            let page = try agent.call("get_coding_session", arguments: ["session_id": id, "view": view, "message_id": anchor, "limit": 1])
            XCTAssertTrue(((page["items"] as? [[String: Any]])?.first?["text"] as? String)?.contains(term) == true)
        }
        try store.setEnabled(true, for: .codex)
        try store.setEnabled(true, for: .claudeCode)
        try store.setEnabled(false, for: .pi)
        let rename = #"{"type":"session_info","id":"rename","parentId":"name","name":"Renamed dial"}"#
        try Data((log + "\n" + rename).utf8).write(to: file)
        XCTAssertTrue(try refresh().isEmpty)
        XCTAssertEqual(try store.sessions().first?.title, "Dial")
        XCTAssertEqual(try store.settings().providers, [.claudeCode, .codex])
        try store.setEnabled(true, for: .pi)
        _ = try refresh()
        XCTAssertEqual(try store.sessions().first?.title, "Renamed dial")
        XCTAssertEqual(try store.history(id: id).conversationIDs, history.conversationIDs)
        try store.setPiSessionsDirectory(nil)
        XCTAssertNil(try store.settings().piSessionsDirectory)
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

    func testClaudeTaskNotificationsRepairAttributionAndKeepSearchCitations() throws {
        func event(_ id: String, parent: String, status: String, summary: String, result: String = "", generated: Bool = true) throws -> String {
            let payload = "<task-notification><status>\(status)</status><summary>\(summary)</summary><result>\(result)</result></task-notification>"
            var row: [String: Any] = ["type": "user", "uuid": id, "parentUuid": parent, "message": ["content": payload]]
            if generated { row["origin"] = ["kind": "task-notification"] }
            return String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self)
        }
        let rows = try [
            event("notice", parent: "reply", status: "completed", summary: "Review finished", result: "Review evidence"),
            event("paste", parent: "notice", status: "completed", summary: "Review finished", result: "Review evidence", generated: false),
            event("empty", parent: "paste", status: "completed", summary: "Routine background completion"),
            event("failure", parent: "empty", status: "failed", summary: "Worker interrupted")
        ]
        try Data(([transcript] + rows).joined(separator: "\n").utf8).write(to: file)
        let store = try imported()
        let id = try XCTUnwrap(store.sessions().first).id
        let db = try SearchDatabase(url: archived.appendingPathComponent("History.sqlite"), durable: true)
        // Simulate the legacy payload and unchanged source timestamp for the same session.
        var legacy = try store.history(id: id)
        legacy = CodingHistory(session: legacy.session, messages: legacy.messages.map {
            CodingMessage(id: $0.id, role: $0.taskNotification == nil ? $0.role : "User", text: $0.text,
                          parentID: $0.parentID, timestamp: $0.timestamp, tools: $0.tools)
        }, conversationIDs: legacy.conversationIDs + ["empty"])
        let json = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        try db.execute("UPDATE sessions SET history=?, info=json_remove(info,'$.transcriptVersion') WHERE id=?", [json, id])
        try db.execute("DELETE FROM settings WHERE key='claudeTaskNotificationsV1'")
        try store.synchronize(reader: reader)
        let history = try store.history(id: id)
        let notice = try XCTUnwrap(history.messages.first { $0.id == "notice" })
        let paste = try XCTUnwrap(history.messages.first { $0.id == "paste" })
        XCTAssertEqual(notice.text, paste.text)
        XCTAssertEqual(notice.role, "Task notification")
        XCTAssertEqual(notice.taskNotification?.result, "Review evidence")
        XCTAssertEqual(paste.role, "User")
        XCTAssertNil(paste.taskNotification)
        XCTAssertEqual(Array(history.conversationIDs.suffix(3)), ["notice", "paste", "failure"])
        let hit = try store.matches(query: "routine background completion", semantic: [], from: nil, to: nil, project: project, branch: nil).first
        XCTAssertEqual(hit?.messageID, "empty")
        XCTAssertEqual(hit?.archived, true)
        let revision = try store.revision
        try store.synchronize(reader: reader)
        XCTAssertEqual(try store.revision, revision)
    }

    func testCodexCompactionRepairsExistingConversationAndSearchCitations() throws {
        let rows = #"""
        {"type":"event_msg","payload":{"type":"user_message","id":"prompt","message":"Build the app"}}
        {"type":"event_msg","payload":{"type":"agent_message","id":"answer","message":"Signed the release bundle."}}
        {"type":"compacted","payload":{"replacement_history":[{"type":"message","id":"prompt","role":"user","content":[{"type":"input_text","text":"Build the app"}]}]}}
        {"type":"event_msg","payload":{"type":"user_message","id":"next","message":"Which files were included in the new package and where can I find them?"}}
        """#
        try writeRollout(threadID, project: project, rows: rows)
        let store = try CodingArchive(directory: archived)
        try store.addProject(project)
        try store.setEnabled(true, for: .codex)
        let reader = CodexReader(homeDirectory: codexHome)
        try store.synchronize(reader: reader)
        let id = try XCTUnwrap(store.sessions().first).id
        let expected = ["prompt", "answer", "next"]
        XCTAssertEqual(try store.history(id: id).conversationIDs, expected)

        // Recreate the unchanged source stamp, cache and search flags from the old importer.
        let db = try SearchDatabase(url: archived.appendingPathComponent("History.sqlite"), durable: true)
        try db.execute("""
            UPDATE sessions SET info=json_remove(info,'$.transcriptVersion'),
              history=json_set(json_remove(history,'$.session.transcriptVersion'),'$.conversationIDs',json('["prompt","next"]')) WHERE id=?
            """, [id])
        try db.execute("UPDATE coding_text SET archived='1' WHERE session=? AND message='answer'", [id])
        try db.execute("DELETE FROM settings WHERE key='codexBranchTranscriptV1'")
        try AgentAccessStore.save(.init(enabled: true, allowCodingSessions: true), directory: root)
        let agent = AgentLibrary(directory: root)
        let page = try agent.call("get_coding_session", arguments: ["session_id": id])
        XCTAssertEqual(page["total"] as? Int, 2)
        let revision = try XCTUnwrap(page["revision"] as? String)

        try store.synchronize(reader: reader)
        let repaired = try agent.call("get_coding_session", arguments: ["session_id": id])
        XCTAssertEqual((repaired["items"] as? [[String: Any]])?.compactMap { $0["message_id"] as? String }, expected)
        XCTAssertThrowsError(try agent.call("get_coding_session", arguments: ["session_id": id, "expected_revision": revision]))
        let hit = try store.matches(query: "signed", semantic: [], from: nil, to: nil, project: project, branch: nil).first
        XCTAssertEqual(hit?.messageID, "answer")
        XCTAssertEqual(hit?.archived, false)
        let repairedRevision = try store.revision
        try store.synchronize(reader: reader)
        XCTAssertEqual(try store.revision, repairedRevision)
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

    func testToolEvidenceSearchPairsParallelCallsAndReplaysLegacyArchive() throws {
        let rows = #"""
        {"type":"assistant","uuid":"batch","parentUuid":"reply","message":{"id":"parallel","content":[{"type":"text","text":"Checking the implementation."},{"type":"tool_use","id":"path","name":"Read","input":{"file_path":"/projects/example/Source/Orchard.swift"}},{"type":"tool_use","id":"tests","name":"Bash","input":{"command":"swift test --filter OrchardTests"}},{"type":"tool_use","id":"unknown","name":"CustomTool","input":{"body":"SecretCustomInput"}}]}}
        {"type":"user","uuid":"results","parentUuid":"batch","message":{"content":[{"type":"tool_result","tool_use_id":"tests","is_error":true,"content":"OrchardTests.swift:9: error: expected 1 row, got 2\nTest Suite 'All tests' failed at 12:00"},{"type":"tool_result","tool_use_id":"path","content":"SecretFileContents"},{"type":"tool_result","tool_use_id":"unknown","content":"SecretCustomOutput"}]}}
        """#
        try Data((transcript + "\n" + rows).utf8).write(to: file)
        let archive = try imported()
        let id = try XCTUnwrap(archive.sessions().first).id
        let db = try SearchDatabase(url: archived.appendingPathComponent("History.sqlite"), durable: true)
        // An unchanged v1 source is enriched once. The legacy name array stays readable while paused.
        try db.execute("UPDATE sessions SET info=json_set(info,'$.transcriptVersion',1), history=json_remove(history,'$.messages[5].toolCalls')")
        try db.execute("DELETE FROM coding_tool_text")
        func batch() throws -> CodingMessage { try XCTUnwrap(archive.history(id: id).messages.first { $0.id == "batch" }) }
        try archive.setEnabled(false)
        try archive.synchronize(reader: reader)
        XCTAssertEqual(try batch().displayedToolCalls.map(\.name), ["Read", "Bash", "CustomTool"])
        XCTAssertNil(try batch().toolCalls)
        try archive.setEnabled(true)
        try archive.synchronize(reader: reader)
        let calls = try XCTUnwrap(batch().toolCalls)
        XCTAssertEqual(calls.map(\.action), [.read, .test, .other])
        XCTAssertEqual(calls[0].subject, "Source/Orchard.swift")
        XCTAssertNil(calls[0].result)
        XCTAssertEqual(calls[1].testOutcome, "failed")
        XCTAssertEqual(calls[1].diagnostic, "OrchardTests.swift:9: error: expected 1 row, got 2")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(calls), as: UTF8.self).contains("Secret"))
        func search(_ term: String) throws -> [CodingHit] {
            try archive.matches(query: term, semantic: [], from: nil, to: nil, project: project, branch: nil)
        }
        let failure = try XCTUnwrap(search("expected 1 row").first)
        XCTAssertEqual(failure.messageID, "batch")
        XCTAssertEqual(failure.toolIndex, 1)
        XCTAssertEqual(try search("Source/Orchard.swift").first?.toolIndex, 0)
        let revision = try archive.revision
        try archive.synchronize(reader: reader)
        XCTAssertEqual(try archive.revision, revision)

        try AgentAccessStore.save(.init(enabled: true, allowCodingSessions: true), directory: root)
        let agent = AgentLibrary(directory: root)
        let shared = try agent.call("search_activity", arguments: ["source": "coding", "query": "OrchardTests", "mode": "keyword"])
        XCTAssertEqual(shared["total"] as? Int, 0)
        let page = try agent.call("get_coding_session", arguments: ["session_id": id, "message_id": "batch", "limit": 1])
        XCTAssertFalse(String(describing: page).contains("Orchard"))
        XCTAssertFalse(try archive.embeddingChunks().contains { $0.text.contains("Orchard") })

        try archive.removeProject(project)
        XCTAssertTrue(try db.rows("SELECT session FROM coding_tool_text").isEmpty)
    }

    func testCodexScriptIndexesReportedCommandsWithoutGuessingAboutOverlappingCalls() throws {
        let rows = #"""
        {"type":"response_item","payload":{"type":"custom_tool_call","id":"wrapper","call_id":"s","name":"exec","input":"await inspect()"}}
        {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"read-one","command":["zsh","-lc","cat Sources/Fruit.swift"],"parsed_cmd":[{"type":"read","path":"/projects/example/Sources/Fruit.swift"}],"exit_code":0,"aggregated_output":"SecretReadBody"}}}
        {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"test-one","command":["zsh","-lc","swift test"],"exit_code":1,"status":"failed","aggregated_output":"FruitTests:9: error: plumfixture failed\nTest Suite 'All tests' failed at noon"}}}
        {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"edit-one","changes":{"Sources/Fruit.swift":{"type":"update","unified_diff":"-before\n+after"}}}}}
        {"type":"response_item","payload":{"type":"custom_tool_call","id":"sibling","call_id":"b","name":"exec","input":"await check()"}}
        {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"ambiguous","command":"SecretAmbiguous","exit_code":1}}}
        {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"s","output":"ok"}}
        {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"b","output":"ok"}}
        """#
        try writeRollout(threadID, project: project, rows: rows)
        let store = try CodingArchive(directory: archived)
        try store.addProject(project)
        try store.setEnabled(true, for: .codex)
        try store.synchronize(reader: CodexReader(homeDirectory: codexHome))
        let history = try store.history(id: XCTUnwrap(store.sessions().first).id)
        XCTAssertEqual(history.conversationIDs, ["wrapper", "sibling"])
        let events = try XCTUnwrap(history.conversation.first?.toolCalls?.first?.events)
        XCTAssertEqual(events.map(\.action), [.read, .test, .edit])
        XCTAssertEqual(events[0].subject, "Sources/Fruit.swift")
        XCTAssertEqual(events[0].result, "Exit 0")
        XCTAssertEqual(events[1].result, "Exit 1")
        XCTAssertEqual(events[1].testOutcome, "failed")
        XCTAssertEqual(events[2].subject, "Sources/Fruit.swift")
        XCTAssertTrue(events[2].preview?.contains("+after") == true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(history), as: UTF8.self).contains("Secret"))
        let hit = try XCTUnwrap(store.matches(query: "plumfixture", semantic: [], from: nil, to: nil, project: nil, branch: nil).first)
        XCTAssertEqual(hit.messageID, "wrapper")
        XCTAssertEqual(hit.toolIndex, 0)
        XCTAssertEqual(hit.eventIndex, 1)
    }

    func testOpeningLegacyCodexSessionRecoversOnlyItsExecDetails() throws {
        let rows = #"""
        {"type":"response_item","payload":{"type":"custom_tool_call","id":"a","call_id":"1","name":"exec","input":"inspectOne()"}}
        {"type":"response_item","payload":{"type":"custom_tool_call","id":"b","call_id":"2","name":"exec","input":"inspectTwo()"}}
        {"type":"response_item","payload":{"type":"custom_tool_call","id":"c","call_id":"3","name":"exec","input":"inspectThree()"}}
        """#
        try writeRollout(threadID, project: project, rows: rows)
        try writeRollout("00000000-0000-4000-a000-000000000002", project: project, rows: rows)
        let reader = CodexReader(homeDirectory: codexHome)
        let archive = try CodingArchive(directory: archived)
        try archive.setEnabled(true, for: .codex)
        try archive.addProject(project)
        try archive.synchronize(reader: reader)
        let sessions = try archive.sessions()
        XCTAssertEqual(sessions.count, 2)
        let id = try XCTUnwrap(sessions.first).id
        let other = try XCTUnwrap(sessions.last).id
        let db = try SearchDatabase(url: archived.appendingPathComponent("History.sqlite"), durable: true)
        try db.execute("""
            UPDATE sessions SET info=json_set(info,'$.transcriptVersion',1),
              history=json_set(json_remove(history,'$.messages[0].toolCalls','$.messages[1].toolCalls','$.messages[2].toolCalls'),
                               '$.session.transcriptVersion',1)
            """)
        func open() throws -> [CodingToolCall] {
            try CodingArchive.historyForDisplay(in: archived, id: id, readers: [reader]).conversation.flatMap(\.displayedToolCalls)
        }
        try archive.setEnabled(false, for: .codex)
        XCTAssertEqual(try open().map(\.hasDetails), [false, false, false])
        try archive.setEnabled(true, for: .codex)
        XCTAssertEqual(try open().compactMap(\.preview), ["inspectOne()", "inspectTwo()", "inspectThree()"])
        XCTAssertNil(try archive.history(id: other).messages.first?.toolCalls)
        let revision = try archive.revision
        _ = try open()
        XCTAssertEqual(try archive.revision, revision)
    }

    func testToolEvidenceUsesOnlyRecordedFieldsAndBoundsExcerpts() throws {
        func call(_ name: String, _ input: Any, provider: CodingProvider = .codex) throws -> CodingToolCall {
            CodingToolCall(name: name, input: try JSONSerialization.data(withJSONObject: input, options: .fragmentsAllowed),
                           project: project, provider: provider.rawValue)
        }
        let command = try call("shell_command", ["command": "swift test --filter LeafTests"])
        XCTAssertEqual(command.action, .test)
        XCTAssertEqual(command.subject, "swift test --filter LeafTests")
        let poll = try call("write_stdin", ["session_id": 37, "chars": ""])
        XCTAssertEqual(poll.subject, "Poll terminal session 37")
        let input = try call("write_stdin", ["session_id": 37, "chars": "PrivateStdin"])
        XCTAssertEqual(input.subject, "Send input to terminal session 37")
        XCTAssertFalse(input.searchText.contains("PrivateStdin"))
        let task = try call("TaskUpdate", ["taskId": "7", "status": "completed", "metadata": ["private": "PrivateValue"]])
        XCTAssertEqual(task.preview, "status = completed\ntaskId = 7")
        let mcp = try call("call_mcp_tool", ["ServerName": "work", "ToolName": "lookup", "Arguments": ["query": "Apricots", "token": "PrivateToken"]], provider: .antigravity)
        XCTAssertEqual(mcp.preview, "query = Apricots")
        let opaque = try call("CustomTool", ["body": "PrivateBody"])
        XCTAssertFalse(opaque.hasDetails)
        let edit = try call("Edit", ["file_path": "/projects/example2/a", "old_string": "old", "new_string": "new"])
        XCTAssertEqual(edit.subject, "/projects/example2/a")
        XCTAssertEqual(edit.preview, "− old\n+ new")
        let indent = try call("edit", ["oldText": "  return", "newText": "    return"])
        XCTAssertEqual(indent.preview, "−   return\n+     return")
        let patch = try call("apply_patch", "*** Update File: First.swift\n" + String(repeating: "+line\n", count: 40) + "*** Delete File: Last.swift")
        XCTAssertEqual(patch.additionalPaths, ["Last.swift"])
        XCTAssertTrue(patch.searchText.contains("Last.swift"))
        let script = try call("exec", "// @exec: {}\n" + String(repeating: "example();\n", count: 1000))
        XCTAssertEqual(script.action, .script)
        XCTAssertTrue(script.preview?.hasSuffix("…") == true)
        XCTAssertFalse(script.preview?.contains("@exec") == true)
        let nested = try call("call_mcp_tool", ["ServerName": "work", "ToolName": "get_ticket", "Arguments": ["secret": "hidden"]], provider: .antigravity)
        XCTAssertEqual(nested.subject, "work / get_ticket")
        XCTAssertFalse(nested.searchText.contains("hidden"))
        var search = try call("Grep", ["pattern": "needle"])
        search.receive(output: try JSONEncoder().encode(["numMatches": 0]), isError: false)
        XCTAssertEqual(search.result, "0 matches")

        func result(_ cmd: String, _ output: String) throws -> CodingToolCall {
            var shell = try call("exec_command", ["cmd": cmd])
            shell.receive(output: try JSONEncoder().encode(output), isError: false)
            return shell
        }
        let shell = try result("swift test | tee log", "Test Suite 'All tests' passed")
        XCTAssertEqual(shell.action, .command)
        XCTAssertNil(shell.testOutcome)
        let partial = try result("swift test", "Chunk ID: abc\nWall time: 1s\nProcess exited with code 0\nOutput:\nTest Suite 'OneTest' passed")
        XCTAssertEqual(partial.result, "Exit 0")
        XCTAssertNil(partial.testOutcome)
        let success = try result("pytest -q", "===== 14 passed in 1.22s =====")
        XCTAssertEqual(success.testOutcome, "passed")
        let unmatched = try call("Bash", ["command": "swift test"])
        XCTAssertNil(unmatched.testOutcome)
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
