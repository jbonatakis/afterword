import SwiftUI
import Combine
import AppKit
import CoreAudio
import RecorderCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = RecordingCoordinator(enabled: false)
    lazy var library = RecordingLibraryModel(recorder: recorder)
    lazy var playback = RecordingPlayback(recorder: recorder)
    private var sourceSubscription: AnyCancellable?
    private var statusItem: RecorderStatusItem?
    private lazy var libraryWindow = RecordingLibraryWindow(
        library: library, recorder: recorder, playback: playback,
        showControls: { [weak self] in self?.showRecordingControls() })

    func applicationDidFinishLaunching(_ notification: Notification) {
        sourceSubscription = library.$sources.map { $0.contains(.recordings) }.removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            if enabled {
                recorder.calendar.startMonitoring()
                statusItem = RecorderStatusItem(recorder: recorder, showLibrary: { [weak self] in self?.showLibrary() })
            } else if statusItem != nil {
                recorder.calendar.shutdown()
                statusItem?.shutdown(); statusItem = nil
                playback.clear()
            }
            LibraryKeyboardMenus.install(recordings: enabled)
        }
        DispatchQueue.main.async { [weak self] in
            self?.showLibrary()
            if let self { LibraryKeyboardMenus.install(recordings: library.sources.contains(.recordings)) }
        }
    }
    func showLibrary() { libraryWindow.present() }
    func showRecordingControls() { statusItem?.showPopover() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if library.managing {
            showLibrary()
            let alert = NSAlert(); alert.messageText = "A change is still saving"
            alert.informativeText = "Wait for it to finish, then quit Afterword."; alert.runModal()
            return .terminateCancel
        }
        if library.hasUnsavedEdits {
            showLibrary()
            let alert = NSAlert(); alert.messageText = "Discard unsaved edits and quit?"
            alert.informativeText = "There are unsaved call, summary, or transcript edits in the library."
            alert.addButton(withTitle: "Keep Editing"); alert.addButton(withTitle: "Discard Edits and Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        return recorder.shouldQuit()
    }
    func applicationWillTerminate(_ notification: Notification) {
        library.shutdown()
        if recorder.sourceEnabled { recorder.calendar.shutdown(); recorder.shortcut.shutdown() }
        recorder.transcription.shutdown()
        playback.shutdown()
        statusItem?.shutdown()
    }
}

@main struct AfterwordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings {
            AfterwordSettings(library: delegate.library, recorder: delegate.recorder)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Show Library") {
                    delegate.library.destination = .activity(delegate.library.filter)
                    delegate.showLibrary()
                }.keyboardShortcut("1", modifiers: .command)
                RecordingMenuCommands(library: delegate.library, showLibrary: delegate.showLibrary)
            }
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") { delegate.library.sidebarVisible.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { LibraryKeyboardMenus.showHelp(recordings: delegate.library.sources.contains(.recordings)) }
            }
        }
    }
}

private struct RecordingMenuCommands: View {
    @ObservedObject var library: RecordingLibraryModel
    let showLibrary: () -> Void

    var body: some View {
        if library.sources.contains(.recordings) {
            Button("Upcoming Calls") { open(.upcoming) }.keyboardShortcut("2", modifiers: .command)
            Button("People & Groups") { open(.people) }
        }
    }

    private func open(_ page: LibraryCalendarPage) {
        library.destination = .calendar(page)
        showLibrary()
    }
}

private struct AfterwordSettings: View {
    @ObservedObject var library: RecordingLibraryModel
    @ObservedObject var recorder: RecordingCoordinator

