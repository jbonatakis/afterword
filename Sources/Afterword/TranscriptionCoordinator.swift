import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RecorderCore

@MainActor final class TranscriptionCoordinator: ObservableObject {
    private let defaults: UserDefaults
    @Published var selectedID: String { didSet { defaults.set(selectedID, forKey: "transcriptionModel") } }
    @Published private(set) var installed: [String: InstalledSpeechModel] = [:]
    @Published private(set) var downloadingID: String?
    @Published private(set) var downloadFraction: Double?
    @Published private(set) var downloadMessage: String?
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var fraction: Double?
    @Published private(set) var transcript: URL?
    @Published private(set) var recording: URL?
    @Published var autoTranscribe: Bool { didSet { defaults.set(autoTranscribe, forKey: "autoTranscribe") } }
    @Published var reduceSpeakerBleed: Bool { didSet { defaults.set(reduceSpeakerBleed, forKey: SpeakerBleedReduction.preferenceKey) } }
    private var downloadTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var job: TranscriptionJob?
    private var operation: UUID?
    private var downloadOperation: UUID?
    private var recordingActive = false
    private var cancellationMessage: String?
    private var pendingAutomaticRecording: URL?
    @Published private(set) var libraryMutationActive = false

    var selected: SpeechModel { SpeechModel.catalog.first { $0.id == selectedID } ?? SpeechModel.catalog[0] }
    var canTranscribe: Bool { !busy && !recordingActive && !libraryMutationActive && recording != nil && installed[selectedID] != nil }
    var recordingName: String? {
        guard let recording else { return nil }
        return recording.lastPathComponent == RecordingTrack.mixed.filename ? recording.deletingLastPathComponent().lastPathComponent : recording.lastPathComponent
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "transcriptionModel")
        selectedID = SpeechModel.catalog.first { $0.id == saved }?.id ?? SpeechModel.catalog[0].id
        autoTranscribe = defaults.bool(forKey: "autoTranscribe")
        reduceSpeakerBleed = SpeakerBleedReduction.preference(in: defaults)
        if let path = defaults.string(forKey: "transcriptionRecording"), FileManager.default.fileExists(atPath: path) {
            recording = URL(fileURLWithPath: path)
        }
        refreshModels()
    }
    func refreshModels() {
        installed = Dictionary(uniqueKeysWithValues: SpeechModel.catalog.compactMap { model in ModelStore.find(model).map { (model.id, $0) } })
    }
    func download(_ model: SpeechModel) {
        guard downloadingID == nil else { return }
        let id = UUID(); downloadOperation = id
        downloadingID = model.id; downloadFraction = 0; downloadMessage = "Downloading \(model.name)…"
        downloadTask = Task {
            do {
                _ = try await ModelStore.download(model) { [weak self] value in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.downloadOperation == id else { return }
                        self.downloadFraction = value
                        self.downloadMessage = value == nil ? "Verifying \(model.name)…" : "Downloading \(model.name)…"
                    }
                }
                guard downloadOperation == id else { return }
                downloadMessage = "\(model.name) is ready."
            } catch {
                guard downloadOperation == id else { return }
                downloadMessage = Task.isCancelled ? "Download cancelled." : error.localizedDescription
            }
            refreshModels(); downloadingID = nil; downloadTask = nil; downloadOperation = nil
        }
    }
    func cancelDownload() {
        downloadTask?.cancel()
        downloadMessage = "Cancelling download…"
    }
    func remove(_ model: SpeechModel) {
        guard !busy, downloadingID != model.id, installed[model.id]?.shared == false else { return }
        do { try ModelStore.remove(model); downloadMessage = "Removed \(model.name) from Afterword." }
        catch { downloadMessage = error.localizedDescription }
        refreshModels()
    }
    func chooseRecording() {
        guard !busy, !recordingActive, !libraryMutationActive else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.folder, .audio]
        panel.prompt = "Choose recording"; panel.message = "Choose a call folder or an audio file. Separate tracks will be transcribed together."
        if let recording { panel.directoryURL = recording.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { setRecording(url); status = nil; transcript = nil }
    }
    private func setRecording(_ url: URL) {
        if recording != url { transcript = nil; if !busy { status = nil } }
        recording = url; defaults.set(url.path, forKey: "transcriptionRecording")
    }
    func recordingSaved(_ url: URL) {
        setRecording(url)
        if autoTranscribe && !recordingActive {
            if busy || libraryMutationActive { pendingAutomaticRecording = url; return }
            refreshModels()
            if installed[selectedID] != nil { transcribe() }
            else { status = "Recording saved. Download a model in Settings to transcribe it." }
        }
    }
    func recordingStateChanged(active: Bool) {
        recordingActive = active
        if active { pendingAutomaticRecording = nil }
        if active && busy { cancel(reason: "Transcription cancelled to give recording priority. You can run it again after recording.") }
    }
    func transcribe() {
        refreshModels()
        guard canTranscribe, let recording, let installation = installed[selectedID] else { return }
        let model = selected, id = UUID(), job = TranscriptionJob()
        let cleanupEnabled = reduceSpeakerBleed
        operation = id; self.job = job; busy = true; fraction = nil; transcript = nil
        status = "Preparing \(model.name)…"
        cancellationMessage = nil
        let worker = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TranscriptionWorker")
        transcriptionTask = Task {
            do {
                let file = try await job.run(recording: recording, model: model, modelURL: installation.url, worker: worker,
                                             reduceSpeakerBleed: cleanupEnabled) { [weak self] progress in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.operation == id, self.cancellationMessage == nil else { return }
                        self.status = progress.message; self.fraction = progress.fraction
                    }
                }
                guard operation == id else { return }
                transcript = file
                if let reason = job.speakerAnalysisError {
                    status = "Transcript saved. Speaker analysis can be retried in Speakers. " + reason
                } else { status = "Transcript saved · \(model.name)" }
            } catch {
                guard operation == id else { return }
                status = error is CancellationError || Task.isCancelled ? cancellationMessage ?? "Transcription cancelled. Your recording is saved." : error.localizedDescription
            }
            busy = false; fraction = nil; operation = nil; self.job = nil; transcriptionTask = nil
            if let pending = pendingAutomaticRecording {
                pendingAutomaticRecording = nil
                if autoTranscribe, !recordingActive, self.recording == pending { transcribe() }
            }
        }
    }
    func transcribe(recording url: URL) {
        guard !busy, !recordingActive, !libraryMutationActive else { return }
        setRecording(url)
        transcribe()
    }
    func beginLibraryMutation() throws {
        guard !busy, !libraryMutationActive else { throw RecorderError.message("Wait for transcription to finish or cancel it before moving items to Trash.") }
        libraryMutationActive = true
    }
    func endLibraryMutation() {
        libraryMutationActive = false
        if let pending = pendingAutomaticRecording {
            pendingAutomaticRecording = nil
            if autoTranscribe, !recordingActive, recording == pending { transcribe() }
        }
    }
    func filesMovedToTrash(_ urls: [URL]) {
        func removed(_ file: URL?) -> Bool { file.map { file in urls.contains { CallFileOperations.contains($0, file) } } ?? false }
        if removed(recording) { recording = nil; defaults.removeObject(forKey: "transcriptionRecording"); status = nil }
        if removed(transcript) { transcript = nil; status = nil }
        if removed(pendingAutomaticRecording) { pendingAutomaticRecording = nil }
    }
    func cancel(reason: String = "Cancelling transcription…") {
        guard busy else { return }
        cancellationMessage = reason == "Cancelling transcription…" ? "Transcription cancelled. Your recording is saved." : reason
        job?.cancel(); transcriptionTask?.cancel()
        status = reason
        // Keep controls disabled until the helper exits; prevent concurrent model loads.
    }
    func shutdown() { downloadTask?.cancel(); job?.cancel(); transcriptionTask?.cancel() }
    func openTranscript() { if let transcript { NSWorkspace.shared.open(transcript) } }
    func revealTranscript() { if let transcript { NSWorkspace.shared.activateFileViewerSelecting([transcript]) } }
}

