import Foundation

struct BoardProjection {
    let board: TaskBoard
    let token: String
    static var unavailable: AgentFailure { AgentFailure("Citation unavailable.") }

    init(_ stored: TaskBoard, evidence: BoardEvidenceReader) throws {
        board = stored.projecting { evidence.verified($0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        token = AgentJSON.hash(try encoder.encode(board))
    }

    func recheck(_ stored: TaskBoard, evidence: BoardEvidenceReader) throws {
        guard board == stored.projecting({ evidence.verified($0) }) else {
            throw AgentFailure("The shared board changed. Read it again and retry.")
        }
    }

    static func newReference(_ fields: [String: Any], evidence: BoardEvidenceReader) throws -> BoardReference {
        guard let source = (fields["source"] as? String).flatMap(BoardReference.Source.init), let item = fields["item_id"] as? String else {
            throw unavailable
        }
        let requested = BoardReference(source: source, itemID: item, anchor: fields["anchor"] as? String,
                                      label: "", quote: fields["quote"] as? String, versionID: fields["version_id"] as? String)
        guard let verified = evidence.verified(requested, storedSnippet: false) else { throw unavailable }
        return verified
    }

    func replacingReferences(on ticket: BoardTicket, with fields: [[String: Any]], evidence: BoardEvidenceReader) throws -> [BoardReference] {
        let visible = board.tickets.first { $0.id == ticket.id }?.references ?? []
        var unused = visible
        var replacements: [BoardReference] = []
        for entry in fields {
            var ref = try Self.newReference(entry, evidence: evidence)
            if let id = entry["reference_id"] as? String {
                guard let index = unused.firstIndex(where: { $0.id == id }) else { throw Self.unavailable }
                ref.id = unused.remove(at: index).id
            } else if let index = unused.firstIndex(where: {
                $0.source == ref.source && $0.itemID == ref.itemID && $0.anchor == ref.anchor &&
                    $0.versionID == ref.versionID && $0.quote == ref.quote
            }) {
                ref.id = unused.remove(at: index).id
            }
            // A returned label may have been refreshed from the source. Round-tripping
            // an unchanged citation should preserve its original local snapshot.
            if visible.contains(ref), let original = ticket.references.first(where: { $0.id == ref.id }) {
                replacements.append(original)
            } else { replacements.append(ref) }
        }
        let visibleIDs = Set(visible.compactMap(\.id))
        var ordered = replacements.makeIterator()
        var merged = ticket.references.compactMap { ref in
            ref.id.map(visibleIDs.contains) == true ? ordered.next() : ref
        }
        while let ref = ordered.next() { merged.append(ref) }
        return merged
    }
}
