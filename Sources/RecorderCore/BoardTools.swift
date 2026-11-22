import Foundation

enum BoardTools {
    static let text = AgentTools.string
    static let revision = text("Opaque token for the board content currently shared with you. Read get_board on conflict.")
    static let position: [String: Any] = ["type": "integer", "minimum": 0, "maximum": 1_000_000,
        "description": "Zero-based position among peers in the destination. Defaults to the current position, or the end when moved."]
    static let referenceFields: [String: [String: Any]] = [
        "source": ["type": "string", "enum": ["call", "coding", "github"]],
        "item_id": text("Shared call_id, session_id, or GitHub item_id."),
        "anchor": text("Message, paragraph (as a string), or contribution ID."),
        "version_id": text("Transcript version ID for a call."),
        "quote": text("Optional verbatim excerpt of up to 1,500 characters from the cited evidence."),
        "label": text("Optional source label. The verified source supplies the saved title.")]
    static let references: [String: Any] = [
        "type": "array", "maxItems": 12, "description": "Replace your visible citations. Omit to preserve citations.",
        "items": ["type": "object", "additionalProperties": false, "required": ["source", "item_id"],
                  "properties": referenceFields.merging(["reference_id": text("Existing visible reference ID to retain or edit.")]) { a, _ in a }]]
    static let definitions: [[String: Any]] = {
        let axis: [String: Any] = ["type": "string", "enum": ["column", "swimlane"]]
        let placement: [String: Any] = ["column_id": text("Destination column ID."), "swimlane_id": text("Swimlane ID. Use an empty string for unassigned.")]
        let ticket = placement.merging(["title": text("Actionable ticket title."), "notes": text("Details or acceptance criteria."),
                                       "references": references, "position": position]) { a, _ in a }
        func tool(_ name: String, _ description: String, _ props: [String: Any] = [:], _ required: [String] = [],
                  write: Bool = false, deletes: Bool = false) -> [String: Any] {
            var fields = props
            if write { fields["expected_revision"] = revision }
            return AgentTools.definition(name, description, fields, required: required + (write ? ["expected_revision"] : []),
                                         readOnly: !write, scoped: false, destructive: deletes)
        }
        return [
            tool("get_board", "Read the board name, revision, ordered columns and swimlanes, and ticket count. Use list_board_tickets for cards."),
            tool("list_board_tickets", "Browse in stored order or search for related work before creating a ticket. A query ranks titles, notes and saved citations and returns a match excerpt. Cell, origin key and citation filters apply in either mode.",
                 placement.merging(["query": text("Words or a quoted phrase. Matches word beginnings and related word forms."),
                                    "origin_key": text("Exact follow-up key."),
                                    "source": ["type": "string", "enum": ["call", "coding", "github"], "description": "Cited source type. Supply item_id with source."],
                                    "item_id": text("Exact cited call, session or GitHub item ID. Supply source with item_id."),
                                    "anchor": text("Optional exact cited paragraph, message or contribution within that source."),
                                    "version_id": text("Optional exact cited version within that source."),
                                    "offset": AgentTools.paging["offset"]!, "limit": AgentTools.paging["limit"]!, "expected_revision": revision]) { a, _ in a }),
            tool("get_board_ticket", "Read a ticket with its source references and notes.", ["ticket_id": text("Ticket ID.")], ["ticket_id"]),
            tool("create_board_ticket", "Create a ticket for a user request or an action identified in shared work activity. Reuse a stable origin_key per distinct follow-up on subsequent passes. Existing keys return the original ticket unchanged.",
                 ticket.merging(["origin_key": text("Stable opaque UUID for this action.")]) { a, _ in a },
                 ["title"], write: true),
            tool("update_board_ticket", "Edit, move, or reorder a ticket. Omitted fields are preserved. Supplying references replaces only the citations you can access.",
                 ticket.merging(["ticket_id": text("Ticket ID.")]) { a, _ in a }, ["ticket_id"], write: true),
            tool("add_board_reference", "Attach verified shared evidence to a ticket. Returns its opaque reference ID.",
                 referenceFields.merging(["ticket_id": text("Ticket ID.")]) { a, _ in a }, ["ticket_id", "source", "item_id"], write: true),
            tool("remove_board_reference", "Remove one visible citation from a ticket.",
                 ["ticket_id": text("Ticket ID."), "reference_id": text("Reference ID from get_board_ticket.")], ["ticket_id", "reference_id"], write: true, deletes: true),
            tool("delete_board_ticket", "Delete one ticket.", ["ticket_id": text("Ticket ID.")], ["ticket_id"], write: true, deletes: true),
            tool("rename_board", "Change the board name.", ["name": text("Board name.")], ["name"], write: true),
            tool("create_board_group", "Add an ordered column or horizontal swimlane.", ["axis": axis, "name": text("Group name."), "position": position],
                 ["axis", "name"], write: true),
            tool("update_board_group", "Rename or reorder a column or swimlane. Tickets keep their group.", ["axis": axis, "group_id": text("Group ID."),
                 "name": text("New group name."), "position": position], ["axis", "group_id"], write: true),
            tool("delete_board_group", "Delete an empty column or swimlane. Move its tickets first. At least one column must remain.",
                 ["axis": axis, "group_id": text("Group ID.")], ["axis", "group_id"], write: true, deletes: true)
        ]
    }()
    static let names = Set(definitions.compactMap { $0["name"] as? String })

