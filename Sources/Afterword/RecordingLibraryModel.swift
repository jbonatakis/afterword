import AppKit
import AVFoundation
import Combine
import RecorderCore

struct ParticipantAssignmentStatus {
    let versionID: String
    let paragraph: Int
    var error: String?
}

enum GitHubPeriod: String, CaseIterable {
    case any = "Any time", today = "Today", thisWeek = "This week", lastWeek = "Last week"

    func interval(relativeTo now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .any: return nil
        case .today: return calendar.dateInterval(of: .day, for: now)
        case .thisWeek: return calendar.dateInterval(of: .weekOfYear, for: now)
        case .lastWeek:
            return calendar.date(byAdding: .weekOfYear, value: -1, to: now).flatMap { calendar.dateInterval(of: .weekOfYear, for: $0) }
        }
    }
}

@MainActor final class LibrarySearchPresentation: ObservableObject {
    @Published fileprivate(set) var text = ""
    @Published fileprivate(set) var status: SemanticSearchStatus?
}

@MainActor final class RecordingLibraryModel: ObservableObject {
    @Published private(set) var recordings: [LibraryRecording] = []
    @Published private(set) var refreshing = false
    @Published private(set) var issues: [String] = []
    @Published var selection: String? { didSet { defaults.set(selection, forKey: "librarySelection") } }
    let searchPresentation = LibrarySearchPresentation()
    var search: String {
        get { searchPresentation.text }
        set {
            guard newValue != search else { return }
            searchPresentation.text = newValue
            updateSearch()
        }
    }
    let github: GitHubCoordinator
    private var githubHistory: [GitHubHit] = [] {
        didSet {
            githubReferences = Dictionary(
                githubHistory.map { ($0.repository.lowercased() + "#" + String($0.item.number), $0.id) },
                uniquingKeysWith: { first, _ in first })
        }
    }
    private(set) var githubReferences: [String: String] = [:]
    func openGitHub(_ id: String) {
        guard githubHistory.contains(where: { $0.id == id }) else { return }
        githubRepository = ""; githubType = ""; githubAction = ""; githubPeriod = .any
        filter = .github; search = ""; updateSearch(debounce: false); selection = "github:" + id
    }
    private var matchedGitHub: [GitHubHit] = []
    @Published private(set) var visibleGitHub: [GitHubHit] = []
    @Published private(set) var activity: [LibraryActivity] = []
    @Published var githubRepository = "" { didSet { updateSearch() } }
    @Published var githubType = "" { didSet { updateSearch() } }
    @Published var githubAction = "" { didSet { updateSearch() } }
    @Published var githubPeriod: GitHubPeriod = .any { didSet { updateSearch() } }
    var selectedGitHub: GitHubHit? { visibleGitHub.first { "github:" + $0.id == selection } }
    let coding: CodingCoordinator
    @Published private(set) var codingHits: [String: CodingHit] = [:]
    @Published private(set) var visibleCoding: [CodingSession] = []
    @Published var codingProject = "" { didSet { updateSearch() } }
    @Published var codingBranch = "" { didSet { updateSearch() } }
    private var matchedCoding: [CodingSession] = []
    var selectedCoding: CodingSession? { visibleCoding.first { $0.id == selection } }
    let embeddings: EmbeddingCoordinator
    @Published var searchSpeaker = "" { didSet { updateSearch() } }
    @Published private(set) var speakerNames: [String] = []
    var semanticStatus: SemanticSearchStatus? { searchPresentation.status }
    private var semanticTimer: Timer?
    private var semanticPolling = false
    private var polledSemanticStatus: SemanticSearchStatus?
    @Published var searchHistory = false { didSet { updateSearch() } }
    @Published private(set) var resultQuery = ""
    @Published private(set) var searching = false
    @Published private(set) var searchHits: [String: LibrarySearchHit] = [:]
    @Published private(set) var visibleRecordings: [LibraryRecording] = []
    @Published var filter: LibraryFilter = .activity {
        didSet {
            if !filter.showsRecordings && !searchSpeaker.isEmpty { searchSpeaker = "" }
            applyFilter()
            if (oldValue == .github || filter == .github) && hasGitHubFilters { updateSearch(debounce: false) }
        }
    }
    private var hasGitHubFilters: Bool {
        !githubRepository.isEmpty || !githubType.isEmpty || !githubAction.isEmpty || githubPeriod != .any
    }
    @Published var sidebarVisible = true
    @Published private(set) var roots: [URL] = []
    @Published private(set) var managing = false
    @Published var preferredTranscriptID: String?
    @Published private(set) var transcriptDrafts: [String: TranscriptDraft] = [:]
    @Published private(set) var summaryDrafts: [String: SummaryDraft] = [:]
    @Published private(set) var participantAssignments: [String: ParticipantAssignmentStatus] = [:]
    @Published private(set) var renamingID: String?
    @Published var renameText = ""
    @Published private(set) var renameError: String?
    @Published private(set) var renaming = false
    private weak var recorder: RecordingCoordinator?
    private var currentDestination: URL
    private var scan: Task<LibraryRefresh, Never>?
    private var searchIndex: LibrarySearchIndex?
    private var indexRoots: [URL] = []
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var matchedRecordings: [LibraryRecording] = []
    private var generation = UUID()
    private var subscriptions: Set<AnyCancellable> = []
    private let defaults: UserDefaults
    private lazy var summaryMonitor = LibrarySummaryMonitor { [weak self] in self?.scheduleLibraryRefresh() }
    private var pendingRefreshTask: Task<Void, Never>?
    private var needsRefresh = false
    private var stopped = false

