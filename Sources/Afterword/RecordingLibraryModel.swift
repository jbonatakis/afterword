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
    @Published private(set) var sources: Set<ActivitySource> = []
    @Published private(set) var sourceError: String?
    @Published var settingsTab = "sources"
    private let sourceDirectory: URL
    private var peopleSubscription: AnyCancellable?
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
    private var browseOrder: [String]?
    private var matchedOrder: [String] = []
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
    @Published var codingProject = "" { didSet { configureCodingPage(); updateSearch() } }
    @Published var codingBranch = "" { didSet { configureCodingPage(); updateSearch() } }
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
            if oldValue != filter { pendingInitialSelection = nil }
            configureCodingPage()
            if oldValue.callScope != filter.callScope {
                searchTask?.cancel(); searchGeneration = UUID()
                discardSearchIndex()
                searchPresentation.status = nil; polledSemanticStatus = nil
                browseOrder = nil; matchedOrder = []
                recordings = []; matchedRecordings = []; searchHits = [:]; speakerNames = []
                githubHistory = []; matchedGitHub = []; resultQuery = ""; searchSpeaker = ""
                applyFilter()
                refresh()
                return
            }
            if !filter.showsRecordings && !searchSpeaker.isEmpty { searchSpeaker = "" }
            applyFilter()
            if (oldValue == .github || filter == .github) && hasGitHubFilters { updateSearch(debounce: false) }
        }
    }
    private var hasGitHubFilters: Bool {
        !githubRepository.isEmpty || !githubType.isEmpty || !githubAction.isEmpty || githubPeriod != .any
    }
    @Published var sidebarVisible = true
    @Published private(set) var calendarPage: LibraryCalendarPage?
    var destination: LibraryDestination {
        get { calendarPage.map(LibraryDestination.calendar) ?? .activity(filter) }
        set {
            switch newValue {
            case .activity(let next):
                if calendarPage != nil { calendarPage = nil }
                if next != filter { filter = next }
            case .calendar(let page):
                if sources.contains(.recordings), calendarPage != page { calendarPage = page }
            }
        }
    }
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
    private(set) var currentDestination: URL?
    private var scan: Task<LibraryRefresh, Never>?
    private var searchIndex: LibrarySearchIndex?
    private var indexRoots: [URL] = []
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var matchedRecordings: [LibraryRecording] = []
    private var pendingInitialSelection: String?
    private var generation = UUID()
    private var subscriptions: Set<AnyCancellable> = []
    private let defaults: UserDefaults
    private lazy var summaryMonitor = LibrarySummaryMonitor { [weak self] in self?.scheduleLibraryRefresh() }
    private var pendingRefresh: DispatchWorkItem?
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
        sourceDirectory = embeddingDirectory == EmbeddingSettings.directory ? AgentAccessStore.directory :
            embeddingDirectory.deletingLastPathComponent().appendingPathComponent("MCP")
        self.defaults = defaults
        self.recorder = recorder
        currentDestination = recorder.destination
        let savedSelection = defaults.string(forKey: "librarySelection")
        let initial: Set<ActivitySource>
        do {
            if let saved = try ActivitySourceStore.load(directory: sourceDirectory) {
                initial = saved
            } else {
                // Previous releases remembered the recording destination on every library launch.
                let existing = defaults.object(forKey: "libraryFolders") != nil || defaults.object(forKey: "destination") != nil
                    || CodingArchive.exists(in: archiveDirectory) || GitHubArchive.exists(in: github.directory)
                initial = existing ? Set(ActivitySource.allCases) : []
            }
        } catch {
            initial = []
            sourceError = error.localizedDescription
        }
        coding.$providers.removeDuplicates().sink { [weak self] providers in
            guard let self, let selected = filter.codingProvider, !providers.contains(selected) else { return }
            filter = .coding
        }.store(in: &subscriptions)
        coding.changed = { [weak self] in
            guard let self, sources.contains(.coding) else { return }
            browseOrder = nil
            if !codingProject.isEmpty && !coding.projects.contains(codingProject) { codingProject = "" }
            if !codingBranch.isEmpty && !coding.branches.contains(codingBranch) { codingBranch = "" }
            requestRefresh()
        }
        coding.pageChanged = { [weak self] in
            guard let self, sources.contains(.coding) else { return }
            browseOrder = nil
            if browsing { updateSearch(debounce: false) }
        }
        github.changed = { [weak self] in
            guard let self, sources.contains(.github) else { return }
            let allowed = github.snapshot.locked ? [] : Set(github.snapshot.selections.map(\.id))
            githubHistory.removeAll { !allowed.contains($0.item.repositoryID) }
            matchedGitHub.removeAll { !allowed.contains($0.item.repositoryID) }
            searchGeneration = UUID(); searchTask?.cancel()
            applyFilter()
            requestRefresh()
        }
        recorder.$destination.dropFirst().removeDuplicates().sink { [weak self] folder in
            guard let self, sources.contains(.recordings) else { return }
            currentDestination = folder?.resolvingSymlinksInPath().standardizedFileURL
            if let folder { remember(folder) }
            refresh()
        }.store(in: &subscriptions)
        recorder.$savedFile.compactMap { $0 }.sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        recorder.transcription.$transcript.compactMap { $0 }.sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        embeddings.changed = { [weak self] in self?.retrySemanticSearch() }
        recorder.$state.combineLatest(recorder.transcription.$busy).sink { [weak self] state, transcribing in
            self?.embeddings.setBusy([.preparing, .recording, .previewing, .finalizing].contains(state) || transcribing)
        }.store(in: &subscriptions)
        applySources(initial)
        if !initial.isEmpty {
            pendingInitialSelection = savedSelection
            selection = savedSelection
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshOnOpen() }.store(in: &subscriptions)
    }
    func setSources(_ next: Set<ActivitySource>, recordingDestination: URL? = nil) {
        guard sources != next, let recorder else { return }
        if sources.contains(.recordings) && !next.contains(.recordings)
            && (recorder.locked || recorder.transcription.busy || recorder.transcription.downloadingID != nil ||
                managing || renamingID != nil || !summaryDrafts.isEmpty || !transcriptDrafts.isEmpty) {
            sourceError = "Finish recording, transcription, downloads, or pending edits before turning off Recordings."
            return
        }
        do {
            try ActivitySourceStore.save(next, directory: sourceDirectory)
            sourceError = nil
            if next.contains(.recordings), let recordingDestination { recorder.destination = recordingDestination }
            applySources(next)
        } catch { sourceError = error.localizedDescription }
    }

    private func applySources(_ next: Set<ActivitySource>) {
        guard let recorder else { return }
        pendingInitialSelection = nil
        let previous = sources
        browseOrder = nil
        scan?.cancel(); generation = UUID(); refreshing = false
        searchTask?.cancel(); searchGeneration = UUID(); searching = false
        discardSearchIndex()
        searchPresentation.status = nil; polledSemanticStatus = nil
        let records = next.contains(.recordings)
        recorder.setSourceEnabled(records)
        if !records && calendarPage != nil { calendarPage = nil }
        sources = next
        if records && !previous.contains(.recordings) {
            roots = Self.savedRecordingFolders(in: defaults)
            currentDestination = recorder.destination?.resolvingSymlinksInPath().standardizedFileURL
            if let currentDestination { remember(currentDestination) }
            recorder.calendar.library = self
            peopleSubscription = recorder.calendar.$directory.dropFirst().removeDuplicates().sink { [weak self] _ in self?.scheduleLibraryRefresh() }
        } else if !records {
            roots = []; recordings = []; matchedRecordings = []; searchHits = [:]; speakerNames = []
            if !searchSpeaker.isEmpty { searchSpeaker = "" }
            if searchHistory { searchHistory = false }
            peopleSubscription = nil; summaryMonitor.stop()
        }
        if next.contains(.coding) {
            if !previous.contains(.coding) { coding.start() }
        } else {
            coding.stop(); matchedCoding = []; codingHits = [:]
        }
        if next.contains(.github) {
            if !previous.contains(.github) { github.start() }
        } else {
            github.stop(); githubHistory = []; matchedGitHub = []
        }
        if next.count == 1, let only = next.first, filter.source != only { filter = only.libraryFilter }
        else if let current = filter.source, !next.contains(current) { filter = .activity }
        issues = []
        applyFilter()
        if next.isEmpty {
            semanticTimer?.invalidate(); semanticTimer = nil
            if let scan {
                let id = generation
                Task { [weak self] in
                    let result = await scan.value
                    await Task.detached(priority: .utility) { result.index?.stopSemanticSearch() }.value
                    if self?.generation == id { self?.scan = nil }
                }
            }
        } else {
            if semanticTimer == nil {
                semanticTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.pollSemanticSearch() }
                }
            }
            refresh()
        }
    }
    private func discardSearchIndex() {
        guard let old = searchIndex else { return }
        searchIndex = nil
        // A retiring search worker can hold its lock while decoding vectors.
        // The visible scope and its result generation change immediately.
        Task.detached(priority: .utility) { old.stopSemanticSearch() }
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
        stopped = true; summaryMonitor.stop(); pendingRefresh?.cancel()
        needsRefresh = false; scan?.cancel(); generation = UUID()
        semanticTimer?.invalidate(); searchTask?.cancel(); discardSearchIndex(); embeddings.shutdown()
    }
    private func scheduleLibraryRefresh() {
        guard !stopped else { return }
        needsRefresh = true
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRefresh = nil
            self?.refreshIfNeeded()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }
    private func refreshIfNeeded() {
        // Changes arriving during an index scan or local save must survive until
        // it completes. Never replace the user's separate in-memory drafts.
        guard needsRefresh, !refreshing, !managing, !stopped else { return }
        refresh()
    }
    private func requestRefresh() {
        needsRefresh = true
        refreshIfNeeded()
    }
    func refreshOnOpen() {
        if !refreshing { refresh() }
    }
    @discardableResult func refresh() -> Task<Void, Never>? {
        guard !stopped, !sources.isEmpty, !managing else { return nil }
        summaryMonitor.watch(roots)
        needsRefresh = false; pendingRefresh?.cancel(); pendingRefresh = nil
        let previousScan = scan
        previousScan?.cancel()
        let id = UUID(); generation = id; refreshing = true
        let roots = roots, embeddingDirectory = embeddings.directory, peopleURL = recorder?.peopleURL ?? PeopleDirectory.fileURL
        let callScope = filter.callScope
        let sessions = sources.contains(.coding) && callScope == .work ? coding.sessions : []
        let pageGeneration = coding.pageGeneration
        let codingDirectory = callScope == .work && sources.contains(.coding) ? coding.directory : nil
        let githubDirectory = callScope == .work && sources.contains(.github) ? github.directory : nil
        let cacheDirectory = embeddingDirectory == EmbeddingSettings.directory ? LibrarySearchIndex.cacheDirectory :
            embeddingDirectory.deletingLastPathComponent().appendingPathComponent("Search")
        let existing = indexRoots == roots ? searchIndex : nil
        if existing == nil { discardSearchIndex() }
        let showRecordingsFirst = recordings.isEmpty && sources.contains(.recordings) && !roots.isEmpty
        let task = Task.detached(priority: .utility) { [weak self] () -> LibraryRefresh in
            // SQLite cannot switch a fresh database to WAL from two concurrent opens.
            // A cancelled scan can still be finishing its current filesystem operation.
            _ = await previousScan?.value
            do {
                try Task.checkCancellation()
                let index = try existing ?? LibrarySearchIndex(roots: roots, directory: cacheDirectory, embeddingDirectory: embeddingDirectory, peopleURL: peopleURL, callScope: callScope)
                try Task.checkCancellation()
                let recordings = try index.synchronize(prepareSemanticSearch: false)
                if showRecordingsFirst && !recordings.isEmpty {
                    await self?.showInitialRecordings(recordings, generation: id)
                }
                try Task.checkCancellation()
                let sources = try index.browseSources(codingDirectory: codingDirectory, githubDirectory: githubDirectory)
                let order = activityOrder(recordings, sessions, sources.github, query: "")
                return LibraryRefresh(
                    index: index, recordings: recordings, error: nil, issues: index.issues, speakers: sources.speakers,
                    github: sources.github, order: order)
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
            if self.needsRefresh {
                await self.refresh()?.value
                return
            }
            self.pendingInitialSelection = nil
            self.browseOrder = self.coding.pageGeneration == pageGeneration ? result.order : nil
            self.githubHistory = result.github; self.recordings = result.recordings; self.issues = result.issues
            if self.speakerNames != result.speakers { self.speakerNames = result.speakers }
            self.pollSemanticSearch()
            await self.updateSearch(debounce: false)?.value
        }
    }
    private func showInitialRecordings(_ verified: [LibraryRecording], generation: UUID) {
        guard self.generation == generation, !stopped else { return }
        recordings = verified
        if browsing {
            browseOrder = coding.sessions.isEmpty && githubHistory.isEmpty ? verified.map(\.id) : nil
            updateSearch(debounce: false)
        }
    }
    private func configureCodingPage() {
        guard filter.showsCoding else { return }
        coding.setBrowseFilter(.init(provider: filter.codingProvider, project: codingProject.isEmpty ? nil : codingProject,
                                     branch: codingBranch.isEmpty ? nil : codingBranch))
    }
    private var browsing: Bool {
        search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchSpeaker.isEmpty && !(filter == .github && hasGitHubFilters)
    }
    var hasMoreCoding: Bool { filter.showsCoding && sources.contains(.coding) && browsing && coding.hasMore }
    func loadOlderCoding(after id: String) {
        if hasMoreCoding && id == coding.sessions.last?.id { coding.loadMore() }
    }
    @discardableResult func updateSearch(debounce: Bool = true) -> Task<Void, Never>? {
        searchTask?.cancel()
        let token = UUID(); searchGeneration = token
        if browsing {
            searchHits = [:]; resultQuery = ""; searching = false
            matchedGitHub = githubHistory; matchedRecordings = recordings; codingHits = [:]
            matchedCoding = sources.contains(.coding) && filter.callScope == .work ? coding.sessions : []
            // A coding snapshot can change while its replacement scan is still running.
            if recordings.isEmpty && githubHistory.isEmpty {
                matchedOrder = matchedCoding.map(\.id)
            } else {
                matchedOrder = browseOrder ?? activityOrder(recordings, matchedCoding, githubHistory, query: "")
            }
            applyFilter(); return nil
        }
        guard let index = searchIndex else { return nil }
        if !searching { searching = true }
        let recordingSnapshot = recordings
        let query = search, history = searchHistory, speaker = searchSpeaker, project = codingProject, branch = codingBranch
        let repo = filter == .github && !githubRepository.isEmpty ? githubRepository : nil
        let itemType = filter == .github && !githubType.isEmpty ? githubType : nil
        let action = filter == .github && !githubAction.isEmpty ? githubAction : nil
        let period = filter == .github ? githubPeriod.interval() : nil
        let task = Task { [weak self] in
            if debounce { try? await Task.sleep(nanoseconds: 150_000_000) }
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { Result {
                try Task.checkCancellation()
                // A query can arrive before the background poll warms a new browse snapshot.
                index.refreshSemanticSearch()
                try Task.checkCancellation()
                let calls = try index.hybridSearch(query, allVersions: history, speaker: speaker.isEmpty ? nil : speaker)
                try Task.checkCancellation()
                let coding = speaker.isEmpty ? try index.codingSearch(query, project: project.isEmpty ? nil : project, branch: branch.isEmpty ? nil : branch).hits : []
                let github = speaker.isEmpty ? try index.githubSearch(
                    query, repository: repo, type: itemType, action: action, from: period?.start, to: period?.end
                ).hits : []
                try Task.checkCancellation()
                let byID = Dictionary(uniqueKeysWithValues: recordingSnapshot.map { ($0.id, $0) })
                let records = calls.hits.compactMap { byID[$0.recordingID] }
                let sessions = coding.map(\.session)
                let callHits = Dictionary(uniqueKeysWithValues: calls.hits.map { ($0.recordingID, $0) })
                let codingHits = Dictionary(uniqueKeysWithValues: coding.map { ($0.session.id, $0) })
                let order = activityOrder(records, sessions, github, query: query, callHits: callHits, codingHits: codingHits)
                return LibraryQueryResult(recordings: records, sessions: sessions, github: github, callHits: callHits,
                                          codingHits: codingHits, order: order, status: calls.status)
            } }
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self, !Task.isCancelled, self.searchGeneration == token else { return }
            self.searching = false
            switch result {
            case .success(let result):
                self.matchedRecordings = result.recordings
                self.matchedCoding = result.sessions
                self.matchedGitHub = result.github
                self.matchedOrder = result.order
                self.searchHits = result.callHits
                self.codingHits = result.codingHits
                self.resultQuery = query
                self.searchPresentation.status = result.status
                self.applyFilter()
            case .failure(let error): self.issues = [error.localizedDescription]
            }
        }
        searchTask = task
        return task
    }
    private func applyFilter() {
        visibleRecordings = filter.showsRecordings && sources.contains(.recordings) ? matchedRecordings.filter { filter.includes($0) } : []
        visibleCoding = filter.showsCoding && sources.contains(.coding) ? matchedCoding.filter {
            filter.includes($0) && (codingProject.isEmpty || $0.project == codingProject) && (codingBranch.isEmpty || $0.branch == codingBranch)
        } : []
        visibleGitHub = sources.contains(.github) && (filter == .activity || filter == .github) ? matchedGitHub : []
        let rows =
            visibleRecordings.map(LibraryActivity.call) + visibleCoding.map(LibraryActivity.coding)
            + visibleGitHub.map(LibraryActivity.github)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        // Removing part of a source changes its round-robin rank against other sources.
        // This can happen immediately on repository removal, before a new query finishes.
        let order: [String]
        if filter == .activity && !resultQuery.isEmpty && rows.count != matchedOrder.count {
            order = activityOrder(visibleRecordings, visibleCoding, visibleGitHub, query: resultQuery, callHits: searchHits, codingHits: codingHits)
        } else {
            order = matchedOrder
        }
        activity = order.compactMap { byID[$0] }
        if let selection, byID[selection] != nil { return }
        // Another source may publish first while the saved item is still loading.
        if refreshing, browsing, let pendingInitialSelection, selection == pendingInitialSelection { return }
        selection = activity.first?.id
    }
    private func beginManagement() throws {
        guard !managing else { throw RecorderError.message("Another change is still saving. Try again in a moment.") }
        managing = true; scan?.cancel(); generation = UUID(); refreshing = false
    }
    @discardableResult private func finishManagement() -> Task<Void, Never>? { managing = false; return refresh() }
    func setScope(_ scope: CallScope, for recording: LibraryRecording) async throws {
        try beginManagement()
        let directory = sourceDirectory
        do {
            try await Task.detached(priority: .userInitiated) {
                if scope == .personal { try AgentAccessStore.prepareForPersonalCalls(directory: directory) }
                try CallDetailsStore.setScope(scope, for: recording)
            }.value
            await finishManagement()?.value
        } catch { finishManagement(); throw error }
    }
    var peopleDirectory: PeopleDirectory { recorder?.calendar.directory ?? .init() }

    func saveMetadata(title: String, tags: [String], description: String, for recording: LibraryRecording) async throws {
        try beginManagement()
        do {
            try await Task.detached(priority: .userInitiated) {
                try CallDetailsStore.saveMetadata(title: title, tags: tags, description: description, for: recording)
            }.value
            await finishManagement()?.value
        } catch { finishManagement(); throw error }
    }
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
        try await saveAttendance(AttendanceRoster(attendees), for: recording, version: version, confirmOnly: confirmOnly)
    }
    func saveAttendance(_ roster: AttendanceRoster, for recording: LibraryRecording, version: LibraryTranscript?, confirmOnly: String?) async throws {
        let attendees = roster.attendees
        try beginManagement()
        do {
            let change = try await Task.detached(priority: .userInitiated) {
                try CallDetailsStore.prepareAttendance(roster, for: recording, confirmOnly: confirmOnly)
            }.value
            if roster.newPeople.isEmpty {
                try await Task.detached(priority: .userInitiated) { try CallDetailsStore.saveAttendance(change, for: recording) }.value
            } else {
                guard let calendar = recorder?.calendar else { throw RecorderError.message("The people directory is unavailable.") }
                try await calendar.saveAttendanceWithNewPeople(roster, change: change, for: recording)
            }
            transcriptDrafts[recording.id]?.updateParticipants(change.updated.participants, renames: roster.renames)
            await finishManagement()?.value
        } catch { finishManagement(); throw error }
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
        if version == nil, recording.isDirectory, let destination = recorder.destination,
           CallFileOperations.contains(recording.url, destination.resolvingSymlinksInPath()) {
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
    static func savedRecordingFolders(in defaults: UserDefaults,
                                      legacyDestination: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Call Recordings", isDirectory: true)) -> [URL] {
        var paths = defaults.stringArray(forKey: "libraryFolders") ?? []
        if !defaults.bool(forKey: "migratedImplicitRecordingFolder") {
            // Older versions registered this path when Recordings was enabled, even before it existed.
            let path = legacyDestination.resolvingSymlinksInPath().standardizedFileURL.path
            if paths.contains(path), defaults.object(forKey: "destination") == nil {
                do { _ = try FileManager.default.attributesOfItem(atPath: path) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                    paths.removeAll { $0 == path }
                    defaults.set(paths, forKey: "libraryFolders")
                } catch { /* Keep inaccessible folders so the library reports the error. */ }
            }
            defaults.set(true, forKey: "migratedImplicitRecordingFolder")
        }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    func removeFolder(_ folder: URL) {
        guard folder != currentDestination else { return }
        roots.removeAll { $0 == folder }
        defaults.set(roots.map(\.path), forKey: "libraryFolders")
        refresh()
    }
}

private func activityOrder(_ calls: [LibraryRecording], _ coding: [CodingSession], _ github: [GitHubHit], query: String,
                           callHits: [String: LibrarySearchHit] = [:], codingHits: [String: CodingHit] = [:]) -> [String] {
    let ref = GitHubReference(query)
    let groups = [
        calls.map {
            ActivityMatch(id: $0.id, source: .call, title: $0.name, evidence: callHits[$0.id]?.snippet ?? "", date: $0.date)
        },
        coding.map {
            ActivityMatch(
                id: $0.id, source: .coding, title: $0.title, evidence: codingHits[$0.id]?.text ?? "",
                date: codingHits[$0.id]?.timestamp ?? $0.updated)
        },
        github.map {
            ActivityMatch(
                id: "github:" + $0.id, source: .github, title: $0.item.title, evidence: $0.citations.first?.text ?? "",
                date: $0.date, qualified: ref != nil)
        },
    ]
    return ActivityMatch.ordered(groups, query: query).map(\.id)
}

private struct LibraryQueryResult: Sendable {
    let recordings: [LibraryRecording]
    let sessions: [CodingSession]
    let github: [GitHubHit]
    let callHits: [String: LibrarySearchHit]
    let codingHits: [String: CodingHit]
    let order: [String]
    let status: SemanticSearchStatus
}

private struct LibraryRefresh: Sendable {
    let index: LibrarySearchIndex?
    let recordings: [LibraryRecording]
    let error: String?
    var issues: [String] = []
    var speakers: [String] = []
    var github: [GitHubHit] = []
    var order: [String] = []
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

extension ActivitySource {
    var libraryFilter: LibraryFilter {
        switch self {
        case .recordings: return .recordings
        case .coding: return .coding
        case .github: return .github
        }
    }
}

enum LibraryDestination: Hashable {
    case activity(LibraryFilter)
    case calendar(LibraryCalendarPage)
}

enum LibraryCalendarPage: String, CaseIterable {
    case upcoming = "Upcoming calls"
    case people = "People & groups"

    var symbol: String { self == .upcoming ? "calendar" : "person.2" }
}

enum LibraryFilter: String, Identifiable {
    case activity = "All activity", coding = "Coding sessions", codex = "Codex", claudeCode = "Claude Code"
    case github = "GitHub"
    case recordings = "Recordings", transcribed = "With transcripts", untranscribed = "Needs transcription"
    case needsSummary = "Needs summary", personal = "Personal"
    var callScope: CallScope { self == .personal ? .personal : .work }
    var id: Self { self }

    var source: ActivitySource? {
        switch self {
        case .activity: return nil
        case .github: return .github
        case .coding, .claudeCode, .codex: return .coding
        default: return .recordings
        }
    }

    var codingProvider: CodingProvider? {
        switch self {
        case .codex: return .codex
        case .claudeCode: return .claudeCode
        default: return nil
        }
    }

    func children(sources: Set<ActivitySource>, providers: Set<CodingProvider>) -> [Self] {
        switch self {
        case .activity: return [ActivitySource.coding, .recordings, .github].filter(sources.contains).map(\.libraryFilter)
        case .coding: return [Self.codex, .claudeCode].filter { $0.codingProvider.map(providers.contains) == true }
        case .recordings: return [.transcribed, .untranscribed, .needsSummary, .personal]
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
        guard recording.details.scope == callScope else { return false }
        switch self {
        case .transcribed: return recording.hasTranscript
        case .untranscribed: return !recording.hasTranscript
        case .needsSummary: return recording.hasTranscript && recording.summary?.current == nil && recording.summaryError == nil
        default: return showsRecordings
        }
    }
    func includes(_ session: CodingSession) -> Bool {
        if let codingProvider { return session.source == codingProvider.rawValue }
        return showsCoding
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
        case .personal: return "No personal recordings"
        }
    }
}

/// Each player is prepared on this serial executor, then owned exclusively by the main actor.
private actor PlaybackPreparation {
    func open(_ url: URL) throws -> AVAudioPlayer {
        try Task.checkCancellation()
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.prepareToPlay(), player.duration.isFinite, player.duration > 0 else {
            throw RecorderError.message("This audio file could not be opened for playback.")
        }
        try Task.checkCancellation()
        return player
    }
}

@MainActor final class RecordingPlayback: ObservableObject {
    @Published private(set) var recordingID: String?
    @Published private(set) var source: TranscriptSource = .mixed
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var error: String?
    enum Availability { case empty, preparing, ready }
    @Published private(set) var availability = Availability.empty
    var ready: Bool { availability == .ready }
    var canPlay: Bool { availability != .empty }
    private let loader = PlaybackPreparation()
    private var preparation: Task<Void, Never>?
    @Published private var playWhenReady = false
    var wantsPlayback: Bool { playing || playWhenReady }
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
    }
    func select(_ recording: LibraryRecording) {
        guard recordingID != recording.id else { return }
        clear(); recordingID = recording.id
        if let track = recording.tracks.first {
            duration = recording.duration ?? 0
            load(track, at: 0, resume: false)
        }
    }
    func changeTrack(_ source: TranscriptSource, in recording: LibraryRecording) {
        guard let track = recording.tracks.first(where: { $0.source == source }) else { return }
        load(track, at: position, resume: wantsPlayback)
    }
    private func load(_ track: LibraryAudioTrack, at time: Double, resume: Bool) {
        preparation?.cancel()
        pause()
        audio = nil; error = nil; source = track.source; position = time
        availability = .preparing; playWhenReady = resume
        let loader = loader
        preparation = Task { [weak self] in
            do {
                let player = try await loader.open(track.url)
                guard let self, !Task.isCancelled else { return }
                self.audio = player; self.duration = player.duration
                self.seek(self.position)
                self.availability = .ready
                self.preparation = nil
                if self.playWhenReady { self.play() }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.duration = 0; self.position = 0; self.playWhenReady = false
                self.availability = .empty; self.preparation = nil; self.error = error.localizedDescription
            }
        }
    }
    func toggle() { wantsPlayback ? pause() : play() }
    func play() {
        guard !captureActive else { return }
        if availability == .preparing { playWhenReady = true; return }
        playWhenReady = false
        guard let audio, ready else { return }
        if position >= duration - 0.05 { seek(0) }
        playing = audio.play()
        if playing && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        if !playing { error = "Playback could not start. Check your audio output and try again." }
    }
    func pause() { playWhenReady = false; audio?.pause(); playing = false; timer?.invalidate(); timer = nil }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if audio == nil && availability == .preparing { position = max(0, seconds); return }
        position = max(0, min(seconds, duration)); audio?.currentTime = position
    }
    private func tick() {
        guard playing, let audio else { return }
        if !audio.isPlaying { pause(); position = duration }
        else { position = audio.currentTime }
    }
    func clear() {
        preparation?.cancel(); preparation = nil; pause(); audio = nil
        availability = .empty; recordingID = nil; position = 0; duration = 0; error = nil
    }
    func shutdown() { clear(); timer?.invalidate(); timer = nil; stateSubscription?.cancel() }
}
