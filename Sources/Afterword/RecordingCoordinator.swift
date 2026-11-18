import SwiftUI
import AppKit
import AVFoundation
import CoreAudio
import IOKit.pwr_mgt
import RecorderCore

@MainActor final class RecordingCoordinator: ObservableObject {
    let transcription: TranscriptionCoordinator
    lazy var shortcut = RecordingShortcut(register: false)
    private(set) var sourceEnabled = false
    let peopleURL: URL
    lazy var calendar = CalendarCoordinator(recorder: self, directoryURL: peopleURL)
    @Published private(set) var state: RecordingState = .idle {
        didSet { transcription.recordingStateChanged(active: locked) }
    }
    @Published var devices: [InputDevice] = []
    @Published var selectedUID: String?
    @Published var selectedChannel = -1
    @Published var destination: URL
    @Published var balanceMix = UserDefaults.standard.object(forKey: "balanceMix") as? Bool ?? true { didSet { defaults.set(balanceMix, forKey: "balanceMix") } }
    @Published var recordMicrophone = true { didSet { engine?.setMicrophoneEnabled(recordMicrophone) } }
    @Published var resolved: InputDevice?
    @Published var snapshot = PipelineSnapshot()
    @Published var message: String?
    @Published var savedFile: URL?
    @Published var recoveries: [RecoveryCandidate] = []
    @Published var noticesAccepted: Bool
    private var lifecycle = Lifecycle()
    private var engine: RecordingEngine?
    private var channelPreferences: [String: ChannelPreference] = [:]
    private var observers: [HALObservation] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var preferenceObservers: [HALObservation] = []
    private var preview = false
    private var engineStarted = false
    private var sleepAssertion: IOPMAssertionID = 0
    private var hasSleepAssertion = false
    private var quitting = false
    private var lastFormats: [SourceFormat] = []
    private var lastLayout: CaptureLayout?
    private let defaults = UserDefaults.standard

    var locked: Bool { [.preparing, .recording, .previewing, .finalizing].contains(state) }
    var capturing: Bool { state == .recording || state == .previewing }
    var isPreview: Bool { preview && locked }
    var selection: MicrophoneSelection { selectedUID.map { .device(uid: $0) } ?? .systemDefault }
    var channelRequired: Bool { (resolved?.channels.count ?? 0) > 1 || resolved?.needsExplicitVerification == true || (resolved != nil && selectedChannel < 0) }
    var elapsed: String {
        let seconds = Int(snapshot.frames / 48_000)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var title: String {
        switch state {
        case .idle: return savedFile == nil ? "Ready to record" : "Saved"
        case .preparing: return "Preparing…"
        case .recording: return "Recording"
        case .previewing: return "Testing audio · not saving"
        case .finalizing: return "Saving…"
        case .needsPermission: return "Permission needed"
        case .error: return "Recording stopped"
        case .recoverable: return "Recoverable recording"
        }
    }
    init(peopleURL: URL? = nil, enabled: Bool = true) {
        transcription = TranscriptionCoordinator(loadRecording: false)
        self.peopleURL = peopleURL ?? PeopleDirectory.fileURL
        destination = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "destination") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Call Recordings").path, isDirectory: true)
        noticesAccepted = UserDefaults.standard.bool(forKey: "noticesAccepted")
        if let data = defaults.data(forKey: "selection"), let selection = try? JSONDecoder().decode(MicrophoneSelection.self, from: data), case .device(let uid) = selection { selectedUID = uid }
        if let data = defaults.data(forKey: "channels"), let choices = try? JSONDecoder().decode([String: ChannelPreference].self, from: data) { channelPreferences = choices }
        if enabled { setSourceEnabled(true) }
    }