    var selectedRecording: LibraryRecording? { visibleRecordings.first { $0.id == selection } }

    init(recorder: RecordingCoordinator, defaults: UserDefaults = .standard, embeddingDirectory: URL = EmbeddingSettings.directory, codingDirectory: URL? = nil) {
        let archiveDirectory = codingDirectory ?? (embeddingDirectory == EmbeddingSettings.directory ? CodingArchive.directory :
            embeddingDirectory.deletingLastPathComponent().appendingPathComponent("CodingSessions"))
        github = GitHubCoordinator(
            directory: embeddingDirectory == EmbeddingSettings.directory
                ? GitHubArchive.directory : embeddingDirectory.deletingLastPathComponent().appendingPathComponent("GitHub"))
        coding = CodingCoordinator(directory: archiveDirectory)
        embeddings = EmbeddingCoordinator(directory: embeddingDirectory)
        self.defaults = defaults
        self.recorder = recorder
        currentDestination = recorder.destination.resolvingSymlinksInPath().standardizedFileURL
        selection = defaults.string(forKey: "librarySelection")
        roots = (defaults.stringArray(forKey: "libraryFolders") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        coding.changed = { [weak self] in
            guard let self else { return }
            if !codingProject.isEmpty && !coding.projects.contains(codingProject) { codingProject = "" }
            if !codingBranch.isEmpty && !coding.sessions.contains(where: { $0.branch == self.codingBranch }) { codingBranch = "" }
            refresh()
        }
        github.changed = { [weak self] in
            guard let self else { return }
            let allowed = github.snapshot.locked ? [] : Set(github.snapshot.selections.map(\.id))
            githubHistory.removeAll { !allowed.contains($0.item.repositoryID) }
            matchedGitHub.removeAll { !allowed.contains($0.item.repositoryID) }
            searchGeneration = UUID(); searchTask?.cancel()
            applyFilter()
            refresh()
        }
        github.start()
        coding.start()
        recorder.calendar.library = self
        recorder.calendar.$directory.dropFirst().removeDuplicates().sink { [weak self] _ in self?.scheduleLibraryRefresh() }.store(in: &subscriptions)
        remember(recorder.destination)
        recorder.$destination.removeDuplicates().sink { [weak self] folder in
            self?.currentDestination = folder.resolvingSymlinksInPath().standardizedFileURL
            self?.remember(folder); self?.refresh()
        }.store(in: &subscriptions)
        recorder.$savedFile.compactMap { $0 }.sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        recorder.transcription.$transcript.compactMap { $0 }.sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        embeddings.changed = { [weak self] in self?.retrySemanticSearch() }
        recorder.$state.combineLatest(recorder.transcription.$busy).sink { [weak self] state, transcribing in
            self?.embeddings.setBusy([.preparing, .recording, .previewing, .finalizing].contains(state) || transcribing)
        }.store(in: &subscriptions)
        semanticTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollSemanticSearch() }
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
    }
    func pollSemanticSearch(retry: Bool = false) {
        guard !stopped, !semanticPolling, let index = searchIndex else { return }
        semanticPolling = true
        let history = searchHistory
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                if retry { index.retrySemanticSearch() } else { index.refreshSemanticSearch() }
                return index.semanticStatus(allVersions: history)
            }.value
            guard let self, !self.stopped else { return }
            self.semanticPolling = false
            guard self.searchIndex === index else { return }
            let previous = self.polledSemanticStatus
            self.polledSemanticStatus = status
            if previous != status { self.searchPresentation.status = status }
            let availabilityChanged = previous?.state != status.state || previous?.model != status.model ||
                (previous?.indexed == 0 && status.indexed > 0)
            if (availabilityChanged || retry) && !self.searching && !self.search.isEmpty { self.updateSearch(debounce: false) }
        }
    }
    func retrySemanticSearch() { pollSemanticSearch(retry: true) }
    func shutdown() {
        github.stop(); coding.stop()
        stopped = true; summaryMonitor.stop(); pendingRefreshTask?.cancel()
        needsRefresh = false; scan?.cancel(); generation = UUID()
        semanticTimer?.invalidate(); searchTask?.cancel(); searchIndex?.stopSemanticSearch(); embeddings.shutdown()
    }
    private func scheduleLibraryRefresh() {
        guard !stopped else { return }
        needsRefresh = true
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.pendingRefreshTask = nil
            self.refreshIfNeeded()
        }
    }
    private func refreshIfNeeded() {
        // Changes arriving during an index scan or local save must survive until
        // it completes. Never replace the user's separate in-memory drafts.
        guard needsRefresh, !refreshing, !managing, !stopped else { return }
        refresh()
    }
    @discardableResult func refresh() -> Task<Void, Never>? {
        guard !stopped, !managing else { return nil }
        summaryMonitor.watch(roots)
        needsRefresh = false; pendingRefreshTask?.cancel(); pendingRefreshTask = nil
        scan?.cancel()
        let id = UUID(); generation = id; refreshing = true
        let roots = roots, embeddingDirectory = embeddings.directory, peopleURL = recorder?.peopleURL ?? PeopleDirectory.fileURL
        let codingDirectory = coding.sessions.isEmpty ? nil : coding.directory
        let githubDirectory = github.directory
        let existing = indexRoots == roots ? searchIndex : nil
        if existing == nil { searchIndex?.stopSemanticSearch() }
        let task = Task.detached(priority: .utility) { () -> LibraryRefresh in
            do {
                let index = try existing ?? LibrarySearchIndex(roots: roots, embeddingDirectory: embeddingDirectory, peopleURL: peopleURL)
                try index.useCodingArchive(in: codingDirectory)
                try index.useGitHubArchive(in: githubDirectory, shared: false)
                let githubItems = try index.githubSearch("", keywordOnly: true).hits
                return LibraryRefresh(
                    index: index, recordings: try index.synchronize(), error: nil, issues: index.issues, speakers: index.speakerNames,
                    github: githubItems)
            } catch { return LibraryRefresh(index: nil, recordings: [], error: error.localizedDescription) }
        }
        scan = task
        return Task { [weak self] in
            let result = await task.value
            guard let self, self.generation == id else { return }
            self.refreshing = false; self.scan = nil
            defer { self.refreshIfNeeded() }
            if let error = result.error { self.issues = [error]; return }
            self.searchIndex = result.index; self.indexRoots = roots
            self.githubHistory = result.github; self.recordings = result.recordings; self.issues = result.issues
            if self.speakerNames != result.speakers { self.speakerNames = result.speakers }
            self.pollSemanticSearch()
            await self.updateSearch(debounce: false)?.value
        }
    }
    @discardableResult func updateSearch(debounce: Bool = true) -> Task<Void, Never>? {
        searchTask?.cancel()
        let token = UUID(); searchGeneration = token
        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchSpeaker.isEmpty
            && !(filter == .github && hasGitHubFilters)
        {
            searchHits = [:]; resultQuery = ""; searching = false
            matchedGitHub = githubHistory; matchedRecordings = recordings; matchedCoding = coding.sessions; codingHits = [:];
            applyFilter(); return nil
        }
        guard let index = searchIndex else { return nil }
        if !searching { searching = true }
        let query = search, history = searchHistory, speaker = searchSpeaker, project = codingProject, branch = codingBranch
        let repo = filter == .github && !githubRepository.isEmpty ? githubRepository : nil
        let itemType = filter == .github && !githubType.isEmpty ? githubType : nil
        let action = filter == .github && !githubAction.isEmpty ? githubAction : nil
        let period = filter == .github ? githubPeriod.interval() : nil
        let task = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { Result {
                try Task.checkCancellation()
                let calls = try index.hybridSearch(query, allVersions: history, speaker: speaker.isEmpty ? nil : speaker)
                try Task.checkCancellation()
                let coding = speaker.isEmpty ? try index.codingSearch(query, project: project.isEmpty ? nil : project, branch: branch.isEmpty ? nil : branch).hits : []
                    let github =
                        speaker.isEmpty
                        ? try index.githubSearch(
                            query, repository: repo, type: itemType, action: action, from: period?.start, to: period?.end
                        ).hits : []
                    return (calls, coding, github)
            } }
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self, !Task.isCancelled, self.searchGeneration == token else { return }
            self.searching = false
            switch result {
            case .success(let (result, codingResults, githubResults)):
                self.matchedGitHub = githubResults
                self.codingHits = Dictionary(uniqueKeysWithValues: codingResults.map { ($0.session.id, $0) })
                self.matchedCoding = codingResults.map(\.session)
                let hits = result.hits
                self.searchPresentation.status = result.status
                let byID = Dictionary(uniqueKeysWithValues: self.recordings.map { ($0.id, $0) })
                self.searchHits = Dictionary(uniqueKeysWithValues: hits.map { ($0.recordingID, $0) })
                self.resultQuery = query
                self.matchedRecordings = hits.compactMap { byID[$0.recordingID] }
                self.applyFilter()
            case .failure(let error): self.issues = [error.localizedDescription]
            }
        }
        searchTask = task
        return task
    }
    private func applyFilter() {
        visibleRecordings = matchedRecordings.filter { filter.includes($0) }
        visibleCoding = matchedCoding.filter {
            filter.includes($0) && (codingProject.isEmpty || $0.project == codingProject) && (codingBranch.isEmpty || $0.branch == codingBranch)
        }
        visibleGitHub = filter == .activity || filter == .github ? matchedGitHub : []
        let rows =
            visibleRecordings.map(LibraryActivity.call) + visibleCoding.map(LibraryActivity.coding)
            + visibleGitHub.map(LibraryActivity.github)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let ref = GitHubReference(resultQuery)
        let groups = [
            visibleRecordings.map {
                ActivityMatch(id: $0.id, source: .call, title: $0.name, evidence: searchHits[$0.id]?.snippet ?? "", date: $0.date)
            },
            visibleCoding.map {
                ActivityMatch(
                    id: $0.id, source: .coding, title: $0.title, evidence: codingHits[$0.id]?.text ?? "",
                    date: codingHits[$0.id]?.timestamp ?? $0.updated)
            },
            visibleGitHub.map {
                ActivityMatch(
                    id: "github:" + $0.id, source: .github, title: $0.item.title, evidence: $0.citations.first?.text ?? "",
                    date: $0.date, qualified: ref != nil)
            },
        ]
        activity = ActivityMatch.ordered(groups, query: resultQuery).compactMap { byID[$0.id] }
        if selection.flatMap({ byID[$0] }) == nil { selection = activity.first?.id }
    }
    private func beginManagement() throws {
        guard !managing else { throw RecorderError.message("Another change is still saving. Try again in a moment.") }
        managing = true; scan?.cancel(); scan = nil; generation = UUID(); refreshing = false
    }
    @discardableResult private func finishManagement() -> Task<Void, Never>? { managing = false; return refresh() }
    func saveDetails(_ details: CallDetails, for recording: LibraryRecording, reveal: Bool = true, participantRenames: [String: String] = [:]) async throws {
        try beginManagement()
        do {
            let saved = try await Task.detached(priority: .userInitiated) { try CallDetailsStore.save(details, for: recording, participantRenames: participantRenames) }.value
            transcriptDrafts[recording.id]?.updateParticipants(saved.participants, renames: participantRenames)
            if reveal { search = ""; selection = recording.id }
            await finishManagement()?.value
        } catch { finishManagement(); throw error }
    }
    func saveTranscript(_ text: [String], version: LibraryTranscript, recording: LibraryRecording, participants: [String?]? = nil, clearSearch: Bool = true) async throws {
        try await saveTranscriptVersion(recording, clearSearch: clearSearch) {
            try CallFileOperations.saveTranscriptEdits(text, version: version, recording: recording, participants: participants)
        }
    }

    func saveSpeakers(_ review: SpeakerReview, version: LibraryTranscript, recording: LibraryRecording) async throws {
        try await saveTranscriptVersion(recording, clearSearch: false) {
            try CallFileOperations.saveSpeakerReview(review, version: version, recording: recording)
        }
    }

    func assignSpeakerGroup(_ group: String, to name: String, from paragraph: Int, recording: LibraryRecording, version: LibraryTranscript) async {
        guard !managing, transcriptDrafts[recording.id] == nil,
              let person = recording.details.callAttendees.first(where: { $0.active && $0.name == name }) else { return }
        participantAssignments[recording.id] = .init(versionID: version.id, paragraph: paragraph)
        do {
            try await saveTranscriptVersion(recording, clearSearch: false) {
                try CallFileOperations.assignSpeakerGroup(group, to: person.id, version: version, recording: recording)
            }
            participantAssignments[recording.id] = nil
        } catch {
            participantAssignments[recording.id] = .init(versionID: version.id, paragraph: paragraph, error: error.localizedDescription)
        }
    }

    private func saveTranscriptVersion(_ recording: LibraryRecording, clearSearch: Bool, write: @escaping @Sendable () throws -> URL) async throws {
        try beginManagement()
        do {
            let file = try await Task.detached(priority: .userInitiated, operation: write).value
            preferredTranscriptID = file.deletingLastPathComponent().appendingPathComponent("Transcript.json").path
            if clearSearch && selection == recording.id { search = "" }
            await finishManagement()?.value
        } catch { finishManagement(); throw error }
    }
    func saveAttendance(_ attendees: [CallAttendee], for recording: LibraryRecording, version: LibraryTranscript?, confirmOnly: String?) async throws {
        let latest = try CallDetailsStore.load(for: recording.url, isDirectory: recording.isDirectory)
        guard latest.callAttendees == recording.details.callAttendees else {
            throw RecorderError.message("The participants changed. Reopen attendance to review the updated list.")
        }
        let details = try latest.updatingAttendance(attendees, confirmOnly: confirmOnly)
        try await saveDetails(details, for: recording, reveal: false)
        guard let confirmOnly, let person = attendees.first(where: { $0.id == confirmOnly }),
              let current = recordings.first(where: { $0.id == recording.id }), let version, let document = version.document else { return }
        if let draft = transcriptDrafts[recording.id] {
            for index in draft.paragraphs.indices where draft.paragraphs[index].source == .system && (draft.participants[index] ?? "").isEmpty {
                draft.participants[index] = person.name
            }
        } else {
            let paragraphs = document.paragraphs
            var names = paragraphs.map { current.details.participantName($0.participant, for: version) }
            for index in paragraphs.indices where paragraphs[index].source == .system && (names[index] ?? "").isEmpty { names[index] = person.name }
            if names != paragraphs.map(\.participant) {
                try await saveTranscript(paragraphs.map(\.text), version: version, recording: current, participants: names, clearSearch: false)
            }
        }
    }
    func beginRenaming(_ recording: LibraryRecording) {
        guard !managing, renamingID == nil || renamingID == recording.id else { return }
        selection = recording.id; renameText = recording.name; renameError = nil; renamingID = recording.id
    }
    func cancelRename() {
        guard !renaming else { return }
        renamingID = nil; renameError = nil
    }
    func saveRename() async {
        guard !renaming, let id = renamingID, let recording = recordings.first(where: { $0.id == id }) else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { renameError = "Enter a title."; return }
        guard title != recording.name else { cancelRename(); return }
        renaming = true; renameError = nil
        do {
            // Re-read details so changing just the title cannot overwrite an updated participant list.
            var details = try CallDetailsStore.load(for: recording.url, isDirectory: recording.isDirectory)
            details.title = title
            try await saveDetails(details, for: recording, reveal: false)
            renamingID = nil
        } catch { renameError = error.localizedDescription }
        renaming = false
    }
    func beginTranscriptEditing(_ recording: LibraryRecording, version: LibraryTranscript, paragraph: Int? = nil) {
        guard !managing, summaryDrafts[recording.id] == nil, version.document?.paragraphs.isEmpty == false else { return }
        participantAssignments[recording.id] = nil
        if transcriptDrafts[recording.id] == nil { transcriptDrafts[recording.id] = TranscriptDraft(version: version, focusedParagraph: paragraph, details: recording.details) }
    }
    func cancelTranscriptEditing(_ recording: LibraryRecording) {
        guard transcriptDrafts[recording.id]?.saving != true else { return }
        transcriptDrafts[recording.id] = nil
    }
    func assignParticipant(_ participant: String?, to paragraph: Int, recording: LibraryRecording, version: LibraryTranscript) async {
        guard !managing, version.document?.paragraphs.indices.contains(paragraph) == true,
              version.document?.paragraphs[paragraph].source == .system else { return }
        if let participant, !participant.isEmpty, !recording.details.participants.contains(participant) { return }
        participantAssignments[recording.id] = nil
        // An explicitly opened text draft keeps its Save/Cancel behavior. A
        // speaker choice in the reader saves on its own, without opening it.
        if let draft = transcriptDrafts[recording.id] {
            guard !draft.saving, draft.version.id == version.id else { return }
            draft.participants[paragraph] = participant
            return
        }
        guard let document = version.document else { return }
        let paragraphs = document.paragraphs
        var names = paragraphs.map { recording.details.participantName($0.participant, for: version) }
        guard names[paragraph] != participant else { return }
        names[paragraph] = participant
        participantAssignments[recording.id] = .init(versionID: version.id, paragraph: paragraph)
        do {
            try await saveTranscript(paragraphs.map(\.text), version: version, recording: recording, participants: names, clearSearch: false)
            participantAssignments[recording.id] = nil
        } catch {
            participantAssignments[recording.id] = .init(versionID: version.id, paragraph: paragraph, error: error.localizedDescription)
        }
    }
    func saveTranscriptDraft(for recording: LibraryRecording) async {
        guard let draft = transcriptDrafts[recording.id], !draft.saving, draft.changed else { return }
        draft.saving = true; draft.error = nil
        do {
            try await saveTranscript(draft.text, version: draft.version, recording: recording, participants: draft.participants)
            transcriptDrafts[recording.id] = nil
        } catch { draft.error = error.localizedDescription }
        draft.saving = false
    }
    var hasUnsavedEdits: Bool {
        summaryDrafts.values.contains { $0.changed } || transcriptDrafts.values.contains { $0.changed } || renamingID.flatMap { id in recordings.first { $0.id == id } }.map { $0.name != renameText } == true
    }
    func beginSummaryEditing(_ recording: LibraryRecording) {
        guard !managing, recording.summaryError == nil, transcriptDrafts[recording.id] == nil, summaryDrafts[recording.id] == nil else { return }
        summaryDrafts[recording.id] = SummaryDraft(recording: recording)
    }
    func cancelSummaryEditing(_ recording: LibraryRecording) {
        guard summaryDrafts[recording.id]?.saving != true else { return }
        summaryDrafts[recording.id] = nil
    }
    func saveSummaryDraft(for recording: LibraryRecording) async {
        guard !managing, let draft = summaryDrafts[recording.id], draft.changed, !draft.saving else { return }
        draft.saving = true; draft.error = nil
        do {
            try beginManagement()
            let snapshot = draft.recording, text = draft.markdown
            let peopleURL = recorder?.peopleURL ?? PeopleDirectory.fileURL
            _ = try await Task.detached(priority: .userInitiated) {
                try CallSummaryStore.save(text, for: snapshot, source: snapshot.summary == nil ? snapshot.latestTranscript : nil, peopleURL: peopleURL)
            }.value
            summaryDrafts[recording.id] = nil
            await finishManagement()?.value
        } catch { finishManagement(); draft.error = error.localizedDescription }
        draft.saving = false
    }
    func moveToTrash(_ recording: LibraryRecording, version: LibraryTranscript? = nil, playback: RecordingPlayback,
                     trash: (@Sendable (URL) throws -> URL)? = nil) async throws {
        guard transcriptDrafts[recording.id] == nil, summaryDrafts[recording.id] == nil, renamingID != recording.id else {
            throw RecorderError.message("Save or cancel your edits before moving this item to Trash.")
        }
        guard let recorder, !recorder.locked else { throw RecorderError.message("Finish recording before moving items to Trash.") }
        if version == nil, recording.isDirectory, CallFileOperations.contains(recording.url, recorder.destination.resolvingSymlinksInPath()) {
            throw RecorderError.message("This call contains the current recording destination. Choose another destination in Settings first.")
        }
        try beginManagement()
        defer { finishManagement() }
        try recorder.transcription.beginLibraryMutation()
        defer { recorder.transcription.endLibraryMutation() }
        let unloadedPlayback = version == nil && playback.recordingID == recording.id
        if unloadedPlayback { playback.clear() }
        do {
            let plan = try await Task.detached(priority: .userInitiated) {
                let plan = try version.map { try CallFileOperations.trashPlan(for: $0, recording: recording) }
                    ?? CallFileOperations.trashPlan(for: recording)
                try CallFileOperations.moveToTrash(plan, trash: trash)
                return plan
            }.value
            recorder.transcription.filesMovedToTrash(plan.urls)
            roots.removeAll { root in plan.urls.contains { CallFileOperations.contains($0, root) } }
            defaults.set(roots.map(\.path), forKey: "libraryFolders")
            if let saved = recorder.savedFile, plan.urls.contains(where: { CallFileOperations.contains($0, saved) }) { recorder.savedFile = nil }
            if preferredTranscriptID.map({ id in plan.urls.contains { CallFileOperations.contains($0, URL(fileURLWithPath: id)) } }) == true { preferredTranscriptID = nil }
        } catch {
            if unloadedPlayback, playback.recordingID == nil { playback.select(recording) }
            throw error
        }
    }
    func addFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Add to library"
        panel.message = "Choose a recordings folder. Existing audio and transcripts stay where they are."
        if panel.runModal() == .OK, let url = panel.url { remember(url); refresh() }
    }
    private func remember(_ folder: URL) {
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL
        if !roots.contains(folder) {
            roots.append(folder); defaults.set(roots.map(\.path), forKey: "libraryFolders")
        }
    }
    func removeFolder(_ folder: URL) {
        guard folder != currentDestination else { return }
        roots.removeAll { $0 == folder }
        defaults.set(roots.map(\.path), forKey: "libraryFolders")
        refresh()
    }
}

