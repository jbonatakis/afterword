import AVFoundation
import RecorderCore
import SwiftUI

@MainActor final class VoiceClipPlayer: ObservableObject {
    @Published private(set) var playing: String?
    @Published private(set) var playbackError: String?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?

    func stop() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver = nil; endObserver = nil; player?.pause(); player = nil; playing = nil
    }

    func play(_ id: String, audio: URL, from start: Double, to end: Double) throws {
        stop(); playbackError = nil
        let file = try AVAudioFile(forReading: audio)
        let end = min(end, Double(file.length) / file.processingFormat.sampleRate)
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw RecorderError.message("This clip is outside the available audio.") }
        let item = AVPlayerItem(url: audio)
        item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 48_000)
        let player = AVPlayer(playerItem: item)
        self.player = player; playing = id
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "This audio could not be played."
            Task { @MainActor in
                guard self?.player === player else { return }
                self?.stop(); self?.playbackError = message
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.player === player { self?.stop() } }
        }
        player.seek(to: CMTime(seconds: start, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor [weak self] in if finished, self?.player === player { player.play() } }
        }
    }
}

struct PersonVoiceClipsView: View {
    @ObservedObject var calendar: CalendarCoordinator
    @ObservedObject var library: RecordingLibraryModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = VoiceClipPlayer()
    @State private var catalog = PersonVoiceLibrary()
    @State private var owner: String
    @State private var samples = true
    @State private var error: String?
    @State private var removal: PersonVoiceLibrary.Item?
    @State private var saving = false
    @State private var reloadID = 0
    @State private var loaded = false
    @State private var chooseInitialTab = true

    init(calendar: CalendarCoordinator, library: RecordingLibraryModel, owner: String?) {
        self.calendar = calendar; self.library = library
        _owner = State(initialValue: owner ?? "")
    }

    private var filtered: [PersonVoiceLibrary.Item] {
        catalog.items.filter { item in
            guard owner.isEmpty || item.owner == owner else { return false }
            switch item.source { case .sample: return samples; case .passage: return !samples }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Voice clips").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Person", selection: $owner) {
                Text("All people").tag("")
                ForEach(catalog.owners) { person in Text(ownerLabel(person)).tag(person.id) }
            }
            Picker("Clips", selection: $samples) {
                Text("Remembered samples").tag(true)
                Text("Transcript passages").tag(false)
            }.pickerStyle(.segmented).labelsHidden()
            Text(samples ? "These examples help Afterword recognize voices in future calls." : "Named passages from the latest transcript of each call. Changing a speaker saves a transcript version.")
                .font(.callout).foregroundStyle(.secondary)
            if let message = error ?? player.playbackError { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView(samples ? "No remembered samples" : "No assigned passages", systemImage: "waveform")
            } else {
                List(filtered) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            if player.playing == item.id { player.stop() }
                            else if let audio = item.audio {
                                do { error = nil; try player.play(item.id, audio: audio, from: item.start, to: item.end) }
                                catch { self.error = error.localizedDescription }
                            }
                        } label: { Image(systemName: player.playing == item.id ? "stop.fill" : "play.fill") }
                            .buttonStyle(.borderless).disabled(item.audio == nil || calendar.locked)
                            .accessibilityLabel(player.playing == item.id ? "Stop clip" : "Play clip")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.recording?.name ?? "Source call unavailable").font(.headline)
                            Text("\(Transcript.timestamp(item.start)) – \(Transcript.timestamp(item.end))" + (owner.isEmpty ? " · " + (catalog.owners.first { $0.id == item.owner }?.name ?? "") : ""))
                                .font(.caption).foregroundStyle(.secondary)
                            if case let .passage(_, paragraph) = item.source { Text(paragraph.text).lineLimit(3).textSelection(.enabled) }
                        }
                        Spacer()
                        Menu {
                            switch item.source {
                            case .sample(let sample):
                                ForEach(catalog.owners.filter { $0.id != item.owner && $0.attendee != nil }) { target in
                                    Button("Assign to " + ownerLabel(target)) { change(sample, to: target.attendee) }
                                }
                                Divider()
                                Button("Forget this sample…", role: .destructive) { removal = item }
                            case .passage:
                                if let recording = item.recording {
                                    ForEach(recording.details.callAttendees.filter(\.active)) { person in
                                        if VoiceProfiles.key(for: person, in: calendar.directory) != item.owner {
                                            Button("Assign to " + recording.displayName(person.name)) { assign(item, to: person.name) }
                                        }
                                    }
                                }
                                Button("Unassign passage") { assign(item, to: "") }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .fixedSize().accessibilityLabel("Clip actions").disabled(saving || library.managing)
                    }.padding(.vertical, 4)
                }
            }
        }
        .padding(20).frame(minWidth: 600, idealWidth: 680, minHeight: 440, idealHeight: 500)
        .onReceive(library.$recordings.dropFirst()) { _ in reloadID += 1 }
        .onReceive(NotificationCenter.default.publisher(for: VoiceProfiles.changed)) { _ in reloadID += 1 }
        .onChange(of: calendar.directory) { _, _ in reloadID += 1 }
        .task(id: reloadID) { await reload() }
        .onChange(of: owner) { _, _ in player.stop() }
        .onChange(of: samples) { _, _ in player.stop() }
        .onChange(of: calendar.locked) { _, locked in if locked { player.stop() } }
        .onDisappear { player.stop() }
        .alert("Forget this voice sample?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { item in
            Button("Forget", role: .destructive) { if case .sample(let sample) = item.source { change(sample, to: nil) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Afterword will stop using this sample for speaker suggestions.") }
    }

    private func ownerLabel(_ person: PersonVoiceLibrary.Owner) -> String {
        if catalog.owners.contains(where: { $0.id != person.id && $0.name == person.name }), let email = person.attendee?.email {
            return "\(person.name) (\(email))"
        }
        return person.name
    }
    private func reload() async {
        let calls = library.recordings, directory = calendar.directory
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                PersonVoiceLibrary(recordings: calls, profiles: try VoiceProfiles.load(), directory: directory)
            }.value
            guard !Task.isCancelled else { return }
            catalog = result; loaded = true
            if !owner.isEmpty && !catalog.owners.contains(where: { $0.id == owner }) { owner = "" }
            if chooseInitialTab, !result.items.isEmpty {
                if filtered.isEmpty { samples = false }
                chooseInitialTab = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            loaded = true; self.error = error.localizedDescription
        }
    }
    private func change(_ sample: VoiceReference, to person: CallAttendee?) {
        do {
            try VoiceProfiles.update { try $0.change(sample, to: person, in: calendar.directory) }
            player.stop(); error = nil
        } catch { self.error = error.localizedDescription; reloadID += 1 }
    }
    private func assign(_ item: PersonVoiceLibrary.Item, to name: String) {
        guard case .passage(let version, let paragraph) = item.source, let recording = item.recording else { return }
        guard library.recordings.first(where: { $0.id == recording.id })?.latestTranscript?.id == version.id,
              library.transcriptDrafts[recording.id] == nil else {
            error = "The transcript changed or is open for editing. Finish editing and review the latest passages."; return
        }
        saving = true; error = nil; player.stop()
        Task {
            await library.assignParticipant(name, to: paragraph.id, recording: recording, version: version)
            error = library.participantAssignments[recording.id]?.error
            saving = false
        }
    }
}
