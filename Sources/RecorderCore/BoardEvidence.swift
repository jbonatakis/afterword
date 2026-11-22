import Foundation

/// Only the immutable item identity comes from the ticket. Resolve its actual
/// title, anchor, version and excerpt against source material before sharing it.
public enum BoardEvidence {
    case call(LibraryRecording)
    case coding(CodingHistory)
    case github(GitHubItem, [GitHubPassage])

    public func verified(_ ref: BoardReference, storedSnippet: Bool = true) -> BoardReference? {
        let title: String
        var quote = ref.quote
        func matches(_ text: String) -> Bool {
            guard let saved = ref.quote else { return true }
            guard !saved.isEmpty else { return false }
            if text.contains(saved) { return true }
            guard storedSnippet else { return false }
            // Earlier native follow-ups stored formatted FTS snippets. Verify
            // every fragment in order and show an actual contiguous source excerpt.
            let snippet = ref.source == .call && ref.anchor == nil
                ? saved.replacingOccurrences(of: "Summary · ", with: "", options: .anchored) : saved
            guard snippet != saved || snippet.contains("…") else { return false }
            let parts = snippet.components(separatedBy: "…").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var next = text.startIndex
            for part in parts {
                guard let range = text.range(of: part, options: .literal, range: next..<text.endIndex) else { return false }
                next = range.upperBound
            }
            guard let verified = parts.max(by: { $0.count < $1.count }) else { return false }
            quote = verified
            return true
        }
        switch self {
        case .call(let recording):
            title = recording.name
            let version: LibraryTranscript?
            if let id = ref.versionID {
                guard let found = recording.transcripts.first(where: { $0.agentVersionID(callID: ref.itemID) == id }),
                      found.document != nil else { return nil }
                version = found
            } else { version = recording.latestTranscript }
            let paragraphs = version?.document?.paragraphs ?? []
            if let anchor = ref.anchor {
                guard paragraphs.contains(where: { String($0.id) == anchor && matches($0.text) }) else { return nil }
            } else if ref.quote != nil {
                guard paragraphs.contains(where: { matches($0.text) }) ||
                        (ref.versionID == nil && recording.summary?.current.map { matches($0.markdown) } == true) else { return nil }
            }
        case .coding(let history):
            title = history.session.title
            guard ref.versionID == nil else { return nil }
            if ref.anchor != nil || ref.quote != nil {
                guard history.messages.contains(where: { (ref.anchor == nil || $0.id == ref.anchor) && matches($0.text) }) else { return nil }
            }
        case .github(let item, let passages):
            title = item.title
            guard ref.versionID == nil else { return nil }
            if ref.anchor != nil || ref.quote != nil {
                guard passages.contains(where: { (ref.anchor == nil || $0.id == ref.anchor) && matches($0.text) }) else { return nil }
            }
        }
        var result = ref
        result.label = String(title.prefix(240))
        result.quote = quote
        return result
    }
}

/// Short-lived cache scoped to one authorization pass, including failed lookups.
/// Source failures hide only that evidence. They never disable unrelated board work.
final class BoardEvidenceReader {
    let access: AgentEvidenceAccess
    init(directory: URL) throws { access = try AgentEvidenceAccess(directory: directory) }
    private lazy var github = try? access.sharedGitHub()
    private lazy var githubRevision = try? github?.revision(shared: true)
    private lazy var coding = access.codingAllowed ? try? CodingArchive(directory: access.codingDirectory) : nil
    private lazy var codingRevision = try? coding?.revision
    private var sharedGitHub = false
    private var sharedCoding = false
    private var sharedCalls: [String: LibraryRecording] = [:]
    private lazy var work = calls(.work)
    private lazy var personal = calls(.personal)
    private var items: [BoardReference.Source: [String: BoardEvidence?]] = [:]

    private func calls(_ scope: CallScope) -> [String: LibraryRecording] {
        guard access.permitsCalls(scope), !access.folders.isEmpty,
              let index = try? access.recordingIndex(scope: scope),
              (try? index.synchronize(prepareSemanticSearch: false)) != nil else { return [:] }
        return Dictionary(uniqueKeysWithValues: index.calls.map { ($0.id, $0.recording) })
    }

    func verified(_ ref: BoardReference, storedSnippet: Bool = true) -> BoardReference? {
        let item: BoardEvidence?
        if let cached = items[ref.source]?[ref.itemID] { item = cached }
        else {
            item = load(ref)
            items[ref.source, default: [:]].updateValue(item, forKey: ref.itemID)
        }
        guard let item, let verified = item.verified(ref, storedSnippet: storedSnippet) else { return nil }
        switch item {
        case .github: sharedGitHub = true
        case .coding: sharedCoding = true
        case .call(let call): sharedCalls[ref.itemID] = call
        }
        return verified
    }

    private func load(_ ref: BoardReference) -> BoardEvidence? {
        switch ref.source {
        case .call:
            return (work[ref.itemID] ?? personal[ref.itemID]).map(BoardEvidence.call)
        case .coding:
            guard codingRevision != nil, let history = try? coding?.history(id: ref.itemID) else { return nil }
            return .coding(history)
        case .github:
            if githubRevision != nil, let github, let hit = try? github.search(shared: true, itemID: ref.itemID).first,
               let timeline = try? github.timeline(ref.itemID, shared: true) {
                return .github(hit.item, timeline)
            }
            return nil
        }
    }

    func checkCurrentAccess() throws {
        guard try AgentEvidenceAccess(directory: access.directory) == access,
              try !sharedGitHub || github?.revision(shared: true) == githubRevision,
              try !sharedCoding || coding?.revision == codingRevision else {
            throw AgentFailure("Shared activity changed. Retry the board request.")
        }
        if !sharedCalls.isEmpty {
            let roots = try access.recordingRoots()
            for (id, call) in sharedCalls {
                guard roots.contains(where: { CallFileOperations.contains($0, call.url) }),
                      (try? AgentJSON.identity(call.url)) == id,
                      (try? CallDetailsStore.load(for: call.url, isDirectory: call.isDirectory).scope) == call.details.scope else {
                    throw AgentFailure("Shared activity changed. Retry the board request.")
                }
            }
        }
    }

    static func shared(_ ref: BoardReference, directory: URL) -> Bool {
        guard let reader = try? BoardEvidenceReader(directory: directory),
              reader.access.grants.allowBoardManagement, reader.access.sources.contains(.board) else { return false }
        return reader.verified(ref) != nil && (try? reader.checkCurrentAccess()) != nil
    }
}

extension BoardReference {
    /// Search can insert ellipses between fragments. Save an actual source substring.
    public static func excerpt(in text: String, near snippet: String?) -> String? {
        guard !text.isEmpty else { return nil }
        if let snippet, !snippet.isEmpty {
            if text.contains(snippet) { return String(snippet.prefix(1500)) }
            let fragments = snippet.components(separatedBy: "…").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let match = fragments.filter({ !$0.isEmpty && text.contains($0) }).max(by: { $0.count < $1.count }) {
                return String(match.prefix(1500))
            }
        }
        return String(text.prefix(1500))
    }

    public func isSharedWithAgents(in directory: URL) -> Bool { BoardEvidenceReader.shared(self, directory: directory) }
}