private struct LibraryRefresh: Sendable {
    let index: LibrarySearchIndex?
    let recordings: [LibraryRecording]
    let error: String?
    var issues: [String] = []
    var speakers: [String] = []
    var github: [GitHubHit] = []
}

enum LibraryActivity: Identifiable {
    case call(LibraryRecording), coding(CodingSession), github(GitHubHit)
    var id: String {
        switch self {
        case .call(let item): return item.id
        case .coding(let item): return item.id
        case .github(let item): return "github:" + item.id
        }
    }
}

enum LibraryFilter: String, Identifiable {
    case activity = "All activity", coding = "Coding sessions", codex = "Codex", claudeCode = "Claude Code"
    case github = "GitHub"
    case recordings = "Recordings", transcribed = "With transcripts", untranscribed = "Needs transcription"
    case needsSummary = "Needs summary"
    var id: Self { self }

    var children: [Self] {
        switch self {
        case .activity: return [.coding, .recordings, .github]
        case .coding: return [.codex, .claudeCode]
        case .recordings: return [.transcribed, .untranscribed, .needsSummary]
        default: return []
        }
    }

    var showsRecordings: Bool {
        switch self {
        case .github, .coding, .codex, .claudeCode: return false
        default: return true
        }
    }
    var showsCoding: Bool { self != .github && (self == .activity || !showsRecordings) }