    var body: some View {
        TabView(selection: $library.settingsTab) {
            Form {
                Section("Library sources") {
                    SourceToggles(selection: Binding(get: { library.sources }, set: { library.setSources($0) }),
                                  destination: $recorder.destination, recordingLocked: recorder.locked)
                    Text("Turning off a source pauses its background work and hides it from the library and connected agents. Turn it on again to restore your setup.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = library.sourceError { Text(error).foregroundStyle(.red) }
                }
            }.formStyle(.grouped).tabItem { Label("Sources", systemImage: "rectangle.stack") }.tag("sources")
            if library.sources.contains(.recordings) {
                RecorderSettings(recorder: recorder).tabItem { Label("Recording", systemImage: "waveform") }.tag("recordings")
                TranscriptionSettings(transcription: recorder.transcription).tabItem { Label("Transcription", systemImage: "text.bubble") }.tag("transcription")
                CalendarSettings(calendar: recorder.calendar).tabItem { Label("Calendar", systemImage: "calendar") }.tag("calendar")
            }
            if library.sources.contains(.coding) {
                CodingSettingsView(coding: library.coding).tabItem { Label("Coding", systemImage: "terminal") }.tag("coding")
            }
            if library.sources.contains(.github) {
                GitHubSettingsView(github: library.github).tabItem { Label("GitHub", systemImage: "arrow.triangle.branch") }.tag("github")
            }
            EmbeddingSettingsView(library: library, embeddings: library.embeddings).tabItem { Label("Search", systemImage: "magnifyingglass") }.tag("search")
            AgentAccessSettings(library: library).tabItem { Label("Agent Access", systemImage: "point.3.connected.trianglepath.dotted") }.tag("agents")
        }.padding(12).frame(width: 620, height: 640)
    }
}

private struct Notices: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("System audio includes sounds from other apps and notifications.")
            Text("Your microphone is recorded independently of the call. Muting yourself in Zoom, Meet, or Teams does not mute this recorder.")
            Text("Use headphones to avoid recording the call audio again through your microphone. Get any required permission before recording.")
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct RecorderView: View {
    @ObservedObject var recorder: RecordingCoordinator
    var showLibrary: () -> Void = {}
    @State private var transcriptionExpanded = false
    var body: some View {
        ViewThatFits(in: .vertical) {
            panelContent
            ScrollView { panelContent }
        }
        .frame(width: 400)
        .frame(maxHeight: min(780, (NSScreen.main?.visibleFrame.height ?? 860) - 80))
        .fixedSize(horizontal: false, vertical: true)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Afterword").font(.headline)
                    Label(recorder.title, systemImage: recorder.state == .recording ? "record.circle" : "waveform")
                        .font(.caption).foregroundStyle(recorder.state == .recording ? .red : .secondary)
                }
                Spacer()
                ElapsedRecordingTime(clock: recorder.telemetry.clock)
            }
            if !recorder.noticesAccepted {
                Text("Save your microphone and system audio as separate tracks, plus a mixed recording for playback. macOS will ask for each permission when you start or test.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Notices()
                Button("Got it") { recorder.acceptNotices() }
            }
            SourcePicker(recorder: recorder)
            RecordingMeters(telemetry: recorder.telemetry, microphoneEnabled: recorder.recordMicrophone)
            Toggle("Personal recording", isOn: Binding(get: { recorder.personalRecording }, set: recorder.setPersonalRecording))
                .help("Keep this call in Recordings → Personal and out of work history. Applies to this recording only.")
                .disabled(recorder.savingScope || (recorder.locked && recorder.state != .recording))
            Toggle("Record microphone", isOn: $recorder.recordMicrophone)
                .help("Mutes the microphone track and playback mix. It does not mute the microphone sent to your call.")
                .disabled(recorder.state == .finalizing)
            if recorder.isPreview {
                Text("Speak and play audio in another app. This test ends when you close this panel or after 60 seconds. Nothing is saved.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message = recorder.message {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if recorder.state == .needsPermission || recorder.state == .error {
                Button("Open System Settings") { recorder.openSystemSettings() }
            }
            if recorder.state == .finalizing {
                HStack { ProgressView().controlSize(.small); Text("Saving…").font(.callout) }.frame(maxWidth: .infinity)
            } else if recorder.locked {
                Button { recorder.stop() } label: {
                    Label(recorder.state == .preparing ? "Cancel preparation" : recorder.isPreview ? "End audio test" : "Stop recording", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
            } else {
                Button { recorder.start() } label: {
                    Label("Start recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(recorder.resolved == nil || recorder.selectedChannel < 0)
                Button("Test audio") { recorder.start(preview: true) }.frame(maxWidth: .infinity)
                    .disabled(recorder.resolved == nil || recorder.selectedChannel < 0)
            }
            if let file = recorder.savedFile {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(file.lastPathComponent == RecordingTrack.mixed.filename ? "Saved mix + separate tracks" : "Saved", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                        Text(file.lastPathComponent == RecordingTrack.mixed.filename ? file.deletingLastPathComponent().lastPathComponent : file.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Show in Finder") { recorder.reveal(file) }.controlSize(.small)
                }
            }
            RecordingShortcutHint(shortcut: recorder.shortcut)
            if !recorder.locked, !recorder.recoveries.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(recorder.recoveries.count) recoverable session\(recorder.recoveries.count == 1 ? "" : "s")").font(.subheadline.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(recorder.recoveries) { candidate in
                                VStack(alignment: .leading, spacing: 6) {
                                    if let date = candidate.startDate { Text(date, style: .date).font(.caption.weight(.medium)) }
                                    Text(candidate.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    HStack {
                                        Button("Recover recording") { recorder.recover(candidate) }.disabled(!candidate.canRecover)
                                        Menu("More") {
                                            Button(recorder.destination == nil ? "Choose export folder…" : "Export to selected destination") {
                                                recorder.recover(candidate, useCurrentDestination: true)
                                            }.disabled(!candidate.canRecover)
                                            Button("Show recovery files") { recorder.reveal(candidate.directory) }
                                        }.menuStyle(.borderlessButton)
                                    }
                                }
                            }
                        }
                    }.frame(height: min(180, CGFloat(recorder.recoveries.count * 110)))
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            TranscriptionPanel(transcription: recorder.transcription, recordingActive: recorder.locked, isExpanded: $transcriptionExpanded)
            Divider()
            HStack {
                Button(action: showLibrary) { Label("Library", systemImage: "rectangle.stack") }
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                Spacer()
                Menu {
                    Button("Copy diagnostics") { recorder.copyDiagnostics() }
                    Button("Quit Afterword") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }.font(.caption)
        }.fixedSize(horizontal: false, vertical: true).padding(20)
    }
}

private struct SourcePicker: View {
    @ObservedObject var recorder: RecordingCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Microphone", selection: Binding(get: { recorder.selectedUID }, set: recorder.chooseDevice)) {
                Text("System default").tag(String?.none)
                if let uid = recorder.selectedUID, !recorder.devices.contains(where: { $0.uid == uid }) {
                    Text("Selected microphone unavailable").tag(String?.some(uid))
                }
                ForEach(recorder.devices) { device in Text(DeviceSelection.displayName(device, in: recorder.devices)).tag(String?.some(device.uid)) }
            }
            Text(recorder.resolved.map { DeviceSelection.displayName($0, in: recorder.devices) } ?? "Selected microphone unavailable")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if recorder.resolved?.transport == kAudioDeviceTransportTypeBuiltIn {
                Text("On a Mac laptop, closing the lid disconnects the built-in microphone. Choose an external microphone for closed-lid recording.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if recorder.channelRequired, let device = recorder.resolved {
                Picker("Channel", selection: Binding(get: { recorder.selectedChannel }, set: recorder.chooseChannel)) {
                    Text("Choose and test a channel").tag(-1)
                    ForEach(device.channels.indices, id: \.self) { index in Text(device.channels[index]).tag(index) }
                }
                if device.needsExplicitVerification {
                    Text("Verify that this input is your microphone and does not include a playback/loopback mix.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.disabled(recorder.locked)
    }
}

private struct ElapsedRecordingTime: View {
    @ObservedObject var clock: RecordingClock

    var body: some View {
        Text(clock.text).font(.system(.title2, design: .monospaced)).monospacedDigit()
    }
}

private struct RecordingMeters: View {
    @ObservedObject var telemetry: RecordingTelemetry
    let microphoneEnabled: Bool

    var body: some View {
        VStack(spacing: 10) {
            LevelMeter(title: "Microphone", level: telemetry.snapshot.microphonePeak, off: !microphoneEnabled)
            LevelMeter(title: "System audio", level: telemetry.snapshot.systemPeak, off: false)
        }
    }
}

private struct LevelMeter: View {
    let title: String
    let level: Float
    let off: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.caption).frame(width: 86, alignment: .leading)
            GeometryReader { geometry in
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.97 ? Color.orange : Color.accentColor)
                    .frame(width: geometry.size.width * (off ? 0 : CGFloat(max(0, min(1, (20 * log10(max(level, 0.001)) + 60) / 60)))))
            }.frame(height: 6).accessibilityHidden(true)
            Text(off ? "Off" : level < 0.001 ? "Quiet" : "On").font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(title): \(off ? "Off" : level < 0.001 ? "Quiet" : "Audio detected")")
    }
}

struct RecorderSettings: View {
    @ObservedObject var recorder: RecordingCoordinator
    var body: some View {
        Form {
            SourcePicker(recorder: recorder)
            LabeledContent("Save recordings to") {
                RecordingFolderPicker(destination: $recorder.destination).disabled(recorder.locked)
            }
            Text("Each recording gets a dated folder with Microphone.m4a, System.m4a, and Mixed.m4a. The tracks share the same start time and duration.").font(.caption).foregroundStyle(.secondary)
            Text("Audio stays local. Your selected folder may be synced or backed up by another service.").font(.caption).foregroundStyle(.secondary)
            Toggle("Balance voice volume in the saved mix", isOn: $recorder.balanceMix).disabled(recorder.locked)
            Text("Brings quiet microphone speech and louder call audio to similar listening levels, with gentle compression and peak protection. The separate tracks keep their original levels for transcription.")
                .font(.caption).foregroundStyle(.secondary)
            RecordingShortcutSettings(shortcut: recorder.shortcut)
            Divider()
            Notices()
        }.formStyle(.grouped)
    }
}