struct TranscriptionPanel: View {
    @ObservedObject var transcription: TranscriptionCoordinator
    let recordingActive: Bool
    @Binding var isExpanded: Bool
    private var expansion: Binding<Bool> {
        Binding(get: { isExpanded }, set: { expanded in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            // Override the transaction at the state change so the enclosing
            // panel's footer also moves immediately, not only this group's content.
            withTransaction(transaction) { isExpanded = expanded }
        })
    }
    var body: some View {
        DisclosureGroup(isExpanded: expansion) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Button("Choose recording…") { transcription.chooseRecording() }.controlSize(.small)
                        .disabled(transcription.busy || recordingActive)
                }
                Picker("Model", selection: $transcription.selectedID) {
                    ForEach(SpeechModel.catalog) { model in
                        Text(model.name + (transcription.installed[model.id] == nil ? " · download needed" : "")).tag(model.id)
                    }
                }.disabled(transcription.busy)
                Toggle("Reduce speaker bleed", isOn: $transcription.reduceSpeakerBleed)
                    .font(.caption).disabled(transcription.busy)
                    .help("Reduce speaker audio picked up by your microphone before transcription. Requires separate tracks; original recordings stay intact.")
                if let name = transcription.recordingName {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if transcription.busy {
                    HStack {
                        if let fraction = transcription.fraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                        Button("Cancel") { transcription.cancel() }.controlSize(.small)
                    }
                } else if transcription.installed[transcription.selectedID] == nil {
                    SettingsLink { Text("Download models in Settings…") }.font(.caption)
                } else {
                    Button("Transcribe recording") { transcription.transcribe() }.disabled(!transcription.canTranscribe || recordingActive)
                }
                if let status = transcription.status {
                    Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if transcription.transcript != nil {
                    HStack {
                        Button("Open transcript") { transcription.openTranscript() }
                        Button("Show in Finder") { transcription.revealTranscript() }
                    }.controlSize(.small)
                }
            }.padding(.top, 6)
        } label: {
            HStack {
                Label("Transcription", systemImage: "text.bubble").font(.subheadline.weight(.semibold))
                if transcription.busy {
                    Spacer()
                    ProgressView().controlSize(.small).accessibilityLabel("Transcribing")
                }
            }
        }
        .transaction {
            // Match the native popover's nonanimated content-size changes.
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }
}