    func includes(_ recording: LibraryRecording) -> Bool {
        switch self {
        case .transcribed: return recording.hasTranscript
        case .untranscribed: return !recording.hasTranscript
        case .needsSummary: return recording.hasTranscript && recording.summary?.current == nil && recording.summaryError == nil
        default: return showsRecordings
        }
    }
    func includes(_ session: CodingSession) -> Bool {
        switch self {
        case .codex: return session.source == CodingProvider.codex.rawValue
        case .claudeCode: return session.source == CodingProvider.claudeCode.rawValue
        default: return showsCoding
        }
    }

    var emptyTitle: String {
        switch self {
        case .github: return "No GitHub activity"
        case .activity: return "No activity"
        case .coding: return "No coding sessions"
        case .codex, .claudeCode: return "No \(rawValue) sessions"
        case .recordings: return "No recordings"
        case .transcribed: return "No recordings with transcripts"
        case .untranscribed: return "No recordings need transcription"
        case .needsSummary: return "No recordings need a summary"
        }
    }
}

@MainActor final class RecordingPlayback: ObservableObject {
    @Published private(set) var recordingID: String?
    @Published private(set) var source: TranscriptSource = .mixed
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var error: String?
    @Published private(set) var ready = false
    private var audio: AVAudioPlayer?
    private var timer: Timer?
    private var stateSubscription: AnyCancellable?
    private var captureActive = false