    static func call(_ name: String, _ args: [String: Any], store: TaskBoardStore, search: BoardTicketSearch, evidence: () throws -> BoardEvidenceReader, authorize: () throws -> Void) throws -> [String: Any] {
        try authorize()
        let ticketID = args["ticket_id"] as? String
        let column = args["column_id"] as? String
        let lane = args["swimlane_id"] as? String
        if ["get_board", "get_board_ticket", "list_board_tickets"].contains(name) {
            let stored = try store.read()
            let projection = try BoardProjection(stored, evidence: evidence())
            let board = projection.board
            var result: [String: Any] = ["revision": projection.token]
            switch name {
            case "get_board":
                result["name"] = board.name
                result["columns"] = try AgentJSON.object(board.columns)
                result["swimlanes"] = try AgentJSON.object(board.swimlanes)
                result["ticket_count"] = board.tickets.count
            case "get_board_ticket":
                result["ticket"] = try AgentJSON.object(board.ticket(ticketID!))
            default:
                if let expected = args["expected_revision"] as? String, expected != projection.token { throw AgentFailure("The board changed. Restart pagination.") }
                var query = BoardTicketQuery()
                query.text = args["query"] as? String ?? ""
                query.columnID = column
                query.swimlaneID = lane
                query.originKey = args["origin_key"] as? String
                if ["source", "item_id", "anchor", "version_id"].contains(where: { args[$0] != nil }) {
                    guard let source = (args["source"] as? String).flatMap(BoardReference.Source.init),
                          let item = args["item_id"] as? String, !item.isEmpty else {
                        throw AgentFailure("Supply both source and item_id to match a ticket citation.")
                    }
                    query.citation = .init(source: source, itemID: item, anchor: args["anchor"] as? String, versionID: args["version_id"] as? String)
                }
                let matches = try search.results(on: board, for: query)
                let offset = min(args["offset"] as? Int ?? 0, matches.count)
                let end = min(offset + (args["limit"] as? Int ?? 50), matches.count)
                result["total"] = matches.count
                result["items"] = try matches[offset..<end].map { hit -> [String: Any] in
                    let ticket = hit.ticket
                    var row: [String: Any] = ["id": ticket.id, "title": ticket.title, "column_id": ticket.columnID]
                    row["swimlane_id"] = ticket.swimlaneID
                    if let match = hit.match { row["match"] = try AgentJSON.object(match) }
                    if let reference = hit.sharedReference { row["matched_reference"] = try AgentJSON.object(reference) }
                    return row
                }
                if end < matches.count { result["next_offset"] = end }
            }
            let fresh = try evidence()
            try projection.recheck(stored, evidence: fresh)
            try fresh.checkCurrentAccess()
            try authorize()
            return result
        }
        var result: [String: Any] = [:]
        _ = try store.mutate { board in
            try authorize()
            let reader = try evidence()
            let original = board
            let projection = try BoardProjection(board, evidence: reader)
            guard projection.token == args["expected_revision"] as? String else {
                throw AgentFailure("The board changed. Read the latest board and retry your edit.")
            }
            let position = args["position"] as? Int
            switch name {
            case "create_board_ticket", "update_board_ticket":
                if let key = args["origin_key"] as? String, UUID(uuidString: key) == nil {
                    throw AgentFailure("Use an opaque UUID for origin_key.")
                }
                var ticket = try ticketID.map(board.ticket) ?? BoardTicket(title: "", columnID: board.columns[0].id, originKey: args["origin_key"] as? String)
                if let title = args["title"] as? String { ticket.title = title }
                if let notes = args["notes"] as? String { ticket.notes = notes }
                if let column { ticket.columnID = column }
                if let lane { ticket.swimlaneID = lane.isEmpty ? nil : lane }
                if let refs = args["references"] as? [[String: Any]] {
                    ticket.references = try projection.replacingReferences(on: ticket, with: refs, evidence: reader)
                }
                result["ticket_id"] = try board.saveTicket(ticket, position: position)
            case "add_board_reference", "remove_board_reference":
                var ticket = try board.ticket(ticketID!)
                let visible = try projection.board.ticket(ticket.id).references
                if name == "add_board_reference" {
                    guard visible.count < 12 else { throw AgentFailure("A ticket supports up to 12 shared citations at a time.") }
                    let ref = try BoardProjection.newReference(args, evidence: reader)
                    ticket.references.append(ref)
                    result["reference_id"] = ref.id
                } else {
                    let id = args["reference_id"] as! String
                    guard visible.contains(where: { $0.id == id }) else { throw BoardProjection.unavailable }
                    ticket.references.removeAll { $0.id == id }
                }
                _ = try board.saveTicket(ticket)
            case "delete_board_ticket": try board.deleteTicket(ticketID!)
            case "rename_board": try board.rename(args["name"] as! String)
            default:
                let axis = BoardAxis(rawValue: args["axis"] as! String)!
                let id = args["group_id"] as? String
                if name == "delete_board_group" { try board.deleteGroup(axis, id: id!) }
                else {
                    let groupName = args["name"] as? String ?? board.groups(axis).first { $0.id == id }?.name ?? ""
                    result["group_id"] = try board.saveGroup(axis, id: id, name: groupName, position: position)
                }
            }
            let next = try BoardProjection(board, evidence: reader)
            let fresh = try evidence()
            try projection.recheck(original, evidence: fresh)
            try next.recheck(board, evidence: fresh)
            try fresh.checkCurrentAccess()
            try authorize()
            result["revision"] = next.token
        }
        return result
    }
}
