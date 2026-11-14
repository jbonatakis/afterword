import AppKit
import SwiftUI
import AVFoundation
import Combine
import RecorderCore

/// Own-window rendering and silent playback fixtures. Never starts capture or
/// changes the production app's defaults, files, or shortcut.
@main struct LibraryHarness {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-ui-" + UUID().uuidString)
        let name = Bundle.main.bundleIdentifier!
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: name) }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func pump(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        let folder = root.appendingPathComponent("Call-2026-11-14_09-30-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for track in RecordingTrack.allCases {
            let temporary = folder.appendingPathComponent(UUID().uuidString + ".caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: track.channels)!
            do {
                let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000 * 80)!
                buffer.frameLength = buffer.frameCapacity
                for channel in 0..<Int(track.channels) { buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(buffer.frameLength)) }
                try file.write(from: buffer)
            }
            try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent(track.filename))
        }
        let input = try TranscriptionInput.resolve(folder)
        let document = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "fixture", language: "en", segments: [
            .init(source: .microphone, start: 0, end: 8, text: "I'd like the recording library to feel like a place where we can actually work with our conversations.", timing: "word"),
            .init(source: .microphone, start: 8, end: 16, text: "We should be able to open a call, read a clear transcript, and listen to the moments that matter.", timing: "word"),
            .init(source: .system, start: 18, end: 28, text: "That makes sense. Search would help us find a decision even if we don't remember which meeting it came from.", timing: "word"),
            .init(source: .system, start: 28, end: 40, text: "Let's start with a simple library and readable transcripts, then add the notes pipeline once that foundation is in place.", timing: "word"),
            .init(source: .microphone, start: 42, end: 51, text: "Agreed. We can keep the recording controls in the menu bar so they're always easy to reach.", timing: "word")
        ])
        _ = try document.save(beside: input)
        let scan = RecordingLibraryScanner.scan(roots: [root])
        let recording = scan.recordings[0]
        let states = CurrentValueSubject<RecordingState, Never>(.idle)
        let playback = RecordingPlayback(states: states.eraseToAnyPublisher())
        defer { playback.shutdown() }
        playback.select(recording)
        require(playback.ready && playback.source == .mixed, "Mixed playback did not load")
        playback.seek(12.5); playback.play(); await pump()
        require(playback.playing && playback.position >= 12.5, "Silent fixture did not play")
        playback.changeTrack(.microphone, in: recording)
        require(playback.source == .microphone && playback.position >= 12.5 && playback.playing, "Track switch lost playback position")
        for state in [RecordingState.preparing, .recording, .previewing, .finalizing] {
            states.send(state); playback.play()
            require(!playback.playing, "Playback allowed during \(state)")
        }
        states.send(.idle); playback.seek(500)
        require(playback.position == playback.duration, "Seeking past the end was not clamped")
        playback.play(); require(playback.playing && playback.position == 0, "Replay did not restart at zero")
        playback.pause()
        print("PASS playback, track switching, seek bounds, replay, and capture priority")

        UserDefaults.standard.set(root.path, forKey: "destination")
        UserDefaults.standard.set(true, forKey: "noticesAccepted")
        // A cleared shortcut prevents registration of any production key.
        UserDefaults.standard.set(false, forKey: "KeyboardShortcuts_toggleCallRecording")
        let recorder = RecordingCoordinator(); recorder.shortcut.shutdown()
        defer { recorder.transcription.shutdown() }
        let library = RecordingLibraryModel(recorder: recorder)
        for _ in 0..<50 { if !library.refreshing { break }; await pump(0.05) }
        require(library.recordings.count == 1 && library.selectedRecording?.id == recording.id, "Library failed to load fixture")
        library.search = "clear transcript"
        require(library.visibleRecordings.count == 1, "Transcript phrase search failed")
        library.search = "missing phrase"
        require(library.visibleRecordings.isEmpty, "Search did not filter results")
        library.search = ""; library.filter = .untranscribed
        require(library.visibleRecordings.isEmpty, "Needs transcription filter was wrong")
        library.filter = .all
        print("PASS async library refresh, initial selection, transcript search, and filters")

        let native = RecordingLibraryWindow(library: library, recorder: recorder, playback: playback, showControls: {})
        native.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        native.present(); await pump()
        playback.play(); require(playback.playing, "Silent window-close fixture did not start")
        native.close(); await pump()
        require(!playback.playing && recorder.state == .idle, "Window close failed to pause playback independently of capture")
        native.present(); await pump()
        require(native.window?.isVisible == true, "Owned native window could not reopen")
        native.close()
        print("PASS native window ownership, playback pause on close, and reopen")

        for (width, height, dark, suffix) in [(1180.0, 740.0, false, "light"), (940.0, 600.0, true, "compact-dark")] {
            let view = RecordingLibraryView(library: library, recorder: recorder, playback: playback, showControls: {})
                .preferredColorScheme(dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.appearance = window.appearance
            window.contentView = host; window.orderFront(nil); await pump(0.6)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            window.appearance!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/library-\(suffix).png"))
            window.orderOut(nil)
        }
        print("PASS own-view rendering at default and minimum sizes; no screen capture or live audio capture")
    }
}
