#if canImport(XCTest)
import XCTest
#endif
import Foundation
@testable import RecorderCore

final class TaskBoardTests: XCTestCase {
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var library: AgentLibrary { AgentLibrary(directory: state) }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: state) }

    func grant(_ allow: Bool = true) throws {
        var config = AgentAccessConfiguration(enabled: true)
        config.allowBoardManagement = allow
        try AgentAccessStore.save(config, directory: state)
    }

    func revision() throws -> String { try XCTUnwrap(library.call("get_board", arguments: [:])["revision"] as? String) }

    func sharedSource() throws -> (BoardReference, GitHubArchive) {
        try ActivitySourceStore.save([.board, .github], directory: state)
        let db = try GitHubArchive(directory: state.appendingPathComponent("GitHub"))
        try db.connect(.init(id: "author", login: "tester"))
        try db.select(.init(id: "repo", name: "sample/board"))
        let repo = try XCTUnwrap(db.selections().first)
        try db.begin(repo, now: Date())
        let item = GitHubItem(id: "meeting", repositoryID: repo.id, type: "pr", title: "Planning café", author: "tester", state: "OPEN", url: "https://example.org/1", number: 1)
        let passage = GitHubPassage(id: "5", actorID: "author", text: "Retry the failed delivery.", url: item.url, kind: .comment,
                                    date: Date(), edited: nil, verdict: nil, path: nil, line: nil)
        var page = GitHubPage()
        page.entries = [(item, passage)]
        try db.commit(page, work: XCTUnwrap(db.next(repo)), repo: repo)
        try db.share(repo.id, enabled: true)
        return (BoardReference(source: .github, itemID: item.id, anchor: passage.id, label: item.title, quote: passage.text), db)
    }

    func testDiscoveryRevocationAndPersistence() throws {
        let rpc = AgentRPCServer(directory: state)
        func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
            let data = try AgentJSON.data(["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            return try JSONSerialization.jsonObject(with: XCTUnwrap(rpc.handle(data))) as! [String: Any]
        }
        _ = try request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        _ = rpc.handle(try AgentJSON.data(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        func names() throws -> Set<String> {
            let result = try XCTUnwrap(request("tools/list")["result"] as? [String: Any])
            return Set((result["tools"] as! [[String: Any]]).compactMap { $0["name"] as? String })
        }
        let initial = try names()
        try grant()
        XCTAssertEqual(try names(), initial)
        XCTAssertThrowsError(try library.call("get_board", arguments: [:]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("Board").path))
        try ActivitySourceStore.save([.coding, .board], directory: state)
        // A stable build sharing these settings still sees its original source keys.
        let raw = try Data(contentsOf: state.appendingPathComponent("Sources.json"))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: raw), ["coding"])
        XCTAssertTrue(rpc.toolsChangedNotification() != nil)
        XCTAssertEqual(try names().subtracting(initial), BoardTools.names)
        _ = try library.call("create_board_ticket", arguments: ["title": "Retain me", "expected_revision": try revision()])
        try grant(false)
        XCTAssertTrue(rpc.toolsChangedNotification() != nil)
        XCTAssertEqual(try names(), initial)
        try grant()
        try ActivitySourceStore.save([.coding], directory: state)
        XCTAssertEqual(try names(), initial)
        XCTAssertTrue(try request("tools/call", ["name": "delete_board_ticket", "arguments": [:]])["error"] != nil)
        XCTAssertThrowsError(try library.call("create_board_ticket", arguments: ["title": "Hidden", "expected_revision": try revision()]))
        try ActivitySourceStore.save([.board], directory: state)
        XCTAssertEqual(try library.call("get_board", arguments: [:])["ticket_count"] as? Int, 1)
        var config = try AgentAccessStore.load(directory: state)
        config.enabled = false
        try AgentAccessStore.save(config, directory: state)
        XCTAssertEqual(try names(), initial)
        XCTAssertThrowsError(try library.call("get_board", arguments: [:]))
    }

    func testSavingTicketDuringAgentEdits() throws {
        try ActivitySourceStore.save([.board], directory: state)
        try grant()
        let store = TaskBoardStore(stateDirectory: state)
        let (shared, _) = try sharedSource()
        let original = BoardTicket(title: "Release", notes: "Initial notes", columnID: "todo")
        _ = try store.save(original, original: nil)
        var draft = original
        draft.notes = "Use the signed build."
        _ = try library.call("update_board_ticket", arguments: ["expected_revision": try revision(), "ticket_id": original.id, "column_id": "done",
            "references": [["source": "github", "item_id": shared.itemID, "label": shared.label]]])
        let saved = try store.save(draft, original: original).ticket(original.id)
        XCTAssertEqual(saved.notes, draft.notes)
        XCTAssertEqual(saved.columnID, "done")
        XCTAssertEqual(saved.references.first?.itemID, shared.itemID)
        XCTAssertEqual(try store.save(draft, original: original).revision, 3)

        var local = saved
        local.title = "Prepare release"
        local.notes = "My notes"
        _ = try library.call("update_board_ticket", arguments: ["expected_revision": try revision(), "ticket_id": saved.id,
            "title": "Ship release", "notes": "Agent notes"])
        let before = try store.read()
        var collision: BoardTicketConflict?
        do { _ = try store.save(local, original: saved) } catch let conflict as BoardTicketConflict { collision = conflict }
        let conflict = try XCTUnwrap(collision)
        XCTAssertEqual(conflict.fields, [.title, .notes])
        XCTAssertEqual(conflict.latest.notes, "Agent notes")
        XCTAssertEqual(conflict.draft.notes, "My notes")
        XCTAssertEqual(try store.read(), before)

        var resolution = conflict.draft
        BoardTicketField.title.copy(from: conflict.latest, to: &resolution)
        _ = try library.call("update_board_ticket", arguments: ["expected_revision": try revision(), "ticket_id": saved.id, "column_id": "in-progress"])
        let resolved = try store.save(resolution, original: conflict.latest)
        let ticket = try resolved.ticket(saved.id)
        XCTAssertEqual(ticket.title, "Ship release")
        XCTAssertEqual(ticket.notes, "My notes")
        XCTAssertEqual(ticket.columnID, "in-progress")
        _ = try store.change(expectedRevision: resolved.revision) { try $0.deleteTicket(ticket.id) }
        XCTAssertThrowsError(try store.save(resolution, original: conflict.latest))
        XCTAssertTrue(try store.read().tickets.isEmpty)
    }

    func testRankedTicketSearchAndCitationFilters() throws {
        try grant()
        try ActivitySourceStore.save([.board], directory: state)
        let agent = library
        let store = TaskBoardStore(stateDirectory: state)
        let (source, _) = try sharedSource()
        let key = UUID().uuidString
        let other = BoardReference(source: .coding, itemID: "meeting", anchor: "5", label: "Another session")
        let notes = String(repeating: "Earlier context. ", count: 80) + "Retry delivery with a backoff."
        let one = BoardTicket(title: "Delivery checklist", notes: notes, columnID: "todo", references: [source])
        let two = BoardTicket(title: "Retry delivery", columnID: "done", references: [other], originKey: key)
        let three = BoardTicket(title: "Review alerts", columnID: "todo", references: [source])
        let four = BoardTicket(title: "Renew certificate", columnID: "todo")
        _ = try store.change(expectedRevision: 0) { board in
            for ticket in [one, two, three, four] { _ = try board.saveTicket(ticket) }
        }

        func page(_ args: [String: Any]) throws -> [[String: Any]] {
            try XCTUnwrap(agent.call("list_board_tickets", arguments: args)["items"] as? [[String: Any]])
        }
        func ids(_ args: [String: Any]) throws -> [String] { try page(args).compactMap { $0["id"] as? String } }
        let browse = try page(["query": "  "])
        XCTAssertEqual(browse.compactMap { $0["id"] as? String }, [one.id, two.id, three.id, four.id])
        XCTAssertNil(browse.first?["match"])
        let ranked = try page(["query": "retry delivery"])
        XCTAssertEqual(ranked.first?["id"] as? String, two.id)
        XCTAssertEqual((ranked.first?["match"] as? [String: String])?["field"], "title")
        let noteMatch = try XCTUnwrap(page(["query": "backoff"]).first?["match"] as? [String: String])
        XCTAssertEqual(noteMatch["field"], "notes")
        XCTAssertTrue(noteMatch["excerpt"]?.contains("backoff") == true)
        let cited = try page(["query": "planning cafe"])
        XCTAssertEqual(cited.count, 2)
        XCTAssertEqual((cited.first?["match"] as? [String: String])?["field"], "citation")
        XCTAssertEqual(try ids(["query": "delivering retry"]), ranked.compactMap { $0["id"] as? String })
        XCTAssertTrue(try ids(["query": "retry outbound delivery"]).contains(two.id))
        XCTAssertTrue(try ids(["query": "ret", "column_id": "done"]).contains(two.id))
        XCTAssertEqual(try ids(["query": "ew ce"]), [four.id])
        XCTAssertTrue(try ids(["query": "unrelated"]).isEmpty)
        let scope = ["source": "github", "item_id": "meeting", "anchor": "5"]
        XCTAssertEqual(try ids(scope), [one.id, three.id])
        XCTAssertEqual(try page(scope).first?["matched_reference"].flatMap { ($0 as? [String: Any])?["label"] as? String }, source.label)
        XCTAssertEqual(try ids(["query": "backoff", "source": "github", "item_id": "meeting", "swimlane_id": ""]), [one.id])
        XCTAssertEqual(try ids(["query": "delivery", "origin_key": key]), [two.id])
        XCTAssertTrue(try ids(["source": "github", "item_id": "meeting", "version_id": "v2"]).isEmpty)
        XCTAssertThrowsError(try page(["item_id": "meeting"]))
        XCTAssertThrowsError(try page(["anchor": "5"]))
        let first = try agent.call("list_board_tickets", arguments: ["query": "planning cafe", "limit": 1])
        XCTAssertEqual(first["next_offset"] as? Int, 1)
        let firstIDs = try XCTUnwrap(first["items"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        let rest = try ids(["query": "planning cafe", "expected_revision": first["revision"]!, "offset": 1])
        XCTAssertEqual(firstIDs + rest, cited.compactMap { $0["id"] as? String })
        _ = try store.change(expectedRevision: 1) { try $0.deleteTicket(three.id) }
        XCTAssertThrowsError(try page(["query": "planning cafe", "expected_revision": first["revision"]!, "offset": 1]))
        XCTAssertEqual(try ids(["query": "planning cafe"]), [one.id])
        try grant(false)
        XCTAssertThrowsError(try page(["query": "planning cafe"]))
    }

    func testHiddenCitationsHaveNoObservableEffectOnReadsSearchOrEdits() throws {
        try grant()
        let (shared, db) = try sharedSource()
        let agent = library
        let store = TaskBoardStore(stateDirectory: state)
        let ticket = BoardTicket(title: "Review delivery", notes: "Shared notes", columnID: "todo", references: [shared])
        _ = try store.save(ticket, original: nil)
        _ = try store.save(BoardTicket(title: "Delivery planning", columnID: "todo"), original: nil)
        let secret = BoardReference(source: .coding, itemID: "private-session", anchor: "message", label: "Private label", quote: "secret delivery backoff")
        func read(_ tool: String, _ args: [String: Any] = [:]) throws -> Data {
            try AgentJSON.data(agent.call(tool, arguments: args))
        }
        func observed() throws -> [Data] {
            try [read("get_board"), read("get_board_ticket", ["ticket_id": ticket.id]), read("list_board_tickets"),
                 read("list_board_tickets", ["query": "delivery"]), read("list_board_tickets", ["query": "private label"]),
                 read("list_board_tickets", ["query": "backoff"]), read("list_board_tickets", ["source": "coding", "item_id": secret.itemID]),
                 read("list_board_tickets", ["source": "github", "item_id": shared.itemID])]
        }
        let baseline = try observed()
        let token = try revision()
        var native = ticket
        native.references.insert(secret, at: 0)
        _ = try store.change(expectedRevision: 2) { try $0.saveTicket(native) }
        XCTAssertEqual(try observed(), baseline)
        var changed = secret
        changed.quote = "An entirely different private quotation"
        native.references[0] = changed
        _ = try store.change(expectedRevision: 3) { try $0.saveTicket(native) }
        XCTAssertEqual(try revision(), token)
        // A write based on the earlier projection merges under the lock with the latest private snapshot.
        let updated = try agent.call("update_board_ticket", arguments: ["ticket_id": ticket.id, "title": "New title", "column_id": "done", "expected_revision": token])
        XCTAssertEqual(try store.read().ticket(ticket.id).references, [changed, shared])
        XCTAssertNotEqual(updated["revision"] as? String, token)
        XCTAssertThrowsError(try agent.call("remove_board_reference", arguments: ["ticket_id": ticket.id, "reference_id": shared.id!, "expected_revision": token]))
        func write(_ tool: String, _ args: [String: Any]) throws -> [String: Any] {
            try agent.call(tool, arguments: args.merging(["ticket_id": ticket.id, "expected_revision": try revision()]) { _, new in new })
        }
        func errorMessage(_ tool: String, _ args: [String: Any]) -> String? {
            do { _ = try write(tool, args); return nil } catch { return error.localizedDescription }
        }
        let invalidID = UUID().uuidString
        let fields = ["source": "github", "item_id": shared.itemID, "anchor": "5", "quote": "Retry", "label": "Invented title"]
        for id in [changed.id!, invalidID] {
            XCTAssertEqual(errorMessage("remove_board_reference", ["reference_id": id]), "Citation unavailable.")
            XCTAssertEqual(errorMessage("update_board_ticket", ["references": [fields.merging(["reference_id": id]) { _, new in new }]]), "Citation unavailable.")
        }
        for invalid in [["source": "coding", "item_id": secret.itemID], ["source": "github", "item_id": "missing"],
                        fields.merging(["quote": "fabricated"]) { _, new in new }, fields.merging(["anchor": "missing"]) { _, new in new },
                        fields.merging(["version_id": "injected"]) { _, new in new }] {
            XCTAssertEqual(errorMessage("add_board_reference", invalid), "Citation unavailable.")
        }
        _ = try write("update_board_ticket", ["references": []])
        XCTAssertEqual(try store.read().ticket(ticket.id).references, [changed])
        let added = try XCTUnwrap(write("add_board_reference", fields)["reference_id"] as? String)
        let refs = try store.read().ticket(ticket.id).references
        XCTAssertEqual(refs.first, changed)
        XCTAssertEqual(refs.last?.label, shared.label)
        XCTAssertEqual(refs.last?.id, added)
        let bytes = try Data(contentsOf: state.appendingPathComponent("Board/Board.json"))
        let visible = try observed()
        try db.share("repo", enabled: false)
        let privateView = try agent.call("get_board_ticket", arguments: ["ticket_id": ticket.id])
        XCTAssertTrue(((privateView["ticket"] as? [String: Any])?["references"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertEqual(try agent.call("list_board_tickets", arguments: ["query": "Planning café"])["total"] as? Int, 0)
        XCTAssertEqual(errorMessage("remove_board_reference", ["reference_id": added]), "Citation unavailable.")
        try db.share("repo", enabled: true)
        XCTAssertEqual(try observed(), visible)
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("Board/Board.json")), bytes)
        _ = try write("remove_board_reference", ["reference_id": added])
        XCTAssertEqual(try store.read().ticket(ticket.id).references, [changed])
        // The limit applies to the visible set. Hidden citations cannot consume visible slots.
        _ = try write("update_board_ticket", ["references": Array(repeating: fields, count: 12)])
        XCTAssertEqual(try store.read().ticket(ticket.id).references.count, 13)
        XCTAssertEqual(try store.read().ticket(ticket.id).references.first, changed)
    }

    func testAgentEditWhileAnotherProcessChangesAHiddenCitation() throws {
        try grant()
        let (source, archive) = try sharedSource()
        try archive.share("repo", enabled: false)
        let store = TaskBoardStore(stateDirectory: state)
        let ticket = BoardTicket(title: "Review", columnID: "todo")
        var snapshot = try store.save(ticket, original: nil)
        let agent = try BoardMCPClient(directory: state)
        defer { agent.close() }
        let lookup = ["ticket_id": ticket.id]
        let noCitation = try agent.call("get_board_ticket", lookup)
        var citation = source
        snapshot = try store.change(expectedRevision: snapshot.revision) { board in
            var local = try board.ticket(ticket.id)
            local.references = [citation]
            try board.saveTicket(local)
        }
        XCTAssertEqual(try AgentJSON.data(agent.call("get_board_ticket", lookup)), try AgentJSON.data(noCitation))

        // Cover both an ordinary edit and a client sending back its entire visible reference list.
        for (index, quote) in ["failed delivery", "Retry the failed"].enumerated() {
            let before = try agent.call("get_board_ticket", lookup)
            let token = try XCTUnwrap(before["revision"] as? String)
            let title = "Review \(index + 1)"
            var edit: [String: Any] = ["ticket_id": ticket.id, "expected_revision": token, "title": title, "column_id": "done"]
            if index == 1 { edit["references"] = [] as [[String: Any]] }

            citation.quote = quote
            let previousRevision = snapshot.revision
            var request = 0
            _ = try store.change(expectedRevision: previousRevision) { board in
                var local = try board.ticket(ticket.id)
                local.references = [citation]
                try board.saveTicket(local)
                // This transaction still owns the native lock. Release it only once the
                // MCP child has opened that exact lock for the outstanding tool call.
                request = try agent.sendTool("update_board_ticket", edit)
                try agent.waitForWriterLock(in: state)
            }
            let write = try agent.toolResult(request)
            let newToken = try XCTUnwrap(write["revision"] as? String)
            XCTAssertNotEqual(newToken, token)
            XCTAssertEqual(Set(write.keys), ["revision", "ticket_id"])
            XCTAssertEqual(write["ticket_id"] as? String, ticket.id)
            let after = try agent.call("get_board_ticket", lookup)
            var expected = try XCTUnwrap(noCitation["ticket"] as? [String: Any])
            expected["title"] = title
            expected["column_id"] = "done"
            XCTAssertEqual(try AgentJSON.data(after), try AgentJSON.data(["ticket": expected, "revision": newToken]))
            for arguments in [["query": quote], ["source": "github", "item_id": source.itemID]] {
                let search = try agent.call("list_board_tickets", arguments)
                XCTAssertEqual(search["total"] as? Int, 0)
                XCTAssertEqual((search["items"] as? [[String: Any]])?.count, 0)
            }

            snapshot = try store.read()
            let saved = try snapshot.ticket(ticket.id)
            XCTAssertEqual(snapshot.revision, previousRevision + 2)
            XCTAssertEqual(saved.title, title)
            XCTAssertEqual(saved.columnID, "done")
            XCTAssertEqual(saved.references, [citation])
        }
        try archive.share("repo", enabled: true)
        let restored = try XCTUnwrap(agent.call("get_board_ticket", lookup)["ticket"] as? [String: Any])
        XCTAssertEqual(try AgentJSON.data(XCTUnwrap(restored["references"])), try AgentJSON.data(AgentJSON.object([citation])))
    }

    func testLegacyBoardUpgradePreservesEvidenceAndOpaqueIDsAcrossReaders() throws {
        try grant()
        let (ref, _) = try sharedSource()
        let store = TaskBoardStore(stateDirectory: state)
        let ticket = BoardTicket(title: "Legacy", columnID: "todo", references: [ref], originKey: "private-session:private-message")
        let original = try store.save(ticket, original: nil)
        var bare = try XCTUnwrap(AgentJSON.object(original) as? [String: Any])
        var row = try XCTUnwrap((bare["tickets"] as? [[String: Any]])?.first)
        var citation = try XCTUnwrap((row["references"] as? [[String: Any]])?.first)
        citation.removeValue(forKey: "reference_id")
        row["references"] = [citation]; bare["tickets"] = [row]
        let file = state.appendingPathComponent("Board/Board.json")
        try ActivitySourceStore.save([.github], directory: state)
        try PrivateFiles.atomicWrite(AgentJSON.data(bare), to: file)
        try ActivitySourceStore.save([.github, .board], directory: state)
        XCTAssertThrowsError(try JSONDecoder().decode(TaskBoard.self, from: Data(contentsOf: file)))
        let migrated = try store.read()
        let first = try XCTUnwrap(migrated.ticket(ticket.id).references.first)
        XCTAssertTrue(first.id.flatMap(UUID.init(uuidString:)) != nil)
        XCTAssertEqual(first.quote, ref.quote)
        XCTAssertEqual(migrated.revision, original.revision)
        XCTAssertEqual(try TaskBoardStore(stateDirectory: state).read(), migrated)
        let agentTicket = try XCTUnwrap(library.call("get_board_ticket", arguments: ["ticket_id": ticket.id])["ticket"] as? [String: Any])
        XCTAssertNil(agentTicket["origin_key"])
        XCTAssertEqual(try library.call("list_board_tickets", arguments: ["origin_key": ticket.originKey!])["total"] as? Int, 0)
    }

    func testLegacySearchExcerptMustStillBeBackedByTheSource() throws {
        try grant()
        let (ref, _) = try sharedSource()
        let store = TaskBoardStore(stateDirectory: state)
        var snippet = ref, forged = ref
        snippet.quote = "Retry…delivery"
        forged.quote = "Private marker…delivery"
        let ticket = BoardTicket(title: "Follow up", columnID: "todo", references: [snippet, forged])
        _ = try store.save(ticket, original: nil)
        let row = try XCTUnwrap(library.call("get_board_ticket", arguments: ["ticket_id": ticket.id])["ticket"] as? [String: Any])
        let references = try XCTUnwrap(row["references"] as? [[String: Any]])
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?["quote"] as? String, "delivery")
        XCTAssertThrowsError(try library.call("add_board_reference", arguments: ["ticket_id": ticket.id, "source": "github", "item_id": ref.itemID,
            "anchor": "5", "quote": "Retry…delivery", "expected_revision": try revision()]))
    }

    func testRevocationDuringReferenceRemovalAbortsTheLockedWrite() throws {
        try grant()
        let (ref, db) = try sharedSource()
        let store = TaskBoardStore(stateDirectory: state)
        let ticket = BoardTicket(title: "Review", columnID: "todo", references: [ref])
        let saved = try store.save(ticket, original: nil)
        var passes = 0
        let args: [String: Any] = ["expected_revision": try revision(), "ticket_id": ticket.id, "reference_id": ref.id!]
        XCTAssertThrowsError(try BoardTools.call("remove_board_reference", args, store: store, search: BoardTicketSearch(), evidence: {
            passes += 1
            if passes == 2 { try db.share("repo", enabled: false) }
            return try BoardEvidenceReader(directory: self.state)
        }, authorize: {}))
        XCTAssertEqual(passes, 2)
        XCTAssertEqual(try store.read(), saved)
        XCTAssertEqual(BoardReference.excerpt(in: "Discuss the rollout plan tomorrow.", near: "…rollout plan…"), "rollout plan")
    }

    func testTicketAndGroupLifecycle() throws {
        try grant()
        try ActivitySourceStore.save([.board], directory: state)
        let agent = library
        _ = try sharedSource()
        var rev = try revision()
        func write(_ name: String, _ fields: [String: Any]) throws -> [String: Any] {
            let result = try agent.call(name, arguments: fields.merging(["expected_revision": rev]) { _, new in new })
            rev = try XCTUnwrap(result["revision"] as? String)
            return result
        }
        _ = try write("rename_board", ["name": "Release"])
        let lane = try XCTUnwrap(write("create_board_group", ["axis": "swimlane", "name": "Client"])["group_id"] as? String)
        let column = try XCTUnwrap(write("create_board_group", ["axis": "column", "name": "Review", "position": 1])["group_id"] as? String)
        let refs = [["source": "github", "item_id": "meeting", "anchor": "5", "quote": "Retry"]]
        let fields: [String: Any] = ["title": "Fix build", "references": refs, "origin_key": UUID().uuidString]
        let ticket = try XCTUnwrap(write("create_board_ticket", fields)["ticket_id"] as? String)
        let firstRevision = rev
        XCTAssertEqual(try write("create_board_ticket", fields)["ticket_id"] as? String, ticket)
        XCTAssertEqual(rev, firstRevision)
        _ = try write("update_board_ticket", ["ticket_id": ticket, "column_id": column, "swimlane_id": lane, "notes": "Review output"])
        let store = TaskBoardStore(stateDirectory: state)
        XCTAssertEqual(try store.read().ticket(ticket).references.first?.anchor, "5")
        XCTAssertThrowsError(try agent.call("delete_board_ticket", arguments: ["ticket_id": ticket, "expected_revision": firstRevision]))
        XCTAssertThrowsError(try write("delete_board_group", ["axis": "column", "group_id": column]))
        XCTAssertThrowsError(try write("delete_board_group", ["axis": "swimlane", "group_id": lane]))
        _ = try write("update_board_group", ["axis": "column", "group_id": column, "name": "QA", "position": 0])
        _ = try write("update_board_group", ["axis": "swimlane", "group_id": lane, "name": "Mobile"])
        XCTAssertEqual(try store.read().columns.first?.name, "QA")
        let second = try XCTUnwrap(write("create_board_ticket", ["column_id": column, "swimlane_id": lane, "title": "Second", "position": 0])["ticket_id"] as? String)
        let page = try agent.call("list_board_tickets", arguments: ["column_id": column, "swimlane_id": lane, "limit": 1])
        XCTAssertEqual((page["items"] as? [[String: String]])?.first?["id"], second)
        XCTAssertEqual(page["next_offset"] as? Int, 1)
        let info = try agent.call("get_board_ticket", arguments: ["ticket_id": ticket])
        XCTAssertEqual((info["ticket"] as? [String: Any])?["notes"] as? String, "Review output")
        XCTAssertThrowsError(try write("update_board_ticket", ["ticket_id": ticket, "references": [["source": "bad", "label": "x", "item_id": "y"]]]))
        XCTAssertThrowsError(try write("update_board_ticket", ["ticket_id": ticket, "column_id": "missing"]))
        XCTAssertThrowsError(try write("update_board_ticket", ["ticket_id": ticket, "position": 20]))
        _ = try write("update_board_ticket", ["ticket_id": ticket, "column_id": "done", "swimlane_id": "", "references": []])
        _ = try write("delete_board_ticket", ["ticket_id": second])
        _ = try write("delete_board_group", ["axis": "column", "group_id": column])
        _ = try write("delete_board_group", ["axis": "swimlane", "group_id": lane])
        XCTAssertNil(try store.read().ticket(ticket).swimlaneID)
        XCTAssertEqual(try store.read().ticket(ticket).references.count, 0)
    }
}

/// Keep one real stdio helper alive across reads, grant changes and contended writes.
/// Responses go to a fixture file so a missing response has a deadline instead of blocking the suite.
private final class BoardMCPClient {
    private let helper = Process()
    private let input = Pipe()
    private let output: URL
    private var nextID = 1

    init(directory: URL) throws {
        let products = Bundle(for: TaskBoardTests.self).bundleURL.deletingLastPathComponent()
        let executable = ProcessInfo.processInfo.environment["AFTERWORD_TEST_MCP"].map { URL(fileURLWithPath: $0) }
        helper.executableURL = executable ?? products.appendingPathComponent("AfterwordMCP")
        helper.arguments = ["--state-directory", directory.path]
        helper.standardInput = input
        output = directory.appendingPathComponent("mcp-responses.jsonl")
        try Data().write(to: output)
        let log = try FileHandle(forWritingTo: output)
        defer { try? log.close() }
        helper.standardOutput = log
        try helper.run()
        do {
            let id = try send("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "board-race-test", "version": "1"]])
            _ = try response(id)
            try input.fileHandleForWriting.write(contentsOf: AgentJSON.data(["jsonrpc": "2.0", "method": "notifications/initialized"]) + Data([10]))
        } catch { close(); throw error }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if helper.isRunning { helper.terminate() }
        helper.waitUntilExit()
    }

    private func send(_ method: String, _ params: [String: Any]) throws -> Int {
        let id = nextID
        nextID += 1
        let data = try AgentJSON.data(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
        return id
    }

    private func response(_ id: Int) throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(10)
        while helper.isRunning && ContinuousClock.now < deadline {
            let bytes = try Data(contentsOf: output)
            // Ignore an incomplete last line while the child is writing.
            for line in bytes.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
                let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                if envelope["id"] as? Int == id { return try XCTUnwrap(envelope["result"] as? [String: Any]) }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw AgentFailure("No MCP response to fixture request \(id).")
    }

    func sendTool(_ name: String, _ arguments: [String: Any]) throws -> Int {
        try send("tools/call", ["name": name, "arguments": arguments])
    }

    func toolResult(_ id: Int) throws -> [String: Any] {
        let result = try response(id)
        guard result["isError"] as? Bool == false else { throw AgentFailure("Fixture tool call failed: \(result)") }
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: String]])
        XCTAssertEqual(content.count, 1)
        let text = try XCTUnwrap(content.first?["text"])
        XCTAssertEqual(try AgentJSON.data(JSONSerialization.jsonObject(with: Data(text.utf8))), try AgentJSON.data(structured))
        return structured
    }

    func call(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        try toolResult(sendTool(name, arguments))
    }

    func waitForWriterLock(in directory: URL) throws {
        let lock = directory.appendingPathComponent("Board/.lock")
        let deadline = ContinuousClock.now + .seconds(10)
        while helper.isRunning && ContinuousClock.now < deadline {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            probe.arguments = ["-nP", "-a", "-p", String(helper.processIdentifier), "--", lock.path]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus == 0 { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw AgentFailure("The MCP helper never reached the native writer's board lock.")
    }
}