    convenience init(recorder: RecordingCoordinator) { self.init(states: recorder.$state.eraseToAnyPublisher()) }
    init(states: AnyPublisher<RecordingState, Never>) {
        stateSubscription = states.sink { [weak self] state in
            self?.captureActive = [.preparing, .previewing, .recording, .finalizing].contains(state)
            if self?.captureActive == true { self?.pause() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func select(_ recording: LibraryRecording) {
        guard recordingID != recording.id else { return }
        clear(); recordingID = recording.id
        if let track = recording.tracks.first { load(track, at: 0, resume: false) }
    }
    func changeTrack(_ source: TranscriptSource, in recording: LibraryRecording) {
        guard let track = recording.tracks.first(where: { $0.source == source }) else { return }
        load(track, at: position, resume: playing)
    }
    private func load(_ track: LibraryAudioTrack, at time: Double, resume: Bool) {
        pause(); audio = nil; ready = false; error = nil; source = track.source
        do {
            let player = try AVAudioPlayer(contentsOf: track.url)
            guard player.prepareToPlay(), player.duration.isFinite, player.duration > 0 else {
                throw RecorderError.message("This audio file could not be opened for playback.")
            }
            audio = player; duration = player.duration; ready = true
            seek(time)
            if resume { play() }
        } catch { duration = 0; position = 0; self.error = error.localizedDescription }
    }
    func toggle() { playing ? pause() : play() }
    func play() {
        guard let audio, ready, !captureActive else { return }
        if position >= duration - 0.05 { seek(0) }
        playing = audio.play()
        if !playing { error = "Playback could not start. Check your audio output and try again." }
    }
    func pause() { audio?.pause(); playing = false }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        position = max(0, min(seconds, duration)); audio?.currentTime = position
    }
    private func tick() {
        guard playing, let audio else { return }
        if !audio.isPlaying { playing = false; position = duration }
        else { position = audio.currentTime }
    }
    func clear() { pause(); audio = nil; ready = false; recordingID = nil; position = 0; duration = 0; error = nil }
    func shutdown() { clear(); timer?.invalidate(); timer = nil; stateSubscription?.cancel() }
}
