import SwiftUI
import AppKit
import CoreAudio
import RecorderCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = RecordingCoordinator()
    private var statusItem: RecorderStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = RecorderStatusItem(recorder: recorder)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        recorder.shouldQuit()
    }
    func applicationWillTerminate(_ notification: Notification) {
        recorder.transcription.shutdown()
        recorder.shortcut.shutdown()
        statusItem?.shutdown()
    }
}

@main struct CallRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings {
            TabView {
                RecorderSettings(recorder: delegate.recorder).tabItem { Label("Recording", systemImage: "waveform") }
                TranscriptionSettings(transcription: delegate.recorder.transcription).tabItem { Label("Transcription", systemImage: "text.bubble") }
            }.padding(12).frame(width: 560, height: 640)
        }
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
                    Text("Call Recorder").font(.headline)
                    Label(recorder.title, systemImage: recorder.state == .recording ? "record.circle" : "waveform")
                        .font(.caption).foregroundStyle(recorder.state == .recording ? .red : .secondary)
                }
                Spacer()
                Text(recorder.elapsed).font(.system(.title2, design: .monospaced)).monospacedDigit()
            }
            if !recorder.noticesAccepted {
                Text("Save your microphone and system audio as separate tracks, plus a mixed recording for playback. macOS will ask for each permission when you start or test.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Notices()
                Button("Got it") { recorder.acceptNotices() }
            }
            SourcePicker(recorder: recorder)
            VStack(spacing: 10) {
                LevelMeter(title: "Microphone", level: recorder.snapshot.microphonePeak, off: !recorder.recordMicrophone)
                LevelMeter(title: "System audio", level: recorder.snapshot.systemPeak, off: false)
            }
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
                                            Button("Export to selected destination") { recorder.recover(candidate, useCurrentDestination: true) }.disabled(!candidate.canRecover)
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
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                Spacer()
                Menu {
                    Button("Copy diagnostics") { recorder.copyDiagnostics() }
                    Button("Quit Call Recorder") { NSApp.terminate(nil) }
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
                VStack(alignment: .trailing) {
                    Text(recorder.destination.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).lineLimit(2)
                    Button("Choose folder…") { recorder.chooseDestination() }.disabled(recorder.locked)
                }
            }
            Text("Each recording gets a dated folder with Microphone.m4a, System.m4a, and Mixed.m4a. The tracks share the same start time and duration.").font(.caption).foregroundStyle(.secondary)
            Text("Audio stays local. Your selected folder may be synced or backed up by another service.").font(.caption).foregroundStyle(.secondary)
            RecordingShortcutSettings(shortcut: recorder.shortcut)
            Divider()
            Notices()
        }.formStyle(.grouped)
    }
}
