import AppKit
import AVFoundation
import Combine
import RecorderCore

struct ParticipantAssignmentStatus {
    let versionID: String
    let paragraph: Int
    var error: String?
}

@MainActor final class RecordingLibraryModel: ObservableObject {
    @Published private(set) var recordings: [LibraryRecording] = []
    @Published private(set) var refreshing = false
    @Published private(set) var issues: [String] = []
    @Published var selection: String? { didSet { defaults.set(selection, forKey: "librarySelection") } }
    @Published var search = "" { didSet { updateSearch() } }
    let embeddings: EmbeddingCoordinator
    @Published var searchSpeaker = "" { didSet { updateSearch() } }
    @Published private(set) var speakerNames: [String] = []
    @Published private(set) var semanticStatus: SemanticSearchStatus?
    private var semanticTimer: Timer?
    private var semanticPolling = false
    private var polledSemanticStatus: SemanticSearchStatus?
    @Published var searchHistory = false { didSet { updateSearch() } }
    @Published private(set) var resultQuery = ""
    @Published private(set) var searching = false
    @Published private(set) var searchHits: [String: LibrarySearchHit] = [:]
    @Published private(set) var visibleRecordings: [LibraryRecording] = []
    @Published var filter: LibraryFilter = .all { didSet { applyFilter() } }
    @Published var sidebarVisible = true
    @Published private(set) var roots: [URL] = []
    @Published private(set) var managing = false
    @Published var preferredTranscriptID: String?
    @Published private(set) var transcriptDrafts: [String: TranscriptDraft] = [:]
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

    var selectedRecording: LibraryRecording? { visibleRecordings.first { $0.id == selection } }

    init(recorder: RecordingCoordinator, defaults: UserDefaults = .standard, embeddingDirectory: URL = EmbeddingSettings.directory) {
        embeddings = EmbeddingCoordinator(directory: embeddingDirectory)
        self.defaults = defaults
        self.recorder = recorder
        currentDestination = recorder.destination.resolvingSymlinksInPath().standardizedFileURL
        selection = defaults.string(forKey: "librarySelection")
        roots = (defaults.stringArray(forKey: "libraryFolders") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
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
        guard !semanticPolling, let index = searchIndex else { return }
        semanticPolling = true
        let history = searchHistory
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                if retry { index.retrySemanticSearch() } else { index.refreshSemanticSearch() }
                return (index.semanticStatus(allVersions: history), index.speakerNames)
            }.value
            guard let self else { return }
            let changed = self.polledSemanticStatus != result.0
            self.polledSemanticStatus = result.0
            if changed { self.semanticStatus = result.0 }
            if self.speakerNames != result.1 { self.speakerNames = result.1 }
            self.semanticPolling = false
            if (changed || retry) && !self.searching && !self.search.isEmpty { self.updateSearch(debounce: false) }
        }
    }
    func retrySemanticSearch() { pollSemanticSearch(retry: true) }
    func shutdown() { semanticTimer?.invalidate(); searchTask?.cancel(); searchIndex?.stopSemanticSearch(); embeddings.shutdown() }
    @discardableResult func refresh() -> Task<Void, Never>? {
        guard !managing else { return nil }
        scan?.cancel()
        let id = UUID(); generation = id; refreshing = true
        let roots = roots, embeddingDirectory = embeddings.directory
        let existing = indexRoots == roots ? searchIndex : nil
        if existing == nil { searchIndex?.stopSemanticSearch() }
        let task = Task.detached(priority: .utility) { () -> LibraryRefresh in
            do {
                let index = try existing ?? LibrarySearchIndex(roots: roots, embeddingDirectory: embeddingDirectory)
                return LibraryRefresh(index: index, recordings: try index.synchronize(), error: nil, issues: index.issues)
            } catch { return LibraryRefresh(index: nil, recordings: [], error: error.localizedDescription) }
        }
        scan = task
        return Task { [weak self] in
            let result = await task.value
            guard let self, self.generation == id else { return }
            self.refreshing = false; self.scan = nil
            if let error = result.error { self.issues = [error]; return }
            self.searchIndex = result.index; self.indexRoots = roots
            self.recordings = result.recordings; self.issues = result.issues
            self.pollSemanticSearch()
            await self.updateSearch(debounce: false)?.value
        }
    }
    @discardableResult func updateSearch(debounce: Bool = true) -> Task<Void, Never>? {
        searchTask?.cancel()
        let token = UUID(); searchGeneration = token
        if LibrarySearchQuery(search).isEmpty && searchSpeaker.isEmpty {
            searchHits = [:]; resultQuery = ""; searching = false
            matchedRecordings = recordings; applyFilter(); return nil
        }
        guard let index = searchIndex else { return nil }
        searching = true
        let query = search, history = searchHistory, speaker = searchSpeaker
        let task = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { Result { try index.hybridSearch(query, allVersions: history, speaker: speaker.isEmpty ? nil : speaker) } }
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self, !Task.isCancelled, self.searchGeneration == token else { return }
            self.searching = false
            switch result {
            case .success(let result):
                let hits = result.hits
                self.semanticStatus = result.status
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
        if !visibleRecordings.contains(where: { $0.id == selection }) { selection = visibleRecordings.first?.id }
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
        try beginManagement()
        do {
            let file = try await Task.detached(priority: .userInitiated) {
                try CallFileOperations.saveTranscriptEdits(text, version: version, recording: recording, participants: participants)
            }.value
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
        guard !managing, version.document?.paragraphs.isEmpty == false else { return }
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
        transcriptDrafts.values.contains { $0.changed } || renamingID.flatMap { id in recordings.first { $0.id == id } }.map { $0.name != renameText } == true
    }
    func moveToTrash(_ recording: LibraryRecording, version: LibraryTranscript? = nil, playback: RecordingPlayback,
                     trash: (@Sendable (URL) throws -> URL)? = nil) async throws {
        guard transcriptDrafts[recording.id] == nil, renamingID != recording.id else {
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
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All recordings", transcribed = "With transcripts", untranscribed = "Needs transcription"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .all: return "waveform"; case .transcribed: return "text.bubble"; case .untranscribed: return "text.badge.plus" }
    }
    func includes(_ recording: LibraryRecording) -> Bool {
        switch self { case .all: return true; case .transcribed: return recording.hasTranscript; case .untranscribed: return !recording.hasTranscript }
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
