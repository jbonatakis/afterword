import SwiftUI
import RecorderCore

struct BoardCitationView: View {
    let reference: BoardReference
    @ObservedObject var library: RecordingLibraryModel
    @ObservedObject private var coding: CodingCoordinator
    @ObservedObject private var github: GitHubCoordinator

    init(reference: BoardReference, library: RecordingLibraryModel) {
        self.reference = reference
        self.library = library
        self.coding = library.coding
        self.github = library.github
    }

    private enum Request: Equatable {
        case unavailable(String)
        case call([URL], UUID)
        case coding(CodingProjectSelection, String?)
        case github(String)
    }

    private var request: Request {
        switch reference.source {
        case .call:
            guard library.sources.contains(.recordings) else { return .unavailable("Recordings are turned off in Sources.") }
            return .call(library.roots, library.recordingScanID)
        case .coding:
            guard library.sources.contains(.coding) else { return .unavailable("Coding sessions are turned off in Sources.") }
            return .coding(coding.effectiveSelection, coding.importRevision)
        case .github:
            guard library.sources.contains(.github) else { return .unavailable("GitHub is turned off in Sources.") }
            guard !github.snapshot.locked else { return .unavailable("Reconnect GitHub to read this contribution.") }
            return .github(github.snapshot.revision)
        }
    }

    private enum SourceContent: Sendable {
        case call(LibraryRecording, LibraryTranscript?, [TranscriptParagraph])
        case coding(CodingHistory)
        case github(GitHubHit, [GitHubPassage])
    }

    @State private var refreshID = UUID()
    @State private var sharingStatus: String?
    @State private var loaded: Request?
    @State private var result: Result<SourceContent, Error>?

    var body: some View {
        let request = request
        VStack(alignment: .leading, spacing: 0) {
            if loaded == request, let sharingStatus {
                Text(sharingStatus).font(.callout).foregroundStyle(.secondary).padding(10)
                Divider()
            }
            if case .unavailable(let reason) = request {
                unavailable(reason)
            } else if loaded == request, let result {
                switch result {
                case .success(.coding(let history)):
                    CodingSessionDetail(session: history.session, directory: coding.directory, hit: nil,
                                        citedHistory: history, citedMessageID: reference.anchor)
                case .success(.github(let hit, _)):
                    GitHubItemView(hit: hit, directory: github.directory, revision: github.snapshot.revision, citedPassageID: reference.anchor)
                case .success(.call(let recording, let version, let paragraphs)):
                    callReader(recording, version: version, paragraphs: paragraphs)
                case .failure(let error):
                    unavailable(error.localizedDescription)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentAccessStore.toolsChanged).receive(on: RunLoop.main)) { _ in refreshID = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshID = UUID() }
        .task(id: LoadID(request: request, refresh: refreshID)) {
            let reference = reference, codingDirectory = coding.directory, githubDirectory = github.directory
            let peopleURL = library.peopleURL, stateDirectory = library.boardStore.stateDirectory
            let next = await Task.detached(priority: .userInitiated) {
                let content = Result { () throws -> SourceContent in
                    switch request {
                    case .unavailable(let reason): throw RecorderError.message(reason)
                    case .call(let roots, _):
                        let call = try RecordingLibraryScanner.citedCall(id: reference.itemID, roots: roots, peopleURL: peopleURL, includePersonal: true)
                        let version: LibraryTranscript?
                        if let id = reference.versionID {
                            guard let match = call.transcripts.first(where: { $0.agentVersionID(callID: reference.itemID) == id }) else {
                                throw RecorderError.message("The cited transcript version is no longer available.")
                            }
                            version = match
                        } else { version = call.latestTranscript }
                        if let error = version?.error { throw RecorderError.message(error) }
                        let paragraphs = version?.document?.paragraphs ?? []
                        if let anchor = reference.anchor {
                            guard let id = Int(anchor), let passage = paragraphs.first(where: { $0.id == id }),
                                  reference.versionID != nil || reference.quote.map({ !$0.isEmpty && passage.text.contains($0) }) == true else {
                                throw RecorderError.message("The cited transcript passage could not be verified.")
                            }
                        }
                        return .call(call, version, paragraphs)
                    case .coding(let projects, _):
                        let history = try CodingArchive.historyForDisplay(in: codingDirectory, id: reference.itemID)
                        guard projects.includes(history.session.project) else {
                            throw RecorderError.message("This session is outside your selected coding sources.")
                        }
                        if let anchor = reference.anchor, !history.messages.contains(where: { $0.id == anchor }) {
                            throw RecorderError.message("The cited message is no longer available.")
                        }
                        return .coding(history)
                    case .github:
                        guard GitHubArchive.exists(in: githubDirectory),
                              let archive = try? GitHubArchive(directory: githubDirectory),
                              let hit = try archive.search(shared: false, itemID: reference.itemID, passageID: reference.anchor).first else {
                            throw RecorderError.message("This contribution is no longer in your imported GitHub activity.")
                        }
                        return .github(hit, try archive.timeline(reference.itemID, shared: false))
                    }
                }
                let evidence: BoardEvidence
                switch content {
                case .success(.call(let call, _, _)): evidence = .call(call)
                case .success(.coding(let history)): evidence = .coding(history)
                case .success(.github(let hit, let passages)): evidence = .github(hit.item, passages)
                case .failure: return (content, nil as String?)
                }
                if evidence.verified(reference) == nil { return (content, "The saved citation no longer matches the source.") }
                return (content, reference.isSharedWithAgents(in: stateDirectory) ? nil : "This citation is private to Afterword.")
            }.value
            if !Task.isCancelled { result = next.0; sharingStatus = next.1; loaded = request }
        }
    }

    private struct LoadID: Equatable {
        let request: Request
        let refresh: UUID
    }

    private func unavailable(_ reason: String) -> some View {
        ContentUnavailableView("Source unavailable", systemImage: "link", description: Text(reason))
    }

    private func callReader(_ call: LibraryRecording, version: LibraryTranscript?, paragraphs: [TranscriptParagraph]) -> some View {
        let target = reference.anchor.flatMap(Int.init)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(call.name).font(.title2.bold())
                Text(call.date.formatted()).foregroundStyle(.secondary)
                if let version { Text("Transcript · " + version.runName).font(.caption).foregroundStyle(.secondary) }
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if paragraphs.isEmpty {
                            if let summary = call.summary?.current { MarkdownContent(markdown: summary.markdown) }
                            else { Text("No transcript passages.").foregroundStyle(.secondary) }
                        } else if let version {
                            ForEach(paragraphs) { passage in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(call.speakerLabel(for: passage, version: version) + " · " + Transcript.timestamp(passage.start))
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(passage.text)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(target == passage.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .id(passage.id)
                            }
                        }
                    }.padding(12)
                }.task(id: target) {
                    guard let target else { return }
                    await Task.yield()
                    if !Task.isCancelled { proxy.scrollTo(target, anchor: .top) }
                }
            }
        }.textSelection(.enabled)
    }
}
