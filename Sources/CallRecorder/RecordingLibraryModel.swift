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
    func refresh() {
        scan?.cancel()
        let id = UUID(); generation = id; refreshing = true
        let roots = roots
        let task = Task.detached(priority: .utility) { RecordingLibraryScanner.scan(roots: roots) }
        scan = task
        Task { [weak self] in
            let result = await task.value
            guard let self, self.generation == id else { return }
            self.recordings = result.recordings; self.issues = result.issues
            self.refreshing = false; self.scan = nil
            if self.selection == nil { self.selection = self.visibleRecordings.first?.id }
            else if !self.recordings.contains(where: { $0.id == self.selection }) { self.selection = nil }
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