    func setSourceEnabled(_ enabled: Bool) {
        guard enabled != sourceEnabled, !locked else { return }
        sourceEnabled = enabled
        guard enabled else {
            shortcut.shutdown()
            observers.removeAll(); preferenceObservers.removeAll()
            for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            workspaceObservers.removeAll()
            engine = nil; resolved = nil; devices = []; selectedChannel = -1
            message = nil; recoveries = []
            return
        }
        transcription.restoreRecording()
        shortcut.start()
        engine = RecordingEngine { [weak self] event in Task { @MainActor in self?.receive(event) } }
        do { observers = try DeviceCatalog.observe { [weak self] in Task { @MainActor in self?.refreshDevices() } } }
        catch { message = error.localizedDescription }
        refreshDevices()
        refreshRecoveries()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let coordinator = self else { return }
                Task { @MainActor in coordinator.stop(reason: "The Mac is going to sleep or shutting down. Recording will not resume automatically.") }
            })
        }
        shortcut.onToggle = { [weak self] in self?.toggleRecording() }
    }
    func refreshDevices() {
        guard sourceEnabled, !locked else { return }
        do {
            devices = try DeviceCatalog.inputs()
            resolved = try DeviceSelection.resolve(selection, devices: devices, defaultID: DeviceCatalog.defaultInputID())
            selectedChannel = resolved.flatMap { DeviceSelection.channel(for: $0, preferences: channelPreferences) } ?? -1
            preferenceObservers.removeAll()
            // A selected input can change its layout/name without the device list changing.
            if let resolved {
                preferenceObservers = try [
                    (kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput),
                    (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
                    (kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
                ].map { selector, scope in
                    try DeviceCatalog.observeDevice(resolved.objectID, selector: selector, scope: scope) { [weak self] in self?.refreshDevices() }
                }
            }
        } catch { resolved = nil; selectedChannel = -1; message = error.localizedDescription }
    }
    func chooseDevice(_ uid: String?) {
        guard !locked else { return }
        selectedUID = uid; message = nil
        defaults.set(try? JSONEncoder().encode(selection), forKey: "selection")
        refreshDevices()
    }
    func chooseChannel(_ channel: Int) {
        guard !locked, let resolved, resolved.channels.indices.contains(channel) else { return }
        channelPreferences[resolved.uid] = ChannelPreference(index: channel, layout: resolved.layout)
        selectedChannel = channel
        defaults.set(try? JSONEncoder().encode(channelPreferences), forKey: "channels")
    }
    func acceptNotices() { noticesAccepted = true; defaults.set(true, forKey: "noticesAccepted") }
    func chooseDestination() {
        guard !locked else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"; panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url { destination = url; defaults.set(url.path, forKey: "destination") }
    }
    func start(preview: Bool = false, callDetails: CallDetails? = nil) {
        guard sourceEnabled, !locked else { return }
        message = nil; savedFile = nil; refreshDevices()
        guard let resolved else { return }
        guard let channel = DeviceSelection.channel(for: resolved, preferences: channelPreferences) else {
            message = "Choose one microphone channel, then use Test audio to verify it."; return
        }
        guard lifecycle.begin() else { return }
        state = lifecycle.state; self.preview = preview; engineStarted = false; snapshot = PipelineSnapshot()
        Task {
            do {
                try await PermissionService.requestMicrophone()
                guard state == .preparing else { completeCancelledPreparation(); return }
                // Resolve again AFTER the permission dialog: topology may have changed while it was open.
                let current = try DeviceSelection.resolve(selection, devices: DeviceCatalog.inputs(), defaultID: DeviceCatalog.defaultInputID())
                guard current.uid == resolved.uid, current.layout == resolved.layout,
                      DeviceSelection.channel(for: current, preferences: channelPreferences) == channel else {
                    throw RecorderError.message("The selected microphone changed during preparation. Check the source and start again.")
                }
                self.resolved = current
                engineStarted = true
                engine?.start(input: ResolvedInput(device: current, channel: channel, selection: selection), destination: destination, preview: preview, microphoneEnabled: recordMicrophone, callDetails: callDetails, balanceMix: balanceMix)
            } catch {
                let permission = (error as? RecorderError).map { if case .microphonePermission = $0 { return true }; return false } ?? false
                message = error.localizedDescription
                lifecycle.finish(permission ? .needsPermission : .error); state = lifecycle.state
                refreshDevices(); if quitting { quitting = false; NSApp.reply(toApplicationShouldTerminate: false) }
            }
        }
    }
    private func completeCancelledPreparation() {
        lifecycle.finish(); state = .idle; preview = false; refreshDevices()
        if quitting { quitting = false; NSApp.reply(toApplicationShouldTerminate: true) }
    }
    func stop(reason: String? = nil) {
        guard lifecycle.stop() else { return }
        state = lifecycle.state
        if engineStarted { engine?.stop(reason: reason) }
        // During the microphone prompt, the pending Task completes cancellation when the dialog resolves.
    }
    func toggleRecording() {
        switch state.toggleAction {
        case .start: start()
        case .stop: stop()
        case .none: break
        }
    }
    func panelClosed() { if isPreview { stop() } }
    private func receive(_ event: EngineEvent) {
        switch event {
        case .prepared(let formats, let layout): lastFormats = formats; lastLayout = layout
        case .started:
            if lifecycle.started(preview: preview) { state = lifecycle.state; acquireSleepAssertion() }
        case .levels(let snapshot): self.snapshot = snapshot
        case .finalizing:
            _ = lifecycle.stop(); state = .finalizing; releaseSleepAssertion()
        case .finished(let file, let reason, let recovery, let needsPermission):
            releaseSleepAssertion(); savedFile = file; message = reason
            snapshot.microphonePeak = 0; snapshot.systemPeak = 0
            engineStarted = false; preview = false
            lifecycle.finish(needsPermission ? .needsPermission : recovery != nil ? .recoverable : reason != nil && file == nil ? .error : .idle)
            state = lifecycle.state
            if let file, !quitting { transcription.recordingSaved(file) }
            refreshDevices(); refreshRecoveries()
            if quitting { quitting = false; NSApp.reply(toApplicationShouldTerminate: file != nil || recovery == nil) }
        }
    }
    func refreshRecoveries() {
        Task { [weak self] in
            let sessions = await Task.detached(priority: .utility) { Recovery.scan() }.value
            guard let self, self.sourceEnabled, !self.locked else { return }
            self.recoveries = sessions
            if !sessions.isEmpty && self.state == .idle && self.savedFile == nil { self.lifecycle.finish(.recoverable); self.state = .recoverable }
        }
    }
    func recover(_ candidate: RecoveryCandidate, useCurrentDestination: Bool = false) {
        guard sourceEnabled, !locked, candidate.canRecover else { return }
        lifecycle.finish(.finalizing); state = .finalizing; message = nil
        engine?.recover(candidate, destination: useCurrentDestination ? destination : nil)
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openSystemSettings() {
        // Open the app itself; unverified pane URL fragments are deliberately avoided.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
    func copyDiagnostics() {
        let formatJSON = (try? JSONEncoder().encode(lastFormats)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let text = """
        Afterword \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") (local diagnostics; no audio)
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        State: \(state.rawValue)
        Selection: \(selection == .systemDefault ? "System default" : "Explicit device UID (redacted)")
        Input: \(resolved?.channels.count ?? 0) channels, \(resolved?.sampleRate ?? 0) Hz; selected channel \(selectedChannel + 1)
        Output: 48000 Hz; microphone mono, system stereo, playback mix stereo; \(snapshot.frames) PCM frames
        Callbacks: \(snapshot.callbacks); dropped frames: \(snapshot.droppedFrames)
        Clipped input samples: \(snapshot.clippedSamples); nonfinite input samples: \(snapshot.invalidSamples)
        Recoverable sessions: \(recoveries.count)
        Aggregate rate: \(lastLayout?.sampleRate ?? 0); buffer channels: \(lastLayout?.buffers ?? [])
        Actual formats and reported latency: \(formatJSON)
        Last status: \(message ?? "none")
        """
        let redacted = text.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(redacted, forType: .string)
    }
    func shouldQuit() -> NSApplication.TerminateReply {
        if state == .finalizing {
            let alert = NSAlert(); alert.messageText = "Saving is still in progress"
            alert.informativeText = "Wait for validation to finish. If an audio device is unresponsive, you can quit and recover the completed PCM chunks next time; the unfinished tail may be missing."
            alert.addButton(withTitle: "Keep saving"); alert.addButton(withTitle: "Quit and recover later")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
        guard locked else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Stop recording and save before quitting?"
        alert.informativeText = isPreview ? "The audio test will stop. No audio from the test is saved." : "Your recording will be finalized before Afterword quits."
        alert.addButton(withTitle: "Stop and save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        quitting = true; stop(); return .terminateLater
    }
    private func acquireSleepAssertion() {
        guard !hasSleepAssertion else { return }
        hasSleepAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Afterword is capturing audio" as CFString, &sleepAssertion) == kIOReturnSuccess
    }
    private func releaseSleepAssertion() { if hasSleepAssertion { IOPMAssertionRelease(sleepAssertion); hasSleepAssertion = false } }
}
