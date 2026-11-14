import AppKit
import AVFoundation
import Combine
import RecorderCore

@MainActor final class RecordingLibraryModel: ObservableObject {
    @Published private(set) var recordings: [LibraryRecording] = []
    @Published private(set) var refreshing = false
    @Published private(set) var issues: [String] = []
    @Published var selection: String? { didSet { defaults.set(selection, forKey: "librarySelection") } }
    @Published var search = ""
    @Published var filter: LibraryFilter = .all
    @Published var sidebarVisible = true
    @Published private(set) var roots: [URL] = []
    @Published private(set) var managing = false
    @Published var preferredTranscriptID: String?
    @Published private(set) var transcriptDrafts: [String: TranscriptDraft] = [:]
    @Published private(set) var renamingID: String?
    @Published var renameText = ""
    @Published private(set) var renameError: String?
    @Published private(set) var renaming = false
    private weak var recorder: RecordingCoordinator?
    private var currentDestination: URL
    private var scan: Task<LibraryScan, Never>?
    private var generation = UUID()
    private var subscriptions: Set<AnyCancellable> = []
    private let defaults: UserDefaults

    var visibleRecordings: [LibraryRecording] {
        recordings.filter { filter.includes($0) && $0.matches(search) }
    }
    var selectedRecording: LibraryRecording? { visibleRecordings.first { $0.id == selection } }

    init(recorder: RecordingCoordinator, defaults: UserDefaults = .standard) {
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
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
    }
    @discardableResult func refresh() -> Task<Void, Never>? {
        guard !managing else { return nil }
        scan?.cancel()
        let id = UUID(); generation = id; refreshing = true
        let roots = roots
        let task = Task.detached(priority: .utility) { RecordingLibraryScanner.scan(roots: roots) }
        scan = task
        return Task { [weak self] in
            let result = await task.value
            guard let self, self.generation == id else { return }
            self.recordings = result.recordings; self.issues = result.issues
            self.refreshing = false; self.scan = nil
            if self.selection == nil { self.selection = self.visibleRecordings.first?.id }
            else if !self.recordings.contains(where: { $0.id == self.selection }) { self.selection = self.visibleRecordings.first?.id }
        }
    }
    private func beginManagement() throws {
        guard !managing else { throw RecorderError.message("Another change is still saving. Try again in a moment.") }
        managing = true; scan?.cancel(); scan = nil; generation = UUID(); refreshing = false
    }
    @discardableResult private func finishManagement() -> Task<Void, Never>? { managing = false; return refresh() }
    func saveDetails(_ details: CallDetails, for recording: LibraryRecording, reveal: Bool = true) async throws {
        try beginManagement()
        do {
            try await Task.detached(priority: .userInitiated) { try CallDetailsStore.save(details, for: recording) }.value
            if reveal { search = ""; selection = recording.id }
            await finishManagement()?.value
        } catch { finishManagement(); throw error }
    }
    func saveTranscript(_ text: [String], version: LibraryTranscript, recording: LibraryRecording, participants: [String?]? = nil) async throws {
        try beginManagement()
        do {
            let file = try await Task.detached(priority: .userInitiated) {
                try CallFileOperations.saveTranscriptEdits(text, version: version, recording: recording, participants: participants)
            }.value
            preferredTranscriptID = file.deletingLastPathComponent().appendingPathComponent("Transcript.json").path
            if selection == recording.id { search = "" }
            await finishManagement()?.value
        } catch { finishManagement(); throw error }
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
        if transcriptDrafts[recording.id] == nil { transcriptDrafts[recording.id] = TranscriptDraft(version: version, focusedParagraph: paragraph) }
    }
    func cancelTranscriptEditing(_ recording: LibraryRecording) {
        guard transcriptDrafts[recording.id]?.saving != true else { return }
        transcriptDrafts[recording.id] = nil
    }
    func assignParticipant(_ participant: String?, to paragraph: Int, recording: LibraryRecording, version: LibraryTranscript) {
        guard !managing, version.document?.paragraphs.indices.contains(paragraph) == true,
              version.document?.paragraphs[paragraph].source == .system else { return }
        if let participant, !participant.isEmpty, !recording.details.participants.contains(participant) { return }
        beginTranscriptEditing(recording, version: version)
        guard let draft = transcriptDrafts[recording.id], !draft.saving, draft.version.id == version.id else { return }
        draft.participants[paragraph] = participant
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