struct TranscriptionSettings: View {
    @ObservedObject var transcription: TranscriptionCoordinator
    var body: some View {
        Form {
            Section {
                Picker("Use model", selection: $transcription.selectedID) {
                    ForEach(SpeechModel.catalog) { Text($0.name).tag($0.id) }
                }.disabled(transcription.busy)
                Toggle("Transcribe automatically after saving a recording", isOn: $transcription.autoTranscribe)
                Toggle("Reduce speaker bleed", isOn: $transcription.reduceSpeakerBleed).disabled(transcription.busy)
                Text("Uses the separate system track to reduce speaker audio in your microphone transcript. Original audio stays intact. Turn this off if cleanup affects your speech.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Transcription runs on your Mac. Each track is processed separately, then combined by timestamp. Models are downloaded only when you choose Download.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Models") {
                ForEach(SpeechModel.catalog) { model in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(model.name).font(.headline)
                            Spacer()
                            Text(model.sizeLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(model.detail).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if let installed = transcription.installed[model.id] {
                                Label(installed.shared ? "Available on this Mac · shared" : "Downloaded", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                                Spacer()
                                if installed.shared {
                                    Menu("More") {
                                        Button("Download a separate copy") { transcription.download(model) }.disabled(transcription.downloadingID != nil)
                                    }.menuStyle(.borderlessButton).fixedSize()
                                } else { Button("Remove") { transcription.remove(model) }.disabled(transcription.busy || transcription.downloadingID == model.id) }
                            } else if transcription.downloadingID == model.id {
                                if let fraction = transcription.downloadFraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                                Button("Cancel") { transcription.cancelDownload() }
                            } else {
                                Button("Download") { transcription.download(model) }.disabled(transcription.downloadingID != nil)
                                Spacer()
                            }
                            Link("Model details", destination: model.modelCardURL)
                        }.controlSize(.small)
                    }.padding(.vertical, 5)
                }
                if let message = transcription.downloadMessage { Text(message).font(.caption).textSelection(.enabled) }
                if let id = transcription.downloadingID, transcription.installed[id] != nil {
                    HStack {
                        if let fraction = transcription.downloadFraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                        Button("Cancel download") { transcription.cancelDownload() }
                    }
                }
            }
            Text("Handy’s compatible cached models are reused without changing Handy. Transcripts are saved in a Transcripts folder beside the recording; each run keeps its own text and JSON files. Track labels do not identify individual remote speakers.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).onAppear { transcription.refreshModels() }
    }
}
