import AVFoundation
import RecorderCore
import SwiftUI

struct SpeakerReviewSheet: View {
    let recording: LibraryRecording
    let version: LibraryTranscript
    let audio: URL
    @ObservedObject var library: RecordingLibraryModel
    @ObservedObject var calendar: CalendarCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var analysis: SpeakerAnalysis?
    @State private var profiles = VoiceProfiles()
    @State private var callID = ""
    @State private var savedNames: [String: String] = [:]
    @State private var changedNames: [String: String] = [:]
    @State private var clipIndices: [String: Int] = [:]
    @State private var error: String?
    @State private var notice: String?
    @State private var saving = false
    @StateObject private var player = VoiceClipPlayer()
    @State private var pendingForget: String?
    private var profileNames: [String: String] { profiles.names(in: calendar.directory) }
    private var attendees: [CallAttendee] { recording.details.callAttendees.filter(\.active) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Review speakers").font(.title2.weight(.semibold))
                Spacer()
                if !profileNames.isEmpty {
                    Menu("Forget voice…") {
                        ForEach(profileNames.keys.sorted { (profileNames[$0] ?? "") < (profileNames[$1] ?? "") }, id: \.self) { key in
                            Button(profileNames[key] ?? key) { pendingForget = key }
                        }
                    }.fixedSize()
                }
            }
            if let analysis {
                if analysis.intervals.isEmpty {
                    Text("No remote speakers were detected.")
                } else {
                    Text("Save speaker labels applies your choices to this transcript. Remember this clip saves an example for future calls.").foregroundStyle(.secondary)
                    if attendees.isEmpty { Text("Add people in call details to assign names.") }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Set(analysis.intervals.map(\.speaker)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { group in
                                groupRow(group, clips: analysis.clips.filter { $0.interval.speaker == group })
                                Divider()
                            }
                        }
                    }
                }
            } else if error == nil {
                HStack { ProgressView().controlSize(.small); Text("Finding voices in system audio…") }
            }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if let message = error ?? player.playbackError { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(changedNames.isEmpty ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save speaker labels") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(saving || analysis?.intervals.isEmpty != false)
            }
        }
        .padding(22).frame(width: 570, height: 480)
        .task(id: version.id) {
            savedNames = recording.details.savedSpeakerNames(for: version)
            changedNames = [:]; clipIndices = [:]; analysis = nil
            do {
                callID = try VoiceProfiles.callID(for: recording)
                profiles = try VoiceProfiles.load()
                let result = try await SpeakerAnalysisStore.bundled.analysis(for: audio)
                try Task.checkCancellation()
                clipIndices = Dictionary(grouping: result.clips, by: { $0.interval.speaker }).compactMapValues { clips in
                    clips.firstIndex { profiles.reference(for: $0, call: callID) != nil }
                }
                analysis = result
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceProfiles.changed)) { _ in
            do { profiles = try VoiceProfiles.load() } catch { self.error = error.localizedDescription }
        }
        .onDisappear { player.stop() }
        .onChange(of: calendar.locked) { _, locked in if locked { player.stop() } }
        .alert("Forget this voice?", isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }), presenting: pendingForget) { key in
            Button("Forget", role: .destructive) {
                do { profiles = try VoiceProfiles.update { $0.forget(key, in: calendar.directory) }; notice = "Removed the saved voice clips." }
                catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { key in Text("Remove all remembered voice samples for " + (profileNames[key] ?? "this person") + " from this Mac?") }
    }

    @ViewBuilder private func groupRow(_ group: String, clips: [VoiceClip]) -> some View {
        let selected = changedNames[group] ?? savedNames[group] ?? ""
        let chosen = attendees.first { $0.name == selected }
        let suggestion = profiles.suggestion(for: clips, among: attendees, excludingCall: callID, in: calendar.directory)
        let index = clipIndices[group, default: 0]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speaker " + String(group.dropFirst())).font(.headline)
                Spacer()
                Picker("Participant", selection: Binding(get: { selected }, set: { select($0, for: group) })) {
                    if savedNames[group] == nil { Text("Keep current labels").tag("") }
                    ForEach(attendees) { person in Text(recording.displayName(person.name)).tag(person.name) }
                }.labelsHidden().fixedSize().accessibilityLabel("Participant for Speaker " + String(group.dropFirst()))
            }
            if let suggestion, chosen == nil {
                let evidence = profiles.previousExamples(for: suggestion, excludingCall: callID, in: calendar.directory)
                HStack {
                    Button("Use suggested name · " + recording.displayName(suggestion.name)) { select(suggestion.name, for: group) }
                    Text("\(evidence.clips) saved \(evidence.clips == 1 ? "clip" : "clips") from \(evidence.calls) earlier \(evidence.calls == 1 ? "call" : "calls")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if clips.indices.contains(index) {
                let sample = profiles.reference(for: clips[index], call: callID)
                let owner = sample.map { VoiceProfiles.resolvedKey($0.person, in: calendar.directory) }
                let alreadyRemembered = chosen.map { VoiceProfiles.key(for: $0, in: calendar.directory) == owner } ?? false
                HStack {
                    Button { preview(clips[index]) } label: { Image(systemName: "play.fill") }.disabled(calendar.locked).help("Play this system-audio clip")
                    Picker("Example", selection: Binding(get: { index }, set: { clipIndices[group] = $0; player.stop(); notice = nil })) {
                        ForEach(clips.indices, id: \.self) { i in
                            let remembered = profiles.reference(for: clips[i], call: callID) != nil
                            Text(Transcript.timestamp(clips[i].interval.start) + (remembered ? " · Saved" : "")).tag(i)
                        }
                    }.fixedSize()
                    Spacer()
                    if !alreadyRemembered {
                        Button(sample == nil ? "Remember this clip" : "Reassign this clip") { if let chosen { remember(clips[index], as: chosen) } }
                            .disabled(chosen == nil)
                    }
                }
                if let sample, let owner {
                    Label("Remembered as " + (profileNames[owner] ?? sample.displayName), systemImage: "checkmark.circle")
                        .font(.callout)
                }
                if let chosen {
                    Text("\(profiles.count(for: chosen, in: calendar.directory)) remembered clips for \(recording.displayName(chosen.name))").font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("No isolated clip long enough to remember.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func select(_ name: String, for group: String) {
        changedNames[group] = name.isEmpty || name == savedNames[group] ? nil : name
    }

    private func preview(_ clip: VoiceClip) {
        do { try player.play(String(clip.interval.start), audio: audio, from: clip.interval.start, to: clip.interval.end) }
        catch { self.error = error.localizedDescription }
    }

    private func remember(_ clip: VoiceClip, as person: CallAttendee) {
        do {
            let current = try CallDetailsStore.load(for: recording.url, isDirectory: recording.isDirectory)
            guard current.callAttendees.contains(where: { $0 == person && $0.active }) else {
                throw RecorderError.message("Attendance changed. Reopen speaker review.")
            }
            profiles = try VoiceProfiles.update { try $0.remember(clip, as: person, call: callID, directory: calendar.directory) }
            notice = "Remembered the clip at \(Transcript.timestamp(clip.interval.start)) for \(recording.displayName(person.name))."
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard let analysis, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await library.saveSpeakers(.init(analysis: analysis, names: changedNames), version: version, recording: recording)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
