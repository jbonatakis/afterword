import SwiftUI
import AppKit
import RecorderCore

struct RecordingLibraryView: View {
    @ObservedObject var library: RecordingLibraryModel
    @ObservedObject var recorder: RecordingCoordinator
    let playback: RecordingPlayback
    let showControls: () -> Void
    @State private var editor: CallEditor?
    @State private var trashTarget: TrashTarget?
    @State private var managementError: String?

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { library.sidebarVisible ? .all : .doubleColumn }, set: { library.sidebarVisible = $0 == .all })) {
            VStack(spacing: 0) {
                List(selection: $library.filter) {
                    Section("Library") {
                        ForEach(LibraryFilter.allCases) { filter in
                            Label(filter.rawValue, systemImage: filter.symbol).tag(filter)
                        }
                    }
                }.listStyle(.sidebar)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    TranscriptionActivity(transcription: recorder.transcription)
                    Menu {
                        Button("Add recordings folder…") { library.addFolder() }
                        Divider()
                        ForEach(library.roots, id: \.path) { folder in
                            Menu(folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) {
                                Button("Show in Finder") { recorder.reveal(folder) }
                                Button("Remove from library") { library.removeFolder(folder) }
                                    .disabled(folder == recorder.destination.resolvingSymlinksInPath().standardizedFileURL)
                            }
                        }
                    } label: { Label("Recording folders", systemImage: "folder") }
                        .menuStyle(.borderlessButton)
                    SettingsLink { Label("Settings", systemImage: "gearshape") }.buttonStyle(.plain)
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
        } content: {
            VStack(spacing: 0) {
                if library.visibleRecordings.isEmpty {
                    ContentUnavailableView {
                        Label(library.search.isEmpty ? "No recordings" : "No results", systemImage: library.search.isEmpty ? "waveform" : "magnifyingglass")
                    } description: {
                        Text(library.search.isEmpty ? "Record a call or add a folder of existing recordings." : "Try another phrase or a different library filter.")
                    }
                } else {
                    List(selection: $library.selection) {
                        ForEach(library.visibleRecordings) { recording in
                            RecordingRow(recording: recording, query: library.search).tag(recording.id)
                                .contextMenu {
                                    Button("Rename or edit details…") { editor = .details(recording) }.disabled(library.managing)
                                    Button("Show in Finder") { recorder.reveal(recording.url) }
                                    Divider()
                                    Button("Move to Trash…", role: .destructive) { trashTarget = .init(recording: recording) }
                                        .disabled(library.managing || recorder.locked)
                                }
                        }
                    }.listStyle(.inset)
                }
                Divider()
                HStack {
                    Text("\(library.visibleRecordings.count) recording\(library.visibleRecordings.count == 1 ? "" : "s")")
                    Spacer()
                    if library.refreshing { ProgressView().controlSize(.mini) }
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }
            .navigationTitle(library.filter.rawValue)
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            if let recording = library.selectedRecording {
                RecordingDetail(recording: recording, query: library.search, library: library, recorder: recorder, transcription: recorder.transcription, playback: playback,
                                edit: { editor = $0 }, trash: { trashTarget = .init(recording: recording, version: $0) })
                    .id(recording.id)
            } else {
                ContentUnavailableView("Select a recording", systemImage: "waveform", description: Text("Your audio and transcripts, together in one place."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $library.search, placement: .toolbar, prompt: "Search recordings and transcripts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { library.refresh() } label: { Label("Refresh library", systemImage: "arrow.clockwise") }
                    .help("Refresh recordings and transcripts")
                Button(action: showControls) { Label("Recording controls", systemImage: "slider.horizontal.3") }
                    .help("Microphone, audio levels, and recording controls")
                Button {
                    if !recorder.noticesAccepted { showControls() }
                    else { recorder.toggleRecording() }
                } label: {
                    Label(recorder.locked ? recorder.state == .finalizing ? "Saving…" : "Stop" : "Record",
                          systemImage: recorder.locked ? "stop.fill" : "record.circle")
                }
                .tint(recorder.locked ? .red : .accentColor)
                .disabled(recorder.state == .finalizing || (!recorder.locked && (recorder.resolved == nil || recorder.selectedChannel < 0)))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if recorder.locked || recorder.message != nil {
                HStack {
                    Label(recorder.title, systemImage: recorder.locked ? "record.circle" : "exclamationmark.circle")
                        .foregroundStyle(recorder.locked ? .red : .orange)
                    if recorder.locked { Text(recorder.elapsed).monospacedDigit() }
                    if let message = recorder.message { Text(message).lineLimit(2) }
                    Spacer()
                }.font(.callout).padding(10).background(.bar)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !library.issues.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(library.issues.joined(separator: "\n")).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { library.refresh() }
                }.font(.caption).padding(10).background(.bar)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 940, minHeight: 600)
        .sheet(item: $editor) { editor in
            switch editor {
            case .details(let recording): CallDetailsEditor(recording: recording, library: library)
            case .transcript(let recording, let version): TranscriptEditor(recording: recording, version: version, library: library)
            }
        }
        .confirmationDialog(trashTarget?.title ?? "Move to Trash?", isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } }), titleVisibility: .visible, presenting: trashTarget) { target in
            Button("Move to Trash", role: .destructive) {
                Task {
                    do { try await library.moveToTrash(target.recording, version: target.version, playback: playback) }
                    catch { managementError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in Text(target.message) }
        .alert("Couldn’t move to Trash", isPresented: Binding(get: { managementError != nil }, set: { if !$0 { managementError = nil } })) {
            Button("OK", role: .cancel) { managementError = nil }
        } message: { Text(managementError ?? "") }
        .onChange(of: library.selectedRecording?.id) { _, _ in
            if let recording = library.selectedRecording { playback.select(recording) }
            else { playback.clear() }
        }
        .onChange(of: library.search) { _, _ in reconcileSelection() }
        .onChange(of: library.filter) { _, _ in reconcileSelection() }
    }

    private func reconcileSelection() {
        if library.selectedRecording == nil { library.selection = library.visibleRecordings.first?.id }
    }
}

private struct TrashTarget {
    let recording: LibraryRecording
    var version: LibraryTranscript? = nil
    var title: String { version == nil ? "Move “\(recording.name)” to Trash?" : "Move this transcript version to Trash?" }
    var message: String {
        version == nil ? "The call’s audio, details, and associated transcripts will move to the Mac’s Trash. You can restore them from there."
            : "This version’s text and JSON files will move to Trash. The recording and other transcript versions will remain."
    }
}

private struct RecordingRow: View {
    let recording: LibraryRecording
    let query: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(recording.name).font(.headline).lineLimit(2).truncationMode(.middle)
            HStack(spacing: 6) {
                Text(recording.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                if let duration = recording.duration { Text("·"); Text(Transcript.timestamp(duration)) }
            }.font(.caption).foregroundStyle(.secondary)
            if let passage = recording.matchingPassage(query) {
                Text(passage).font(.caption).lineLimit(3).foregroundStyle(.secondary)
            } else {
                Label(recording.hasTranscript ? "Transcript available" : recording.transcripts.isEmpty ? "Not transcribed" : "Transcript needs attention",
                      systemImage: recording.hasTranscript ? "text.bubble" : "waveform")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }
}

private struct RecordingDetail: View {
    let recording: LibraryRecording
    let query: String
    @ObservedObject var library: RecordingLibraryModel
    @ObservedObject var recorder: RecordingCoordinator
    @ObservedObject var transcription: TranscriptionCoordinator
    let playback: RecordingPlayback
    let edit: (CallEditor) -> Void
    let trash: (LibraryTranscript?) -> Void
    @State private var versionID: String?

    private var version: LibraryTranscript? {
        recording.transcripts.first { $0.id == versionID } ?? recording.latestTranscript
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(recording.name).font(.title2.weight(.semibold)).textSelection(.enabled).lineLimit(3)
                    Spacer()
                    Menu {
                        Button("Rename or edit details…") { edit(.details(recording)) }
                        Button("Show in Finder") { recorder.reveal(recording.url) }
                        Divider()
                        Button("Move call to Trash…", role: .destructive) { trash(nil) }.disabled(recorder.locked || transcription.busy)
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                        .help("Call actions").accessibilityLabel("Call actions").disabled(library.managing)
                }
                HStack {
                    Text(recording.date, format: .dateTime.weekday().month().day().year().hour().minute())
                    Spacer()
                    Button { edit(.details(recording)) } label: { Label("Edit details", systemImage: "pencil") }.disabled(library.managing)
                }.font(.callout).foregroundStyle(.secondary)
                if !recording.details.participants.isEmpty {
                    Label(recording.details.participants.joined(separator: ", "), systemImage: "person.2").font(.callout).lineLimit(2).textSelection(.enabled)
                }
                if !recording.details.tags.isEmpty {
                    Label(recording.details.tags.joined(separator: " · "), systemImage: "tag").font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                if !recording.details.description.isEmpty {
                    Text(recording.details.description).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
                if let error = recording.detailsError {
                    Label("Couldn’t read call details: " + error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
                HStack {
                    Text("Transcript").font(.headline)
                    Spacer()
                    if let document = version?.document {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(document.readableText(recordingName: recording.name), forType: .string)
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .help("Copy readable transcript")
                        Button { if let version { edit(.transcript(recording, version)) } } label: { Label("Edit", systemImage: "pencil") }
                            .help("Edit transcript text").disabled(library.managing || document.paragraphs.isEmpty)
                    }
                    Button(recording.transcripts.isEmpty ? "Transcribe" : "Transcribe again") {
                        transcription.transcribe(recording: recording.url)
                    }.disabled(transcription.busy || library.managing || recorder.locked || transcription.installed[transcription.selectedID] == nil)
                        .help("Transcribe with \(transcription.selected.name)")
                }
                HStack {
                    if recording.transcripts.count > 1 {
                        Picker("Version", selection: Binding(get: { version?.id ?? "" }, set: { versionID = $0; library.preferredTranscriptID = nil })) {
                            ForEach(recording.transcripts) { version in
                                Text("\(version.document?.editing == nil ? "" : "Edited · ")\(version.document?.modelName ?? "Unreadable transcript") · \(version.date.formatted(date: .abbreviated, time: .shortened))").tag(version.id)
                            }
                        }.font(.caption)
                    } else if let document = version?.document {
                        Text((document.editing == nil ? "" : "Edited · ") + document.modelName + " · " + document.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let version {
                        Spacer(minLength: 0)
                        Menu {
                            Button("Show transcript in Finder") { recorder.reveal(version.url) }
                            Divider()
                            Button("Move version to Trash…", role: .destructive) { trash(version) }
                                .disabled(recorder.locked || transcription.busy)
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            .help("Transcript version actions").accessibilityLabel("Transcript version actions").disabled(library.managing)
                    }
                }
            }.padding(24)
            Divider()
            if let document = version?.document {
                ReadableTranscript(paragraphs: document.paragraphs, edited: document.editing != nil, query: query, playback: playback, playbackDisabled: recorder.locked)
                    .id(version?.id)
            } else if let error = version?.error {
                ContentUnavailableView {
                    Label("Couldn’t read this transcript", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Show transcript file") { if let url = version?.url { recorder.reveal(url) } }
                }
            } else {
                ContentUnavailableView {
                    Label("Ready when you are", systemImage: "text.bubble")
                } description: {
                    Text("Generate a transcript to read and search this recording. Audio is processed locally on your Mac.")
                } actions: {
                    if transcription.installed[transcription.selectedID] == nil {
                        SettingsLink { Text("Choose a model in Settings") }
                    } else {
                        Text("Selected model: \(transcription.selected.name)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            PlaybackBar(recording: recording, playback: playback, disabled: recorder.locked)
        }
        .onAppear { playback.select(recording); selectMatchingVersion() }
        .onChange(of: query) { _, _ in selectMatchingVersion() }
        .onChange(of: recording.transcripts.map(\.id)) { _, _ in versionID = nil; selectMatchingVersion() }
    }
    private func selectMatchingVersion() {
        if let preferred = library.preferredTranscriptID, recording.transcripts.contains(where: { $0.id == preferred }) {
            versionID = preferred; library.preferredTranscriptID = nil; return
        }
        guard !query.isEmpty else { return }
        if let matching = recording.transcripts.first(where: { $0.document?.paragraphs.contains { $0.text.localizedStandardContains(query) } == true }) {
            versionID = matching.id
        }
    }
}

private struct ReadableTranscript: View {
    let paragraphs: [TranscriptParagraph]
    let edited: Bool
    let query: String
    @ObservedObject var playback: RecordingPlayback
    let playbackDisabled: Bool
    private var firstMatch: Int? {
        query.isEmpty ? nil : paragraphs.first { $0.text.localizedStandardContains(query) }?.id
    }
    var body: some View {
        if paragraphs.isEmpty {
            ContentUnavailableView(edited ? "Transcript is empty" : "No speech detected", systemImage: "waveform",
                                   description: Text(edited ? "This edited version has no text. Choose another version or transcribe the recording again." : "You can listen to the audio or try another transcription model."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(paragraphs) { paragraph in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 10) {
                                    Circle().fill(paragraph.source == .microphone ? Color.accentColor : .secondary).frame(width: 7, height: 7)
                                    Text(paragraph.source.label).font(.callout.weight(.semibold))
                                    Button(Transcript.timestamp(paragraph.start)) {
                                        playback.seek(paragraph.start); playback.play()
                                    }.buttonStyle(.plain).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        .disabled(playbackDisabled || !playback.ready)
                                        .help("Play from \(Transcript.timestamp(paragraph.start))")
                                        .accessibilityLabel("Play from \(Transcript.timestamp(paragraph.start))")
                                    Spacer()
                                    if playback.playing && playback.position >= paragraph.start && playback.position < paragraph.end {
                                        Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text(highlighted(paragraph.text)).font(.system(size: 15)).lineSpacing(5)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.id(paragraph.id)
                        }
                        Text("Labels follow the audio tracks. Other participants may include multiple people.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: 760).padding(28).frame(maxWidth: .infinity)
                }
                .onAppear { if let firstMatch { proxy.scrollTo(firstMatch, anchor: .top) } }
                .onChange(of: query) { _, _ in if let firstMatch { proxy.scrollTo(firstMatch, anchor: .top) } }
            }
        }
    }
    private func highlighted(_ text: String) -> AttributedString {
        let result = NSMutableAttributedString(string: text)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return AttributedString(result) }
        let string = text as NSString
        var search = NSRange(location: 0, length: string.length)
        while search.length > 0 {
            let range = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            guard range.location != NSNotFound, range.length > 0 else { break }
            result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: range)
            search = NSRange(location: NSMaxRange(range), length: string.length - NSMaxRange(range))
        }
        return AttributedString(result)
    }
}

private struct PlaybackBar: View {
    let recording: LibraryRecording
    @ObservedObject var playback: RecordingPlayback
    let disabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if disabled { Text("Playback is paused while recording or testing audio.").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 14) {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
                }.buttonStyle(.plain).accessibilityLabel(playback.playing ? "Pause playback" : "Play recording")
                    .disabled(disabled || !playback.ready)
                Text(Transcript.timestamp(playback.position)).font(.caption.monospacedDigit()).frame(width: 60)
                Slider(value: Binding(get: { playback.position }, set: playback.seek), in: 0...max(0.01, playback.duration))
                    .accessibilityLabel("Playback position").disabled(!playback.ready || disabled)
                Text(Transcript.timestamp(playback.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60)
            }
            HStack {
                Picker("Audio", selection: Binding(get: { playback.source }, set: { playback.changeTrack($0, in: recording) })) {
                    ForEach(recording.tracks) { Text($0.label).tag($0.source) }
                }.labelsHidden().frame(maxWidth: 180).disabled(disabled)
                Spacer()
                Text("Click a transcript timestamp to listen").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).background(.bar)
    }
}

private struct TranscriptionActivity: View {
    @ObservedObject var transcription: TranscriptionCoordinator
    var body: some View {
        if let status = transcription.status {
            VStack(alignment: .leading, spacing: 8) {
                if transcription.busy {
                    Text(transcription.recordingName ?? "Transcribing").font(.caption.weight(.medium)).lineLimit(2)
                    if let fraction = transcription.fraction { ProgressView(value: fraction) }
                    else { ProgressView().controlSize(.small) }
                }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                if transcription.busy { Button("Cancel transcription") { transcription.cancel() }.font(.caption) }
            }
            Divider()
        }
    }
}
