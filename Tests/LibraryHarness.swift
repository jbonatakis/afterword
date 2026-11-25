import AppKit
import SwiftUI
import AVFoundation
import Vision
import Combine
@testable import RecorderCore
import Lookback

/// Own-window rendering and silent playback fixtures. Never starts capture or
/// changes the production app's defaults, files, or shortcut.
@main struct LibraryHarness {
    static let checkBoardDrag = CommandLine.arguments.contains("--board-drag")
    static let interactive = CommandLine.arguments.contains("--interactive") || checkBoardDrag
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(interactive ? .accessory : .prohibited)
        Task { @MainActor in
            do {
                try await run()
                if !interactive {
                    require(!app.isActive && !app.windows.contains(where: \.isVisible), "A background fixture activated the app or left a visible window")
                }
                exit(0)
            }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func pump(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    @MainActor static func waitForPreparation(_ playback: RecordingPlayback) async {
        for _ in 0..<4000 {
            if playback.availability != .preparing { break }
            await pump(0.001)
        }
        require(playback.availability != .preparing, "Timed out preparing playback")
    }
    @MainActor static func checkRecordingTelemetry(_ root: URL) {
        let recorder = RecordingCoordinator(enabled: false, recoveryRoot: root.appendingPathComponent("Sessions"))
        let telemetry = recorder.telemetry
        var recorderUpdates = 0, meterUpdates = 0
        var seconds: [Int] = []
        let state = recorder.objectWillChange.sink { recorderUpdates += 1 }
        let meters = telemetry.$snapshot.dropFirst().sink { _ in meterUpdates += 1 }
        let clock = telemetry.clock.$seconds.sink { seconds.append($0) }
        defer { state.cancel(); meters.cancel(); clock.cancel() }

        var sample = PipelineSnapshot()
        for tick in 1...25 {
            sample.frames += 4800
            sample.callbacks += 1
            sample.microphonePeak = Float(tick) / 25
            sample.systemPeak = 0.5
            recorder.receive(.levels(sample))
        }
        require(recorderUpdates == 0 && meterUpdates == 25, "Meter updates reached the library or skipped the meters")
        require(seconds == [0, 1, 2] && telemetry.clock.text == "00:02", "Clock did not follow whole seconds of captured audio")
        require(telemetry.snapshot.microphonePeak == 1 && telemetry.snapshot.systemPeak == 0.5, "Latest meter levels were lost")
        sample.frames = 48_000 * 3601
        recorder.receive(.levels(sample))
        require(telemetry.clock.text == "1:00:01", "Hour rollover changed")
        recorder.receive(.finalizing)
        require(recorderUpdates > 0 && recorder.state == .finalizing, "Finalizing did not reach the library")
        recorder.receive(.finished(file: nil, reason: nil, recovery: nil, needsPermission: false))
        require(recorder.state == .idle && telemetry.snapshot.systemPeak == 0 && telemetry.snapshot.microphonePeak == 0, "Finish left a meter active")
        require(telemetry.snapshot.callbacks == 25 && telemetry.snapshot.frames == sample.frames && seconds == [0, 1, 2, 3601],
                "Finishing lost final diagnostics or advanced the clock")
        recorder.receive(.levels(PipelineSnapshot()))
        require(telemetry.clock.text == "00:00" && seconds.last == 0, "A fresh stream did not reset the clock")
        print("PASS independent recorder state, 10 Hz audio meters, whole-second clock, and final diagnostics")
    }

    @MainActor static func checkMarkdownListLayout() {
        let proposal = NSSize(width: 480, height: 600)
        func width(_ markdown: String, fillsWidth: Bool = false) -> CGFloat {
            let host = NSHostingController(rootView: MarkdownContent(markdown: markdown, fillsWidth: fillsWidth))
            return host.sizeThatFits(in: proposal).width
        }
        // Only the longest row determines the ideal width of these compact conversation bubbles.
        let wide = "- Longest item in this list"
        let flat = width("- A\n" + wide)
        let nested = "- A\n  " + wide
        let compact = width(nested)
        require(compact > flat, "The child row rendered at the parent margin")
        require(width("- A\n  - B\n" + wide) == flat, "The final parent row kept its child's indent")
        require(compact < proposal.width && width(nested, fillsWidth: true) == proposal.width,
                "List rows lost their compact or full-width sizing")
        print("PASS nested Markdown list indentation, return to parent, and compact and full-width sizing")
    }

    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-ui-" + UUID().uuidString)
        setenv("CLAUDE_CONFIG_DIR", root.appendingPathComponent("ClaudeConfig").path, 1)
        setenv("CODEX_HOME", root.appendingPathComponent("CodexHome").path, 1)
        let name = "io.local.afterword.librarycheck"
        guard Bundle.main.bundleIdentifier == name else { throw RecorderError.message("Run this harness in the Library Check test bundle") }
        UserDefaults.standard.removePersistentDomain(forName: name)
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: name) }
        checkMarkdownListLayout()
        checkRecordingTelemetry(root)
        if CommandLine.arguments.contains("--coding-pages") { try await checkCodingPages(root); return }
        if checkBoardDrag { try await checkSourceSelection(root); return }
        if CommandLine.arguments.contains("--sources") { try await checkSourceSelection(root) }
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
        if CommandLine.arguments.contains("--reader") {
            playback.select(recording)
            try await checkLongTranscript(input: input, recording: recording, playback: playback)
            return
        }
        let sourcesOnly = CommandLine.arguments.contains("--sources")
        try await checkRecordingStartup(root: root.appendingPathComponent("RecordingStartup"),
                                        audio: folder.appendingPathComponent(RecordingTrack.mixed.filename))
        if !sourcesOnly {
            playback.select(recording)
            require(playback.canPlay && playback.duration > 0, "Initial scrubber duration missing")
            playback.seek(8); playback.toggle()
            require(playback.wantsPlayback, "Pending play did not expose a pause action")
            playback.toggle()
            await waitForPreparation(playback)
            require(playback.position == 8 && !playback.playing, "Queued seek or toggle lost")
            require(playback.ready && playback.source == .mixed, "Mixed playback did not load")
            playback.seek(12.5); playback.play(); await pump()
            require(playback.playing && playback.position >= 12.5, "Silent fixture did not play")
            playback.changeTrack(.microphone, in: recording)
            playback.changeTrack(.system, in: recording); playback.changeTrack(.microphone, in: recording)
            await waitForPreparation(playback)
            require(playback.source == .microphone && playback.position >= 12.5 && playback.playing, "Track switch lost playback position")
            for state in [RecordingState.preparing, .recording, .previewing, .finalizing] {
                states.send(state); playback.play()
                require(!playback.playing, "Playback allowed during \(state)")
            }
            states.send(.idle); playback.seek(500)
            require(playback.position == playback.duration, "Seeking past the end was not clamped")
            playback.play(); require(playback.playing && playback.position == 0, "Replay did not restart at zero")
            playback.pause()
            playback.changeTrack(.system, in: recording); playback.play(); states.send(.recording)
            await waitForPreparation(playback); states.send(.idle)
            require(playback.ready && !playback.playing, "Pending play survived capture")
            playback.changeTrack(.mixed, in: recording); playback.play(); playback.clear()
            await pump(0.1)
            require(!playback.canPlay && playback.recordingID == nil && !playback.playing, "Cleared player reappeared")
            let missing = LibraryRecording(url: root.appendingPathComponent("Unavailable"), sourceName: "Missing", isDirectory: true,
                details: .init(), detailsError: nil, date: Date(), duration: nil,
                tracks: [.init(source: .mixed, url: root.appendingPathComponent("missing.m4a"))], transcripts: [])
            playback.select(missing); await waitForPreparation(playback)
            require(!playback.canPlay && playback.error != nil, "Failed file reported ready")
            playback.select(recording); playback.play(); playback.select(missing); playback.select(recording)
            await waitForPreparation(playback)
            require(playback.ready && playback.error == nil && !playback.playing && playback.position == 0, "Stale selection won")
            print("PASS playback, track switching, seek bounds, replay, and capture priority")
        }

        UserDefaults.standard.set(root.path, forKey: "destination")
        UserDefaults.standard.set(true, forKey: "noticesAccepted")
        // A cleared shortcut prevents registration of any production key.
        UserDefaults.standard.set(false, forKey: "KeyboardShortcuts_toggleCallRecording")
        let recorder = RecordingCoordinator(peopleURL: root.appendingPathComponent("People.json"), recoveryRoot: root.appendingPathComponent("Sessions")); recorder.shortcut.shutdown()
        defer { recorder.transcription.shutdown() }
        let library = RecordingLibraryModel(recorder: recorder, embeddingDirectory: root.appendingPathComponent("Embeddings"))
        defer { library.shutdown() }
        for _ in 0..<50 { if !library.refreshing { break }; await pump(0.05) }
        require(library.sources == ActivitySource.feedSources, "Upgrading an existing recording library hid a source")
        require(library.recordings.count == 1 && library.selectedRecording?.id == recording.id, "Library failed to load fixture")
        library.search = "clear transcript"
        await library.updateSearch(debounce: false)?.value
        require(library.visibleRecordings.count == 1, "Transcript phrase search failed")
        // A refresh (for example after a contact save) may replace the explicit search task.
        // Await both public operations and verify the final publication keeps the newest query.
        let olderSearch = library.updateSearch(debounce: false)
        let overlappingRefresh = library.refresh()
        library.search = "missing phrase"
        await library.updateSearch(debounce: false)?.value
        await olderSearch?.value
        await overlappingRefresh?.value
        require(!library.searching && library.resultQuery == "missing phrase" && library.visibleRecordings.isEmpty,
                "A refresh or superseded search replaced the newer result")
        library.search = ""; library.filter = .untranscribed
        await library.updateSearch(debounce: false)?.value
        require(library.visibleRecordings.isEmpty, "Needs transcription filter was wrong")
        library.filter = .recordings
        print("PASS async library refresh, initial selection, transcript search, and filters")

        try await checkCodingSidebar(root: root, library: library, recorder: recorder, playback: playback)
        try await checkGitHub(library: library)
        if sourcesOnly { return }
        library.filter = .recordings
        library.search = ""
        await library.refresh()?.value

        let originalVersion = recording.transcripts[0]
        let originalBytes = try Data(contentsOf: originalVersion.url)
        try await library.saveDetails(.init(title: "Product planning", participants: ["Alex"], tags: ["Roadmap", "Design"],
                                           description: "Decisions about the recording library and the next steps for readable transcripts."), for: recording)
        for _ in 0..<50 { if !library.refreshing { break }; await pump(0.05) }
        require(library.selectedRecording?.name == "Product planning", "Renamed title did not persist through refresh")
        library.beginRenaming(library.recordings[0]); library.renameText = "Product planning · weekly review"
        await library.saveRename()
        require(library.selectedRecording?.name == "Product planning · weekly review", "Inline rename did not persist")
        require(library.selectedRecording?.details.participants == ["Alex"], "Renaming replaced participants")
        library.beginRenaming(library.recordings[0]); library.renameText = "   "
        await library.saveRename()
        require(library.renameError != nil && library.renamingID == recording.id, "An empty title was accepted or its draft lost")
        library.cancelRename()
        library.beginRenaming(library.recordings[0]); library.renameText = "Cancelled title"
        library.cancelRename()
        require(library.selectedRecording?.name == "Product planning · weekly review", "Cancelling rename changed the title")
        library.search = "Roadmap"
        await library.updateSearch(debounce: false)?.value
        require(library.visibleRecordings.count == 1, "Tag search failed")
        library.search = "Alex"
        await library.updateSearch(debounce: false)?.value
        require(library.visibleRecordings.count == 1, "Participant search failed")
        var corrected = document.paragraphs.map(\.text)
        corrected[0] = "Let's build a library that makes our conversations easy to find and review."
        library.beginTranscriptEditing(recording, version: originalVersion)
        library.transcriptDrafts[recording.id]?.text = corrected
        var callDetails = library.recordings[0].details
        callDetails.participants.append("Sam")
        try await library.saveDetails(callDetails, for: library.recordings[0])
        let named = library.recordings[0]
        require(named.automaticParticipant(for: originalVersion) == "Alex", "Adding a second person changed existing automatic assignments")
        await library.assignParticipant("Sam", to: 0, recording: named, version: originalVersion)
        require(library.transcriptDrafts[recording.id]?.participants[0] == nil, "Participant assignment changed the microphone speaker")
        await library.assignParticipant("Sam", to: 1, recording: named, version: originalVersion)
        require(library.transcriptDrafts[recording.id]?.participants[1] == "Sam", "Speaker menu selection did not update the draft")
        var renamedDetails = named.details; renamedDetails.participants = ["Alex", "Samuel"]
        try await library.saveDetails(renamedDetails, for: named, participantRenames: ["Sam": "Samuel"])
        require(library.transcriptDrafts[recording.id]?.participants[1] == "Samuel", "Renaming a participant left a stale assignment in the open draft")
        require(library.transcriptDrafts[recording.id]?.text == corrected, "Renaming a participant lost text edits")
        require(library.hasUnsavedEdits, "Inline changes were not tracked as unsaved")
        library.selection = nil; library.search = "no matching call"; await library.refresh()?.value
        require(library.transcriptDrafts[recording.id]?.text == corrected, "Navigating or refreshing lost inline edits")
        library.search = ""; library.selection = recording.id
        await library.updateSearch(debounce: false)?.value
        await library.saveTranscriptDraft(for: recording)
        for _ in 0..<50 { if !library.refreshing { break }; await pump(0.05) }
        require(library.selectedRecording?.transcripts.count == 2, "Editing did not create a version")
        require(library.transcriptDrafts[recording.id] == nil && !library.hasUnsavedEdits, "Successful save left a dirty draft")
        require(library.preferredTranscriptID != nil, "Edited version was not selected")
        require(library.selectedRecording?.transcripts.contains { $0.document?.editing != nil } == true, "Edited version lacks its origin")
        library.search = "clear transcript"
        await library.updateSearch(debounce: false)?.value
        require(library.visibleRecordings.isEmpty, "Search surfaced superseded text by default")
        library.searchHistory = true
        await library.updateSearch(debounce: false)?.value
        require(library.visibleRecordings.count == 1 && library.searchHits[recording.id]?.versionID == originalVersion.id, "History search did not select the matching older version")
        library.searchHistory = false
        library.search = "clear transcript"
        library.search = "conversations"
        await library.updateSearch(debounce: false)?.value
        await pump(0.25)
        require(library.visibleRecordings.count == 1 && library.resultQuery == "conversations", "Stale search replaced the current result")
        library.search = ""

        let namedDocument = library.recordings[0].transcripts.first { $0.document?.editing != nil }!.document!
        require(namedDocument.automaticParticipant == "Alex" && namedDocument.paragraphs[1].participant == "Samuel", "Saved transcript lost the frozen automatic name or renamed assignment")
        require(namedDocument.readableText.contains("Samuel · 00:00:18"), "Readable transcript omitted renamed speakers")
        let unchangedBytes = try Data(contentsOf: originalVersion.url)
        require(unchangedBytes == originalBytes, "Editing changed the original transcript")
        recorder.transcription.recordingSaved(folder)
        try recorder.transcription.beginLibraryMutation()
        require(!recorder.transcription.canTranscribe, "Transcription allowed during file mutation")
        recorder.transcription.transcribe(recording: root.appendingPathComponent("other"))
        require(recorder.transcription.recording == folder, "Mutation allowed a new transcription selection")
        recorder.transcription.filesMovedToTrash([folder])
        recorder.transcription.endLibraryMutation()
        require(recorder.transcription.recording == nil, "Trashed recording remained selected for transcription")
        print("PASS editable metadata, one-to-many participant transition, manual assignments, transcript versions, original preservation, and transcription mutation guard")

        if interactive {
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
        }

        let summaryCall = library.recordings[0]
        try CallSummaryStore.save("Summary from the original transcript.", for: summaryCall, source: originalVersion)
        await library.refresh()?.value
        let current = library.recordings[0]
        require(current.summary?.current?.sourceChanged(in: current) == true, "Fixture did not have a stale summary")
        let summaryController = RecordingLibraryWindow(library: library, recorder: recorder, playback: playback, showControls: {})
        let summaryWindow = summaryController.window!
        summaryWindow.setFrame(NSRect(x: -10000, y: -10000, width: 940, height: 660), display: false)
        summaryWindow.displayIfNeeded(); await pump()
        let content = summaryWindow.contentView!
        content.layoutSubtreeIfNeeded()
        func splitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { splitView(in: $0) }.first
        }
        guard let split = splitView(in: content) else { throw RecorderError.message("Library split view is missing") }
        let bounds = split.convert(split.bounds, to: content)
        require(bounds.minY >= content.bounds.minY - 1 && bounds.maxY <= content.bounds.maxY + 1, "Stale summary pushed the library outside its window")
        summaryWindow.orderOut(nil)
        try FileManager.default.removeItem(at: CallSummaryStore.url(for: current.url, isDirectory: current.isDirectory))
        await library.refresh()?.value
        print("PASS changed-transcript notice fits in the compact library window")

        for (width, height, dark, suffix) in [(1180.0, 740.0, false, "light"), (940.0, 600.0, true, "compact-dark")] {
            let view = RecordingLibraryView(library: library, recorder: recorder, playback: playback, showControls: {})
                .preferredColorScheme(dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.appearance = window.appearance
            window.contentView = host; window.displayIfNeeded(); await pump(0.6)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            window.appearance!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/library-\(suffix).png"))
            window.orderOut(nil)
        }
        print("PASS own-view rendering at default and minimum sizes; no screen capture or live audio capture")
        require(!library.embeddings.settings.enabled, "Semantic search was not opt-in")
        library.embeddings.change(enabled: true)
        library.pollSemanticSearch()
        for _ in 0..<40 { await pump(0.05); if library.semanticStatus?.state == "missing_model" { break } }
        require(library.semanticStatus?.state == "missing_model", "Missing embedding model did not show keyword fallback")
        let searchSettings = NSHostingView(rootView: EmbeddingSettingsView(library: library, embeddings: library.embeddings))
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false; settingsWindow.contentView = searchSettings
        settingsWindow.displayIfNeeded(); await pump()
        searchSettings.layoutSubtreeIfNeeded()
        let settingsBitmap = searchSettings.bitmapImageRepForCachingDisplay(in: searchSettings.bounds)!
        searchSettings.cacheDisplay(in: searchSettings.bounds, to: settingsBitmap)
        try settingsBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/search-settings.png"))
        settingsWindow.close()
        library.embeddings.change(enabled: false)
        print("PASS opt-in search settings, missing-model fallback and settings rendering")

        let updated = library.recordings[0]
        library.beginTranscriptEditing(updated, version: updated.transcripts[0], paragraph: 1)
        library.transcriptDrafts[updated.id]?.text[1] += " This correction is still a draft."
        for (view, width, height, suffix) in [
            (AnyView(CallDetailsEditor(recording: updated, library: library)), 578.0, 510.0, "call-details"),
            (AnyView(RecordingLibraryView(library: library, recorder: recorder, playback: playback, showControls: {})), 1180.0, 740.0, "transcript-inline")
        ] {
            let host = NSHostingView(rootView: view.preferredColorScheme(.light))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua); host.appearance = window.appearance
            window.contentView = host; window.displayIfNeeded(); await pump(0.3)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            window.appearance!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/\(suffix).png"))
            window.orderOut(nil)
        }
        library.cancelTranscriptEditing(updated)
        require(!library.hasUnsavedEdits && library.recordings[0].transcripts.count == 2, "Cancelling an inline draft wrote a transcript")
        print("PASS inline rename, draft navigation/save/cancel, and inline transcript rendering")

        library.beginTranscriptEditing(updated, version: updated.transcripts[0])
        require(!library.hasUnsavedEdits, "Starting an unchanged draft reported unsaved edits")
        var removed = updated.details; removed.participants = []
        try await library.saveDetails(removed, for: updated)
        require(library.transcriptDrafts[updated.id]?.participants[1] == "", "Removing a participant left their name in the open draft")
        require(!library.hasUnsavedEdits, "A participant metadata change made an unchanged draft dirty")
        require(library.recordings[0].automaticParticipant(for: originalVersion) == nil, "Removing all participants retained the automatic name")
        removed.participants = ["Taylor"]
        try await library.saveDetails(removed, for: library.recordings[0])
        require(library.recordings[0].automaticParticipant(for: originalVersion) == "Taylor", "A replacement sole participant did not label automatic sections")
        require(library.transcriptDrafts[updated.id]?.participants[1] == "", "Adding a person revived a removed manual assignment")
        library.cancelTranscriptEditing(updated)
        print("PASS rename/remove/replace participant updates in open drafts and saved transcript views")

        if interactive {
            let renameView = NSHostingView(rootView: RecordingLibraryView(library: library, recorder: recorder, playback: playback, showControls: {}).preferredColorScheme(.light))
            let renameWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 940, height: 660), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            renameWindow.appearance = NSAppearance(named: .aqua); renameView.appearance = renameWindow.appearance
            renameWindow.contentView = renameView; renameWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            await pump()
            library.beginRenaming(updated)
            for _ in 0..<40 {
                if renameWindow.firstResponder is NSTextView { break }
                await pump(0.05)
            }
            require(library.renamingID == updated.id, "Row rename editor dismissed immediately")
            guard let titleEditor = renameWindow.firstResponder as? NSTextView else { throw RecorderError.message("Inline title did not receive keyboard focus") }
            renameView.layoutSubtreeIfNeeded(); renameView.displayIfNeeded()
            let renameBitmap = renameView.bitmapImageRepForCachingDisplay(in: renameView.bounds)!
            renameWindow.appearance!.performAsCurrentDrawingAppearance { renameView.cacheDisplay(in: renameView.bounds, to: renameBitmap) }
            try renameBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/rename-inline.png"))
            titleEditor.selectAll(nil)
            titleEditor.insertText("Title saved with Return", replacementRange: titleEditor.selectedRange())
            await pump(0.1)
            require(library.renameText == "Title saved with Return", "Typing in the title field did not update the draft")
            titleEditor.insertNewline(nil)
            await pump(0.4)
            require(library.renamingID == nil && library.recordings[0].name == "Title saved with Return", "Return did not save the inline title")
            renameWindow.orderOut(nil)
            print("PASS inline title keyboard focus, typing, Return to save, and minimum-width rendering")
        }

        var quickDetails = library.recordings[0].details; quickDetails.participants = ["Taylor", "Morgan"]
        try await library.saveDetails(quickDetails, for: library.recordings[0])
        let quickRecording = library.recordings[0], quickVersion = quickRecording.transcripts[0]
        let quickOriginal = try Data(contentsOf: quickVersion.url)
        library.search = "Taylor"
        await library.updateSearch(debounce: false)?.value
        playback.seek(12.5)
        await library.assignParticipant("Morgan", to: 1, recording: quickRecording, version: quickVersion)
        require(library.transcriptDrafts[updated.id] == nil && !library.hasUnsavedEdits, "Quick speaker assignment opened transcript editing")
        require(library.search == "Taylor" && library.selection == updated.id, "Quick assignment changed search or selection")
        require(playback.position == 12.5, "Quick assignment changed playback position")
        let quickSaved = library.recordings[0].transcripts.first { version in !quickRecording.transcripts.contains { $0.id == version.id } }!
        require(quickSaved.document?.paragraphs[1].participant == "Morgan", "Quick speaker assignment was not persisted")
        require(quickSaved.document?.segments.map(\.text) == quickVersion.document?.segments.map(\.text), "Quick assignment changed transcript text")
        require(quickSaved.document?.segments.map(\.start) == quickVersion.document?.segments.map(\.start), "Quick assignment changed timestamps")
        require(library.participantAssignments[updated.id] == nil, "Successful speaker save retained a spinner or error")
        let quickUnchanged = try Data(contentsOf: quickVersion.url)
        require(quickUnchanged == quickOriginal, "Quick assignment changed the previous version")
        let quickCount = library.recordings[0].transcripts.count
        await library.assignParticipant("Morgan", to: 1, recording: library.recordings[0], version: quickSaved)
        require(library.recordings[0].transcripts.count == quickCount, "Choosing the current speaker created a duplicate version")

        // Simulate a failed save using only this fixture's file, then restore it.
        let temporarilyMissing = quickSaved.url.appendingPathExtension("fixture-backup")
        try FileManager.default.moveItem(at: quickSaved.url, to: temporarilyMissing)
        do {
            defer { try? FileManager.default.moveItem(at: temporarilyMissing, to: quickSaved.url) }
            await library.assignParticipant("Taylor", to: 1, recording: library.recordings[0], version: quickSaved)
            require(library.participantAssignments[updated.id]?.error != nil, "Failed speaker save did not report an error")
            require(library.transcriptDrafts[updated.id] == nil && !library.managing, "Failed speaker save opened an editor or retained its save lock")
        }
        await library.refresh()?.value
        require(library.recordings[0].transcripts.count == quickCount, "Failed save published a transcript version")
        await library.assignParticipant("Taylor", to: 1, recording: library.recordings[0], version: quickSaved)
        require(library.participantAssignments[updated.id] == nil && library.recordings[0].transcripts.count == quickCount + 1, "Retry did not save and clear the speaker error")
        library.search = ""
        await library.updateSearch(debounce: false)?.value
        print("PASS immediate speaker save without text editing, original/text/timing preservation, search/playback stability, no-op choice, and failed-save retry")

        try await checkLongTranscript(input: input, recording: updated, playback: playback)

        let fixtureTrash = root.appendingPathComponent(".fixture-trash")
        try FileManager.default.createDirectory(at: fixtureTrash, withIntermediateDirectories: true)
        let move: @Sendable (URL) throws -> URL = { url in
            let target = fixtureTrash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        recorder.destination = folder
        do {
            try await library.moveToTrash(updated, playback: playback, trash: move)
            throw RecorderError.message("Trash was permitted for the current recording destination")
        } catch { require(FileManager.default.fileExists(atPath: folder.path) && !library.managing, "Blocked Trash changed the recording") }
        recorder.destination = root
        let countBeforeTrash = library.recordings[0].transcripts.count
        try await library.moveToTrash(updated, version: updated.transcripts[0], playback: playback, trash: move)
        for _ in 0..<50 { if !library.refreshing { break }; await pump(0.05) }
        require(library.recordings.first?.transcripts.count == countBeforeTrash - 1, "Version deletion failed to refresh the library")
        require(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Mixed.m4a").path), "Version deletion removed audio")
        recorder.savedFile = folder
        recorder.transcription.recordingSaved(folder)
        playback.select(updated); playback.play()
        try await library.moveToTrash(library.recordings[0], playback: playback, trash: move)
        for _ in 0..<50 { if !library.refreshing { break }; await pump(0.05) }
        require(library.recordings.isEmpty && library.selection == nil, "Call deletion left a stale library entry")
        require(!playback.playing && playback.recordingID == nil, "Call deletion did not unload playback")
        require(recorder.savedFile == nil && recorder.transcription.recording == nil, "Call deletion retained a stale recent recording")
        require(!library.managing && !recorder.transcription.libraryMutationActive, "Trash failed to release its mutation guard")
        require(library.issues.isEmpty, "Deleted call remained as a missing library folder")
        print("PASS call/version deletion, recording destination guard, playback unload, and recent-recording cleanup using fixture Trash")
    }

    @MainActor static func checkLongTranscript(input: TranscriptionInput, recording: LibraryRecording, playback: RecordingPlayback) async throws {
        var stressSegments: [TranscriptSegment] = []
        for index in 0..<375 {
            let source: TranscriptSource = index.isMultiple(of: 2) ? .microphone : .system
            let text = "Passage \(index). " + String(repeating: "A longer paragraph exercises wrapping and selection. ", count: index % 10 + 1)
            stressSegments.append(TranscriptSegment(source: source, start: Double(index), end: Double(index + 1), text: text, timing: "segment"))
        }
        let stressParagraphs = TranscriptParagraph.make(from: stressSegments)
        func reader(_ query: String, matches: [Int] = [], draft: TranscriptDraft? = nil) -> ReadableTranscript {
            ReadableTranscript(paragraphs: stressParagraphs, edited: false, query: query, playback: playback, playbackDisabled: false,
                               draft: draft, canEdit: true, editParagraph: { _ in }, participants: ["Alex", "Sam"], automaticParticipant: "Alex",
                               assignParticipant: { _, _ in }, editParticipants: {}, searchMatches: matches)
        }
        let initialHit = stressParagraphs.count / 2
        let stressHost = NSHostingView(rootView: reader("selected evidence", matches: [initialHit]))
        let stressWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        stressWindow.contentView = stressHost
        if interactive { stressWindow.orderFront(nil) } else { stressWindow.displayIfNeeded() }
        await pump()
        func transcriptTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { transcriptTable(in: $0) }.first
        }
        guard let table = transcriptTable(in: stressHost) else { throw RecorderError.message("Missing transcript list") }
        require(table.numberOfRows == stressParagraphs.count + 1, "Missing transcript paragraphs or footer")
        let mounted = (0..<table.numberOfRows).filter { table.rowView(atRow: $0, makeIfNecessary: false) != nil }
        require(!mounted.isEmpty && mounted.count < 40, "The transcript mounted \(mounted.count) rows on open")
        require(NSLocationInRange(initialHit, table.rows(in: table.visibleRect)), "Opening a search result did not reveal its paragraph")
        let last = stressParagraphs.count - 1
        // SwiftUI delivers subsequent ScrollViewReader updates on the window's display cycle.
        // The background fixture exercises the initial reveal on its own layout pass.
        if interactive {
            stressHost.rootView = reader("selected evidence", matches: [last])
            for _ in 0..<30 {
                if NSLocationInRange(last, table.rows(in: table.visibleRect)) { break }
                await pump(0.05)
            }
            require(NSLocationInRange(last, table.rows(in: table.visibleRect)), "Search failed to reveal an offscreen paragraph")
        }
        playback.play()
        for index in 0..<20 {
            stressWindow.setContentSize(NSSize(width: index.isMultiple(of: 2) ? 420 : 700, height: 500))
            stressHost.rootView = reader("Passage \(index * 3).")
            playback.seek(Double(index * 3))
            playback.changeTrack(index.isMultiple(of: 2) ? .microphone : .system, in: recording)
            await pump(0.06)
        }
        playback.pause()
        guard interactive else {
            print("PASS 375-paragraph reader virtualization, initial search reveal, resizing and playback. Use --interactive for live scrolling and focus checks.")
            return
        }
        let stressDocument = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "fixture", language: "en", segments: stressSegments)
        let version = LibraryTranscript(url: recording.transcripts[0].url, document: stressDocument, error: nil, date: Date(), fileModificationDate: Date())
        let edit = TranscriptDraft(version: version, focusedParagraph: last, details: recording.details)
        for _ in 0..<40 {
            NSApp.activate(ignoringOtherApps: true)
            stressWindow.makeKeyAndOrderFront(nil)
            await pump(0.05)
            if NSApp.isActive && stressWindow.isKeyWindow { break }
        }
        require(stressWindow.isKeyWindow, "The editor test window could not obtain keyboard focus")
        stressHost.rootView = reader("", draft: edit)
        for _ in 0..<40 {
            await pump(0.05)
            if let editor = stressWindow.firstResponder as? NSTextView, editor.isEditable, editor.string == edit.text[last] { break }
        }
        guard let editor = stressWindow.firstResponder as? NSTextView, editor.isEditable, editor.string == edit.text[last] else {
            throw RecorderError.message("The requested offscreen transcript editor did not receive keyboard focus")
        }
        editor.selectAll(nil)
        editor.insertText("Edited at the end of a long transcript", replacementRange: editor.selectedRange())
        stressWindow.makeFirstResponder(table)
        table.scrollRowToVisible(0); await pump()
        table.scrollRowToVisible(last); await pump()
        require(edit.text[last] == "Edited at the end of a long transcript", "Recycling a row lost its draft")
        require(stressWindow.firstResponder === table, "Revisiting a recycled row stole edit focus")
        stressWindow.orderOut(nil)
        print("PASS 375-paragraph reader mounted \(mounted.count) rows, revealed offscreen matches and editors, preserved edits on scroll, and handled resizing during playback")
    }

    /// Use the window server for this opt-in check. App-local NSEvents don't drive a native drag session.
    @MainActor static func pointerDrag(from start: NSPoint, to end: NSPoint, in window: NSWindow, slowStart: Bool = false) async throws {
        let points = [start, end].map { window.convertPoint(toScreen: $0) }
        func unobscured() -> Bool {
            points.allSatisfy { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) == window.windowNumber }
        }
        for _ in 0..<12 where !unobscured() { await pump(0.1) }
        guard unobscured(), !CGEventSource.buttonState(.combinedSessionState, button: .left), let screen = NSScreen.screens.first else {
            throw RecorderError.message("The drag fixture must be unobscured with the mouse button released.")
        }
        let a = CGPoint(x: points[0].x, y: screen.frame.maxY - points[0].y)
        let b = CGPoint(x: points[1].x, y: screen.frame.maxY - points[1].y)
        // AppKit can enter a tracking loop on mouse-down, so drive the pointer off the main thread.
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                func post(_ type: CGEventType, _ point: CGPoint) {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
                post(.mouseMoved, a)
                Thread.sleep(forTimeInterval: 0.15)
                post(.leftMouseDown, a)
                if slowStart {
                    Thread.sleep(forTimeInterval: 0.45)
                    for i in 1...6 {
                        post(.leftMouseDragged, CGPoint(x: a.x, y: a.y + CGFloat(i) / 2))
                        Thread.sleep(forTimeInterval: 0.03)
                    }
                }
                for i in 1...18 {
                    Thread.sleep(forTimeInterval: 0.016)
                    let fraction = CGFloat(i) / 18
                    post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction))
                }
                Thread.sleep(forTimeInterval: 0.1)
                post(.leftMouseUp, b)
                done.resume()
            }
        }
    }

    @MainActor static func checkSourceSelection(_ root: URL) async throws {
        let support = root.appendingPathComponent("SourceSelection")
        let embeddings = support.appendingPathComponent("Embeddings")
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var chosenFolder: URL?
        var pickerCount = 0
        let recorder = RecordingCoordinator(peopleURL: support.appendingPathComponent("People.json"), enabled: false,
                                           recoveryRoot: support.appendingPathComponent("Sessions"), requestRecordingFolder: {
            pickerCount += 1
            return chosenFolder
        })
        let destination = support.appendingPathComponent("Recordings", isDirectory: true)
        require(recorder.destination == nil, "A fresh install already had a recording destination")
        let library = RecordingLibraryModel(recorder: recorder, defaults: defaults, embeddingDirectory: embeddings)
        defer { library.shutdown() }
        require(library.sources.isEmpty && library.refresh() == nil, "A fresh library started source work")
        require(!recorder.sourceEnabled && defaults.object(forKey: "libraryFolders") == nil, "First launch activated recording")
        let recordingAvailability = library.$sources.sink { sources in
            require(recorder.sourceEnabled == sources.contains(.recordings), "Calendar and menu observers saw stale recorder availability")
        }
        defer { recordingAvailability.cancel() }
        let playback = RecordingPlayback(recorder: recorder)
        defer { playback.shutdown() }
        let controller = RecordingLibraryWindow(library: library, recorder: recorder, playback: playback, showControls: {})
        let window = controller.window!
        window.displayIfNeeded()
        let host = window.contentViewController!.view
        defer { window.orderOut(nil) }
        func sidebar(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap(sidebar).first
        }
        await pump()
        require(sidebar(host) == nil, "First launch already displayed a library sidebar")
        // Keep the first two columns exposed for clicks with the ticket overlay open.
        window.setContentSize(NSSize(width: 1440, height: 740))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        window.displayIfNeeded()
        library.setSources([.board])
        await pump()
        require(sidebar(host)?.numberOfRows == 1 && library.destination == .page(.board), "Board-only setup did not open its sole sidebar destination")
        require(!recorder.sourceEnabled && library.refresh() == nil, "Board-only setup started activity work")
        var grants = AgentAccessConfiguration(enabled: true)
        grants.allowBoardManagement = true
        let state = library.boardStore.stateDirectory
        try AgentAccessStore.save(grants, directory: state)
        let agent = AgentLibrary(directory: state)
        func boardRevision() throws -> String {
            try agent.call("get_board", arguments: [:])["revision"] as! String
        }
        let localTicket = BoardTicket(title: "Plan launch review", notes: "Read the release checklist.", columnID: "todo",
                                      references: [.init(source: .coding, itemID: "fixture", label: "Build session")])
        _ = try library.boardStore.save(localTicket, original: nil)
        let sharedTicket = try agent.call("get_board_ticket", arguments: ["ticket_id": localTicket.id])
        let sharedRefs = (sharedTicket["ticket"] as? [String: Any])?["references"] as? [[String: Any]]
        require(sharedRefs?.isEmpty == true, "The board-only agent received a local citation")
        let agendaNotes = "Second ticket body.\n\n## Meeting decisions\n\n" + (1...36).map { "Agenda section " + String($0) + "\nReview the open questions and record next steps." }.joined(separator: "\n\n")
        _ = try agent.call("create_board_ticket", arguments: ["title": "Prepare agenda", "notes": agendaNotes, "column_id": "in-progress", "expected_revision": try boardRevision()])
        // Offscreen SwiftUI windows expose only native containers through AX. Locate
        // visible labels and send clicks to this fixture's own window.
        func labels(in view: NSView, waitingFor target: String, or alternate: String? = nil) async throws -> [String: NSPoint] {
            var result: [String: NSPoint] = [:]
            for _ in 0..<12 {
                await pump(0.1)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let image = bitmap.cgImage else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast
                try VNImageRequestHandler(cgImage: image).perform([request])
                result.removeAll()
                for observation in request.results ?? [] {
                    guard let text = observation.topCandidates(1).first?.string else { continue }
                    let box = observation.boundingBox
                    let point = NSPoint(x: box.midX * view.bounds.width, y: (view.isFlipped ? 1 - box.midY : box.midY) * view.bounds.height)
                    let label = text.filter(\.isLetter).lowercased()
                    result[label] = view.convert(point, to: nil)
                    // Vision can read a button's SF Symbol as a leading letter.
                    for key in ["openinseparatewindow", "backtoticket", "buildsession"] where label.hasSuffix(key) {
                        result[key] = view.convert(point, to: nil)
                    }
                }
                if result[target] != nil || alternate.flatMap({ result[$0] }) != nil { break }
            }
            guard result[target] != nil || alternate.flatMap({ result[$0] }) != nil else {
                throw RecorderError.message("Missing \(target) in rendered labels \(result.keys.sorted())")
            }
            return result
        }
        func click(_ point: NSPoint, in window: NSWindow) {
            if let content = window.contentView {
                var hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
                while let view = hit {
                    if let button = view as? NSButton { button.performClick(nil); return }
                    hit = view.superview
                }
            }
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(event(.leftMouseUp), atStart: true)
            window.sendEvent(event(.leftMouseDown))
        }
        func notesEditor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable && !text.isFieldEditor { return text }
            return view.subviews.lazy.compactMap(notesEditor).first
        }
        if checkBoardDrag {
            guard CGPreflightPostEventAccess() else { throw RecorderError.message("The pointer fixture needs event-posting access.") }
            let previousApp = NSWorkspace.shared.frontmostApplication
            let previousPointer = CGEvent(source: nil)?.location
            defer {
                window.orderOut(nil)
                if let previousPointer { CGWarpMouseCursorPosition(previousPointer) }
                previousApp?.activate(options: [])
            }
            NSApp.activate(ignoringOtherApps: true)
            func checkDrags(in window: NSWindow, content: NSView, location: String) async throws {
                window.setContentSize(NSSize(width: 1050, height: 670))
                window.center()
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                await pump()
                let first = try await labels(in: content, waitingFor: "planlaunchreview")
                guard let firstCard = first["planlaunchreview"] else { throw RecorderError.message("Missing fixture ticket") }
                for (column, heading, padding) in [("in-progress", "inprogress", false), ("todo", "todo", true)] {
                    var current = try await labels(in: content, waitingFor: "planlaunchreview")
                    // The store can finish a move before SwiftUI displays the card in its new column.
                    for _ in 0..<10 where padding {
                        if let card = current["planlaunchreview"], let middle = current["inprogress"], card.x > middle.x { break }
                        current = try await labels(in: content, waitingFor: "planlaunchreview")
                    }
                    guard var start = current["planlaunchreview"], let nextHeading = current["done"],
                          let targetHeading = current[heading] else { throw RecorderError.message("Missing fixture column") }
                    // On the return trip, grab the blank space near the right edge of the middle card.
                    if padding {
                        guard let middle = current["inprogress"], start.x > middle.x else { throw RecorderError.message("Ticket did not appear in its new column") }
                        start.x = nextHeading.x - 55
                    }
                    let end = NSPoint(x: targetHeading.x + 8, y: firstCard.y)
                    let before = NSPasteboard(name: .drag).changeCount
                    try await pointerDrag(from: start, to: end, in: window)
                    for _ in 0..<30 {
                        if try library.boardStore.read().ticket(localTicket.id).columnID == column { break }
                        await pump(0.05)
                    }
                    let saved = try library.boardStore.read().ticket(localTicket.id)
                    let origin = padding ? "card padding" : "title"
                    guard saved.columnID == column else {
                        let lifted = before != NSPasteboard(name: .drag).changeCount
                        throw RecorderError.message("Drag from \(origin) in the \(location) left ticket in \(saved.columnID), expected \(column). Drag pasteboard changed: \(lifted).")
                    }
                    print("PASS drag from \(origin) to \(column) in the \(location)")
                }
            }
            try await checkDrags(in: window, content: host, location: "library")
            library.boardWindows.openBoard(library: library)
            defer { library.boardWindows.closeAll() }
            guard let detached = NSApp.windows.first(where: { $0 !== window && $0.title == "Task board" }),
                  let content = detached.contentView else { throw RecorderError.message("Missing separate board window") }
            try await checkDrags(in: detached, content: content, location: "separate board window")
            _ = try library.boardStore.change(expectedRevision: library.boardStore.read().revision) { board in
                let lane = try board.saveGroup(.swimlane, name: "Ready")
                _ = try board.saveTicket(BoardTicket(title: "Ready target", columnID: "todo", swimlaneID: lane))
            }
            let grid = try await labels(in: content, waitingFor: "readytarget")
            guard let start = grid["planlaunchreview"], let end = grid["readytarget"] else { throw RecorderError.message("Missing swimlane target") }
            click(start, in: detached)
            _ = try await labels(in: content, waitingFor: "openinseparatewindow")
            let lift = NSPasteboard(name: .drag).changeCount
            try await pointerDrag(from: start, to: end, in: detached, slowStart: true)
            for _ in 0..<30 {
                if try library.boardStore.read().ticket(localTicket.id).swimlaneID != nil { break }
                await pump(0.05)
            }
            guard try library.boardStore.read().ticket(localTicket.id).swimlaneID != nil else {
                throw RecorderError.message("Selected card did not move to the next swimlane. Drag pasteboard changed: \(lift != NSPasteboard(name: .drag).changeCount).")
            }
            print("PASS slow drag of a selected card to another swimlane with the reader open")
            return
        }
        let boardLabels = try await labels(in: host, waitingFor: "planlaunchreview")
        require(boardLabels["newticket"] != nil && boardLabels["addticket"] == nil, "Ticket creation should appear only in the board header")
        guard let outline = sidebar(host) else { throw RecorderError.message("Missing board sidebar") }
        let row = outline.rect(ofRow: 0)
        let location = outline.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
        let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        guard let menu = outline.menu(for: rightClick), let item = menu.item(withTitle: "Open in New Window") else {
            throw RecorderError.message("The task board sidebar is missing its separate-window action")
        }
        menu.performActionForItem(at: menu.index(of: item))
        await pump()
        guard let boardWindow = NSApp.windows.first(where: { $0 !== window && $0.title == "Task board" && $0.isVisible }),
              let detachedBoard = boardWindow.contentView else { throw RecorderError.message("Task board window did not open") }
        boardWindow.setContentSize(NSSize(width: 1050, height: 700))
        boardWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let closedGrid = try await labels(in: detachedBoard, waitingFor: "inprogress")
        menu.performActionForItem(at: menu.index(of: item))
        require(NSApp.windows.filter { $0 !== window && $0.title == "Task board" && $0.isVisible }.count == 1,
                "The sidebar action opened a duplicate board window")
        func searchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField, field.placeholderString == "Search tickets" { return field }
            return view.subviews.lazy.compactMap(searchField).first
        }
        guard let detachedSearch = searchField(in: detachedBoard), let mainSearch = searchField(in: host) else {
            throw RecorderError.message("Both board windows need an independent search field")
        }
        func search(_ text: String) {
            detachedSearch.stringValue = text
            detachedSearch.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: detachedSearch))
        }
        search("release checklist")
        let matches = try await labels(in: detachedBoard, waitingFor: "match")
        require(matches["planlaunchreview"] != nil && matches["prepareagenda"] == nil && mainSearch.stringValue.isEmpty,
                "Board search must rank matching tickets in its own window")
        func resultsTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.numberOfRows == 1 { return table }
            return view.subviews.lazy.compactMap(resultsTable).first
        }
        guard let table = resultsTable(in: detachedBoard) else { throw RecorderError.message("Missing ranked ticket list") }
        let listWidth = table.bounds.width
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        _ = try await labels(in: detachedBoard, waitingFor: "openinseparatewindow")
        require(abs(table.bounds.width - listWidth) < 1, "Opening a ticket resized the search results")
        func divider(in view: NSView) -> NSView? {
            if view.accessibilityRole() == .splitter && view.accessibilityLabel() == "Ticket pane width" { return view }
            return view.subviews.lazy.compactMap(divider).first
        }
        func paneWidth() throws -> CGFloat {
            guard let handle = divider(in: detachedBoard) else { throw RecorderError.message("Missing ticket pane divider") }
            return detachedBoard.bounds.maxX - handle.convert(handle.bounds, to: detachedBoard).minX
        }
        let shortWidth = try paneWidth()
        require(abs(shortWidth - 420) < 1, "The short ticket opened at width \(shortWidth)")
        search("no ticket with this phrase")
        // The overlay may cover the empty-state text; the match count stays in the board header.
        _ = try await labels(in: detachedBoard, waitingFor: "matches", or: "omatches")
        require(resultsTable(in: detachedBoard) == nil, "The previous search row remained visible for an empty result")
        search("")
        let openGrid = try await labels(in: detachedBoard, waitingFor: "inprogress")
        require(abs(openGrid["inprogress"]!.x - closedGrid["inprogress"]!.x) < 2, "The ticket pane compressed the board columns")
        let agendaPoint = openGrid["prepareagenda"]!
        // The right end of the middle column's card is covered by the short ticket reader.
        if let edge = divider(in: detachedBoard) {
            let covered = NSPoint(x: edge.convert(edge.bounds, to: nil).maxX + 8, y: agendaPoint.y)
            click(covered, in: boardWindow)
            _ = try await labels(in: detachedBoard, waitingFor: "referencedetails")
        }
        click(agendaPoint, in: boardWindow)
        let longReader = try await labels(in: detachedBoard, waitingFor: "meetingdecisions")
        let longWidth = try paneWidth()
        require(abs(shortWidth - longWidth) < 1, "Long notes changed the width of the reader")
        guard let handle = divider(in: detachedBoard) else { throw RecorderError.message("Missing resize handle") }
        let grab = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func dragEvent(_ type: NSEvent.EventType, dx: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: grab.x + dx, y: grab.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: boardWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        handle.mouseDown(with: dragEvent(.leftMouseDown, dx: 0))
        handle.mouseDragged(with: dragEvent(.leftMouseDragged, dx: -64))
        handle.mouseUp(with: dragEvent(.leftMouseUp, dx: -64))
        await pump()
        let resized = try paneWidth()
        require(abs(resized - longWidth - 64) < 1, "Dragging the edge did not resize the ticket pane")
        click(longReader["planlaunchreview"]!, in: boardWindow)
        _ = try await labels(in: detachedBoard, waitingFor: "referencedetails")
        let switchedWidth = try paneWidth()
        require(abs(switchedWidth - resized) < 1, "Switching tickets discarded the adjusted pane width")
        click(boardLabels["planlaunchreview"]!, in: window)
        await pump()
        require(window.attachedSheet == nil, "Reading a ticket blocked the board")
        let reader = try await labels(in: host, waitingFor: "openinseparatewindow")
        require(reader["readthereleasechecklist"] != nil && reader["save"] == nil, "The ticket should open for reading")
        click(reader["openinseparatewindow"]!, in: window)
        await pump()
        guard let detached = NSApp.windows.first(where: { $0.title == "Plan launch review" }), let detachedContent = detached.contentView else {
            throw RecorderError.message("The separate ticket window did not open")
        }
        _ = try await labels(in: detachedContent, waitingFor: "readthereleasechecklist")
        click(reader["openinseparatewindow"]!, in: window)
        await pump()
        require(NSApp.windows.filter { $0.title == "Plan launch review" }.count == 1, "Opening this ticket created duplicate windows")
        guard let otherCard = reader["prepareagenda"] else { throw RecorderError.message("The second fixture card is outside the exposed board") }
        click(reader["edit"]!, in: window)
        let paneEditor = try await labels(in: host, waitingFor: "save")
        guard let paneNotes = notesEditor(in: host), let paneEdge = divider(in: host) else {
            throw RecorderError.message("The ticket pane did not show editable notes")
        }
        require(window.attachedSheet == nil && paneEditor["save"]!.x > paneEdge.convert(paneEdge.bounds, to: nil).maxX,
                "Edit should open inside the ticket pane")
        paneNotes.selectAll(nil)
        paneNotes.insertText("Unfinished notes.", replacementRange: paneNotes.selectedRange())
        click(otherCard, in: window)
        _ = try await labels(in: host, waitingFor: "meetingdecisions")
        click(boardLabels["planlaunchreview"]!, in: window)
        let resumed = try await labels(in: host, waitingFor: "cancel")
        require(notesEditor(in: host)?.string == "Unfinished notes.", "Switching cards lost the inline draft")
        click(resumed["cancel"]!, in: window)
        _ = try await labels(in: host, waitingFor: "openinseparatewindow")
        let unchanged = try library.boardStore.read()
        require(unchanged.revision == 2 && unchanged.tickets.first?.notes == "Read the release checklist.", "Cancel wrote the draft to the board")
        let detachedReader = try await labels(in: detachedContent, waitingFor: "buildsession")
        click(detachedReader["buildsession"]!, in: detached)
        let citation = try await labels(in: detachedContent, waitingFor: "sourceunavailable")
        click(citation["backtoticket"]!, in: detached)
        let returned = try await labels(in: detachedContent, waitingFor: "edit")
        click(returned["edit"]!, in: detached)
        let editor = try await labels(in: detachedContent, waitingFor: "save")
        require(detached.attachedSheet == nil, "Editing should stay in the ticket window")
        guard let notes = notesEditor(in: detachedContent) else { throw RecorderError.message("Ticket notes editor is missing") }
        notes.selectAll(nil)
        notes.insertText("My revised notes.", replacementRange: notes.selectedRange())
        _ = try agent.call("update_board_ticket", arguments: ["ticket_id": localTicket.id, "notes": "Agent revision.", "expected_revision": try boardRevision()])
        click(editor["save"]!, in: detached)
        let comparison = try await labels(in: detachedContent, waitingFor: "keepmyedit")
        require(comparison["agentrevision"] != nil && comparison["myrevisednotes"] != nil, "The comparison lost one version of the notes")
        click(comparison["keepmyedit"]!, in: detached)
        let resolved = try await labels(in: detachedContent, waitingFor: "editticket")
        require(resolved["myrevisednotes"] != nil, "Keeping the draft lost the edited notes")
        click(resolved["save"]!, in: detached)
        let finished = try await labels(in: detachedContent, waitingFor: "edit")
        let saved = try library.boardStore.read()
        require(saved.revision == 4 && saved.tickets.first?.notes == "My revised notes.",
                "Saving the chosen notes left revision \(saved.revision) with \(String(describing: saved.tickets.first?.notes))")
        require(finished["myrevisednotes"] != nil && finished["save"] == nil, "Saving did not return to the updated ticket")
        library.setSources([.board, .github])
        library.destination = .activity(.github)
        _ = try agent.call("update_board_ticket", arguments: ["ticket_id": localTicket.id, "notes": "Updated by agent.", "expected_revision": try boardRevision()])
        _ = try await labels(in: detachedContent, waitingFor: "updatedbyagent")
        library.destination = .page(.board)
        library.setSources([.github])
        require(!detached.isVisible && !boardWindow.isVisible, "Disabling the board left a board or ticket window open")
        print("PASS task board sidebar window, independent ticket search, live ticket updates, conflict resolution and source gating")
        require(library.destination == .activity(.github), "Disabling the board left its destination selected")
        library.destination = .page(.board)
        require(library.destination == .activity(.github), "A hidden board could still be opened")
        library.setSources([.board])
        let restored = try library.boardStore.read()
        require(restored.tickets.first?.title == "Plan launch review", "Re-enabling the board lost its tickets")
        for source in [ActivitySource.github, .coding] {
            library.setSources([source])
            await library.refresh()?.value
            // GitHub and unconfigured Coding each have only their root row.
            let rowCount = 1
            for _ in 0..<30 {
                await pump(0.05)
                host.layoutSubtreeIfNeeded()
                if sidebar(host)?.numberOfRows == rowCount { break }
            }
            require(sidebar(host)?.numberOfRows == rowCount, "The native sidebar displayed unrelated sources")
            require(library.filter == source.libraryFilter && library.issues.isEmpty, "Opening \(source) selected \(library.filter) with issues \(library.issues)")
            require(library.roots.isEmpty && defaults.object(forKey: "libraryFolders") == nil, "A non-recording source registered a folder")
            require(!recorder.sourceEnabled && recorder.devices.isEmpty, "A non-recording source started the recorder")
        }
        require(!CodingArchive.exists(in: library.coding.directory) && !GitHubArchive.exists(in: library.github.directory),
                "An unconfigured source created an archive")
        UserDefaults.standard.set(false, forKey: "KeyboardShortcuts_toggleCallRecording")
        library.setSources([.recordings])
        await library.refresh()?.value
        require(pickerCount == 0 && library.roots.isEmpty && library.issues.isEmpty, "Skipping the folder in setup produced a warning or registered a folder")
        recorder.selectedUID = "unavailable-test-device" // Exercise preparation without capturing live input.
        recorder.start(preview: true)
        require(pickerCount == 0 && recorder.state == .idle, "Testing audio requested a destination")
        recorder.toggleRecording()
        require(pickerCount == 1 && recorder.state == .idle && recorder.destination == nil, "Cancelling the first Record did not leave the recorder idle")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        chosenFolder = destination
        recorder.start()
        require(pickerCount == 2 && recorder.destination == destination && recorder.state == .idle, "First Record did not accept the chosen folder")
        recorder.start()
        require(pickerCount == 2, "Recording asked for the same folder twice")
        require(RecordingCoordinator(enabled: false).destination == destination, "The chosen recording destination did not survive relaunch")
        await library.refresh()?.value
        let savedFolders = defaults.stringArray(forKey: "libraryFolders")
        require(library.filter == .recordings && recorder.sourceEnabled && savedFolders?.count == 1, "Recordings did not start independently")
        library.setSources([.recordings, .coding])
        require(library.sources == [.recordings, .coding] && recorder.sourceEnabled, "Adding coding interrupted recording setup")
        library.destination = .calendar(.people)
        library.setSources([.github])
        await library.refresh()?.value
        require(library.destination == .activity(.github), "Disabling recordings left the directory selected")
        require(!recorder.sourceEnabled && recorder.devices.isEmpty && library.roots.isEmpty, "Turning off recording left capture resources active")
        require(defaults.stringArray(forKey: "libraryFolders") == savedFolders, "Turning off recording removed folder preferences")
        library.setSources([.recordings])
        require(library.roots.map(\.path) == savedFolders, "Re-enabling recording lost its folders")
        library.setSources([])
        require(library.activity.isEmpty && library.refresh() == nil, "Turning off all sources left activity visible")
        let reopened = RecordingLibraryModel(recorder: recorder, defaults: defaults, embeddingDirectory: embeddings)
        require(reopened.sources.isEmpty && reopened.roots.isEmpty, "An explicit empty selection was treated as an upgrade")
        let setupFolder = support.appendingPathComponent("ChosenDuringSetup", isDirectory: true)
        try FileManager.default.createDirectory(at: setupFolder, withIntermediateDirectories: true)
        reopened.setSources([.recordings], recordingDestination: setupFolder)
        require(recorder.destination == setupFolder && reopened.roots.contains(setupFolder.resolvingSymlinksInPath().standardizedFileURL), "Setup did not register the chosen recording destination")
        try FileManager.default.removeItem(at: setupFolder)
        await reopened.refresh()?.value
        require(reopened.issues.contains { $0.contains("ChosenDuringSetup") }, "The library hid a missing chosen folder")
        reopened.shutdown()
        let legacyFolder = support.appendingPathComponent("Music/Call Recordings", isDirectory: true)
        let legacyPath = legacyFolder.resolvingSymlinksInPath().standardizedFileURL.path
        defaults.set([legacyPath, destination.path], forKey: "libraryFolders")
        defaults.removeObject(forKey: "migratedImplicitRecordingFolder")
        require(RecordingLibraryModel.savedRecordingFolders(in: defaults, legacyDestination: legacyFolder).map(\.path) == [destination.path],
                "Upgrade kept a missing implicit folder or removed another library folder")
        defaults.set([legacyPath], forKey: "libraryFolders")
        require(RecordingLibraryModel.savedRecordingFolders(in: defaults, legacyDestination: legacyFolder).count == 1,
                "Upgrade cleanup repeated on a subsequently added folder")
        defaults.removeObject(forKey: "migratedImplicitRecordingFolder")
        defaults.set(legacyPath, forKey: "destination")
        require(RecordingLibraryModel.savedRecordingFolders(in: defaults, legacyDestination: legacyFolder).count == 1,
                "Upgrade removed the explicitly selected former default")
        print("PASS fresh launch, each standalone source, live switching, folder preservation, and explicit empty selection on relaunch")
    }

    @MainActor static func checkGitHub(library: RecordingLibraryModel) async throws {
        let archive = try GitHubArchive(directory: library.github.directory)
        let repo = GitHubRepository(id: "repo", name: "samples/library")
        try archive.connect(.init(id: "user", login: "fixture"))
        try archive.select(repo)
        let selection = try archive.selections()[0]
        let date = Date()
        try archive.begin(selection, now: date)
        guard let work = try archive.next(selection) else { throw RecorderError.message("Missing GitHub fixture queue") }
        let url = "https://github.com/samples/library/pull/42"
        let item = GitHubItem(id: "pr", repositoryID: repo.id, type: "pr", title: "Garden watering schedule", author: "colleague",
                              state: "OPEN", url: url, number: 42)
        let passage = GitHubPassage(id: "line", actorID: "user", text: "## Irrigation schedule", url: url + "#discussion_r42",
                                    kind: .inline, date: date, edited: nil, verdict: nil, path: "garden.swift", line: 9)
        var page = GitHubPage()
        page.entries = [(item, passage)]
        try archive.commit(page, work: work, repo: selection)
        library.filter = .activity
        library.search = ""
        await library.refresh()?.value
        require(library.activity.first?.id == "github:pr", "Recent GitHub contribution is missing from the mixed timeline")
        require(library.githubReferences["samples/library#42"] == "pr", "Qualified GitHub reference failed to resolve")
        library.openGitHub("pr")
        require(library.filter == .github && library.selectedGitHub?.id == "pr", "Opening a qualified reference lost the selection")
        library.githubRepository = repo.name
        library.githubAction = "review"
        await library.updateSearch(debounce: false)?.value
        require(library.activity.isEmpty, "Review filter returned an inline comment")
        library.githubAction = "inline"
        library.githubPeriod = .lastWeek
        await library.updateSearch(debounce: false)?.value
        require(library.visibleGitHub.isEmpty, "Last week's filter included today's comment")
        library.githubPeriod = .today
        library.githubType = "pr"
        library.search = "#42"
        await library.updateSearch(debounce: false)?.value
        guard let hit = library.selectedGitHub else { throw RecorderError.message("Scoped item number did not find the pull request") }
        let citation = BoardReference(source: .github, itemID: hit.id, anchor: passage.id, label: "Review comment")
        let view = NSHostingView(rootView: BoardCitationView(reference: citation, library: library))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 680, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.displayIfNeeded()
        defer { window.orderOut(nil) }
        func text(_ node: NSObject) -> [String] {
            let children = node.accessibilityAttributeValue(.children) as? [NSObject] ?? []
            return [node.accessibilityAttributeValue(.value) as? String, node.accessibilityAttributeValue(.title) as? String]
                .compactMap { $0 } + children.flatMap(text)
        }
        var displayed = ""
        for _ in 0..<40 {
            await pump(0.05)
            view.layoutSubtreeIfNeeded()
            displayed = text(view).joined(separator: " ")
            if displayed.contains("Irrigation schedule") { break }
        }
        require(displayed.contains("Garden watering schedule") && displayed.contains("garden.swift:9") &&
                displayed.contains("Irrigation schedule") && !displayed.contains("## Irrigation schedule"),
                "GitHub timeline did not render the saved Markdown and file citation")
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw RecorderError.message("Could not render the citation") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw RecorderError.message("Could not inspect the citation") }
        let ocr = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: image).perform([ocr])
        let labels = (ocr.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        require(labels.localizedCaseInsensitiveContains("private to Afterword"), "Missing private citation status in \(labels)")
        try archive.disconnect()
        library.githubRepository = ""
        library.githubAction = ""
        library.githubType = ""
        library.githubPeriod = .any
        library.search = ""
        await library.refresh()?.value
        require(library.visibleGitHub.isEmpty && library.githubReferences.isEmpty, "Removed GitHub item remained in the library")
        let disconnected = GitHubCoordinator(directory: library.github.directory.appendingPathComponent("new-account"))
        let settings = NSHostingView(rootView: GitHubSettingsView(github: disconnected).frame(width: 560, height: 640))
        window.contentView = settings
        func hasTokenField(_ view: NSView) -> Bool {
            if view is NSSecureTextField { return !view.isHiddenOrHasHiddenAncestor }
            return view.subviews.contains(where: hasTokenField)
        }
        for _ in 0..<40 {
            await pump(0.05)
            settings.layoutSubtreeIfNeeded()
            if hasTokenField(settings) { break }
        }
        require(hasTokenField(settings), "GitHub settings must show a secure token field on first connection")
        try await checkGitHubPicker(in: window)
        print("PASS native GitHub timeline, Markdown, source filters, qualified navigation, removal, and token setup")
    }

    @MainActor static func checkGitHubPicker(in window: NSWindow) async throws {
        let api = GitHubRepository(id: "api", name: "team/core-api")
        let warehouse = GitHubRepository(id: "data", name: "team/data-warehouse")
        let other = GitHubRepository(id: "other", name: "other/data-warehouse")
        let repos = [api, warehouse, other] + (0..<600).map { GitHubRepository(id: "r\($0)", name: "samples/repo-\($0)") }
        require(GitHubRepositoryPicker.matches(repos, owner: "team", query: "DATA ware") == [warehouse],
                "Owner and multi-word repository filters disagreed")
        require(GitHubRepositoryPicker.matches(repos, owner: "", query: "https://github.com/team/core-api.git") == [api],
                "Pasting a repository URL failed")
        let exact = GitHubRepository(id: "core", name: "team/core")
        require(GitHubRepositoryPicker.matches([api, exact], owner: "", query: "core") == [exact, api],
                "An exact repository name should come first")
        let host = NSHostingView(rootView: GitHubRepositoryPicker(scope: .available, available: repos, imported: [],
                                                                  shared: [], loading: false) { _, _ in
            require(false, "Filtering the repository picker changed stored settings")
        })
        window.contentView = host
        window.setContentSize(NSSize(width: 620, height: 510))
        await pump()
        func descendant<T: NSView>(_ type: T.Type, in node: NSView) -> T? {
            if let match = node as? T, (node as? NSTextField)?.isEditable != false { return match }
            return node.subviews.lazy.compactMap { descendant(type, in: $0) }.first
        }
        guard let scroll = descendant(NSScrollView.self, in: host), let text = descendant(NSTextField.self, in: host),
              window.makeFirstResponder(text), let editor = text.currentEditor() as? NSTextView else {
            throw RecorderError.message("Native repository list or search field missing")
        }
        let fullHeight = scroll.documentView?.frame.height ?? 0
        require(fullHeight > scroll.frame.height * 2, "The picker did not lay out the full repository list")
        editor.insertText("warehouse", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        await pump()
        require((scroll.documentView?.frame.height ?? fullHeight) < fullHeight / 2, "Typing in the repository picker did not filter the list")
        print("PASS repository picker native list and search across 603 repositories")
    }

    @MainActor static func checkRecordingStartup(root: URL, audio: URL) async throws {
        let calls = root.appendingPathComponent("Calls").resolvingSymlinksInPath()
        let embeddings = root.appendingPathComponent("Embeddings")
        let people = root.appendingPathComponent("People.json")
        func makeCall(_ day: Int) throws -> URL {
            let folder = calls.appendingPathComponent("Call-2026-11-\(day)_09-30-00")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: audio, to: folder.appendingPathComponent(RecordingTrack.mixed.filename))
            return folder
        }
        let saved = try makeCall(10), newer = try makeCall(11), personal = try makeCall(12), removed = try makeCall(13)
        let index = try LibrarySearchIndex(roots: [calls], directory: root.appendingPathComponent("Search"),
                                           embeddingDirectory: embeddings, peopleURL: people, callScope: .work)
        let cached = try index.synchronize()
        require(cached.count == 4, "Expected four cached Work recordings")
        guard let moved = cached.first(where: { $0.url.path == personal.path }) else {
            throw RecorderError.message("Missing cached recording for the scope change")
        }
        try CallDetailsStore.setScope(.personal, for: moved)
        try FileManager.default.removeItem(at: removed)

        let directory = root.appendingPathComponent("CodingSessions")
        _ = try CodingArchive(directory: directory)
        let db = try SearchDatabase(url: directory.appendingPathComponent("History.sqlite"), durable: true)
        // Force the shared search index to wait on the coding archive during launch.
        try db.execute("DROP INDEX sessions_branch_recent")
        try db.execute("BEGIN IMMEDIATE")
        try ActivitySourceStore.save([.recordings, .coding], directory: root.appendingPathComponent("MCP"))
        let suite = "io.local.afterword.recordingstartup." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([calls.path], forKey: "libraryFolders")
        defaults.set(true, forKey: "migratedImplicitRecordingFolder")
        defaults.set(saved.path, forKey: "librarySelection")
        let recorder = RecordingCoordinator(peopleURL: people, enabled: false, recoveryRoot: root.appendingPathComponent("Sessions"))
        let previousDestination = recorder.destination
        recorder.destination = calls
        defer { recorder.destination = previousDestination }
        let library = RecordingLibraryModel(recorder: recorder, defaults: defaults, embeddingDirectory: embeddings)
        defer { library.shutdown(); recorder.setSourceEnabled(false); recorder.transcription.shutdown() }
        library.refreshOnOpen()
        library.refreshOnOpen()
        for _ in 0..<100 {
            if !library.visibleRecordings.isEmpty { break }
            await pump(0.02)
        }
        require(library.refreshing && library.visibleRecordings.map(\.id) == [newer.path, saved.path],
                "Opening the library waited for coding search or displayed stale recordings")
        require(library.selectedRecording?.id == saved.path, "Opening the library lost the selected recording")
        library.search = "no such recording"
        try db.execute("COMMIT")
        for _ in 0..<200 {
            if library.resultQuery == library.search { break }
            await pump(0.02)
        }
        require(library.resultQuery == library.search && library.visibleRecordings.isEmpty,
                "A search entered during startup did not finish")
        print("PASS recording startup during blocked indexing, saved selection, current scope, and queued search")
    }

    @MainActor static func checkCodingPages(_ root: URL) async throws {
        let directory = root.appendingPathComponent("CodingSessions")
        try CodingArchive(directory: directory).setEnabled(true, for: .claudeCode)
        let db = try SearchDatabase(url: directory.appendingPathComponent("History.sqlite"), durable: true)
        try db.execute("""
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<450)
            , summaries AS (SELECT i, json_object('id',printf('s%03d',i),'project','/fixture',
              'title',CASE WHEN i=1 THEN 'archivedneedle' ELSE 'fixture' END,'source',CASE WHEN i=1 THEN 'claude-code' ELSE 'codex' END,
              'branch',CASE WHEN i=1 THEN 'old' ELSE 'main' END,'updated',i) AS info FROM n)
            INSERT INTO sessions SELECT printf('s%03d',i), '/fixture', i, info,
              json_object('session',json(info),'messages',json('[]'),'conversationIDs',json('[]')) FROM summaries
            """)
        try db.execute("INSERT INTO coding_text VALUES ('s001','','1','0','archivedneedle','/fixture','old','','0')")
        // Hold up the importer's schema update while the UI opens the saved SQLite page.
        try db.execute("DROP INDEX sessions_branch_recent")
        try db.execute("BEGIN IMMEDIATE")
        try ActivitySourceStore.save([.coding], directory: root.appendingPathComponent("MCP"))
        let recorder = RecordingCoordinator(enabled: false)
        let library = RecordingLibraryModel(recorder: recorder, embeddingDirectory: root.appendingPathComponent("Embeddings"))
        defer { library.shutdown() }
        func waitFor(_ message: String, _ ready: () -> Bool) async throws {
            for _ in 0..<150 { if ready() { return }; try await Task.sleep(for: .milliseconds(20)) }
            throw RecorderError.message(message)
        }
        try await waitFor("Cached page did not appear while import was blocked") { library.visibleCoding.count == 200 }
        require(library.coding.busy && library.hasMoreCoding, "Cached page waited for synchronization")
        require(library.visibleCoding.first?.id == "s450" && library.visibleCoding.last?.id == "s251", "Incorrect first page")
        let history = try CodingArchive.history(in: directory, id: "s450")
        require(history.session.id == "s450", "The selected session could not open during import")
        let playback = RecordingPlayback(states: recorder.$state.eraseToAnyPublisher())
        defer { playback.shutdown() }
        let host = NSHostingView(rootView: RecordingLibraryView(library: library, recorder: recorder, playback: playback, showControls: {}))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1180, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.orderBack(nil); window.displayIfNeeded()
        defer { window.orderOut(nil) }
        func sessionTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.numberOfRows == 200 { return table }
            return view.subviews.lazy.compactMap { sessionTable($0) }.first
        }
        try await waitFor("First page did not render in the session list") { sessionTable(host) != nil }
        await pump(0.15)
        require(library.visibleCoding.count == 200, "Rendering the top of the list loaded older pages")
        sessionTable(host)?.scrollRowToVisible(199)
        try await waitFor("Second page waited for import") { library.visibleCoding.count == 400 }
        try db.execute("DELETE FROM sessions WHERE id='s450'")
        try db.execute("INSERT OR REPLACE INTO settings VALUES ('revision','changed')")
        try db.execute("COMMIT")
        try await waitFor("Refresh lost the loaded range or kept a deleted session") {
            library.visibleCoding.count == 400 && library.visibleCoding.first?.id == "s449"
        }
        await library.refresh()?.value
        library.search = "archivedneedle"
        await library.updateSearch(debounce: false)?.value
        require(library.visibleCoding.map(\.id) == ["s001"] && library.coding.sessions.count == 400,
                "Search missed a session outside the loaded pages")
        library.search = ""
        library.loadOlderCoding(after: "s050")
        try await waitFor("Final page did not load") { !library.hasMoreCoding && library.visibleCoding.count == 449 }
        require(Set(library.visibleCoding.map(\.id)).count == 449, "Paging repeated a session")
        library.filter = .claudeCode
        try await waitFor("Provider filter missed the oldest row") { library.visibleCoding.map(\.id) == ["s001"] }
        library.filter = .coding; library.codingBranch = "old"
        try await waitFor("Branch filter missed the oldest row") { library.visibleCoding.map(\.id) == ["s001"] }
        require(library.coding.branches == ["main", "old"], "Branch picker only contained loaded pages")
        print("PASS cached first paint and detail during a blocked import, native scrolling, concurrent removal, and archive-wide search and filters")
    }

    @MainActor static func checkCodingSidebar(root: URL, library: RecordingLibraryModel, recorder: RecordingCoordinator, playback: RecordingPlayback) async throws {
        try checkQuestionReplies()
        let pending = root.appendingPathComponent("Call-2026-11-14_10-00-00")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pending) }
        let mixed = library.recordings[0].url.appendingPathComponent("Mixed.m4a")
        try FileManager.default.copyItem(at: mixed, to: pending.appendingPathComponent("Mixed.m4a"))
        let projects = root.appendingPathComponent("ClaudeConfig/projects")
        let project = projects.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = project.appendingPathComponent(UUID().uuidString + ".jsonl")
        let sessionText = #"""
        {"type":"assistant","uuid":"old","cwd":"/projects/fixture","message":{"content":"## Earlier decision\n\n- **The retry** used archivedterm."}}
        {"type":"system","uuid":"boundary","logicalParentUuid":"old"}
        {"type":"user","uuid":"first","parentUuid":"boundary","cwd":"/projects/fixture","message":{"content":"Document the retry behavior"}}
        {"type":"assistant","uuid":"investigate","parentUuid":"first","message":{"content":"I’ll trace how the retry works."}}
        {"type":"assistant","uuid":"answer","parentUuid":"investigate","message":{"content":"## Current decision\n\n- **The retry** preserves the original message.\n\n````text\n```\n**literal**\n````"}}
        {"type":"assistant","uuid":"tools-1","parentUuid":"answer","message":{"content":[{"type":"tool_use","id":"t1","name":"Read"},{"type":"tool_use","id":"t2","name":"Read"}]}}
        {"type":"assistant","uuid":"tools-2","parentUuid":"tools-1","message":{"content":[{"type":"tool_use","id":"t3","name":"InspectLayout"}]}}
        {"type":"assistant","uuid":"reply","parentUuid":"tools-2","message":{"content":"Retries are now documented with a worked example."}}
        {"type":"user","uuid":"again","parentUuid":"reply","message":{"content":"Run the integration tests once more and tell me whether the final result matches the expected behavior."}}
        {"type":"assistant","uuid":"tools-3","parentUuid":"again","message":{"content":[{"type":"tool_use","id":"t4","name":"Test"}]}}
        {"type":"user","uuid":"review","parentUuid":"tools-3","origin":{"kind":"task-notification"},"message":{"content":"<task-notification><status>completed</status><summary>Review finished</summary><result>```json\n[{\"file\":\"App.swift\",\"line\":17,\"summary\":\"Check the reviewneedle result.\",\"severity\":\"warning\",\"failure_scenario\":\"A saved setting is lost.\"}]\n```</result></task-notification>"}}
        """#
        // Alternate short prompts and tall replies so the lazy stack's estimated height changes as it scrolls.
        let prompt = "Review this section."
        let paragraph = "This paragraph wraps across several lines in a narrow window. "
        let turns = try (0..<32).map { index in
            let user = index.isMultiple(of: 2)
            let body = user ? prompt : String(repeating: paragraph + "\n\n", count: index % 7 + 8) + "End of reply \(index)."
            let event: [String: Any] = ["type": user ? "user" : "assistant", "uuid": "turn-\(index)",
                                        "parentUuid": index == 0 ? "review" : "turn-\(index - 1)", "message": ["content": body]]
            return String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        }
        try Data(([sessionText] + turns).joined(separator: "\n").utf8).write(to: source)
        let archive = try CodingArchive(directory: library.coding.directory)
        try archive.setEnabled(true); try archive.addProject("/projects/fixture")
        try archive.synchronize(reader: ClaudeCodeReader(projectsDirectory: projects))
        let codexHome = root.appendingPathComponent("CodexHome")
        let rollouts = codexHome.appendingPathComponent("sessions/2026/01/02")
        try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
        let thread = "00000000-0000-4000-a000-000000000001"
        let rollout = """
        {"type":"session_meta","payload":{"id":"\(thread)","cwd":"/projects/fixture"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"Review the layout"}}
        {"type":"event_msg","payload":{"type":"agent_message","id":"progress","message":"I’ll check how the cells line up."}}
        {"type":"event_msg","payload":{"type":"agent_message","id":"answer","message":"## Grid layout\\n\\nUse **hexagons** for this grid."}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """
        try Data(rollout.utf8).write(to: rollouts.appendingPathComponent("rollout-fixture-\(thread).jsonl"))
        try archive.setEnabled(true, for: .codex)
        try archive.synchronize(reader: CodexReader(homeDirectory: codexHome))
        library.coding.refresh()
        for _ in 0..<100 { if !library.coding.busy { break }; await pump(0.02) }
        await library.refresh()?.value
        let controller = RecordingLibraryWindow(library: library, recorder: recorder, playback: playback, showControls: {})
        let window = controller.window!
        let host = window.contentViewController!.view
        defer { withExtendedLifetime(controller) {} }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil); window.displayIfNeeded()
        defer { window.orderOut(nil) }
        await pump()
        func outline(in view: NSView) -> NSOutlineView? {
            if let view = view as? NSOutlineView, view.numberOfRows > 1, view.level(forRow: 1) == 1 { return view }
            return view.subviews.lazy.compactMap { outline(in: $0) }.first
        }
        guard let tree = outline(in: host) else { throw RecorderError.message("Missing library sidebar outline") }
        let rows: [(LibraryFilter, Int, [String])] = [
            (.activity, 2, ["Claude Code", "Codex"]), (.coding, 0, ["Claude Code", "Codex"]),
            (.codex, 0, ["Codex"]), (.claudeCode, 0, ["Claude Code"]),
            (.recordings, 2, []), (.transcribed, 1, []), (.untranscribed, 1, []), (.needsSummary, 1, []), (.personal, 0, []), (.github, 0, [])
        ]
        let totalRows = rows.count + 2
        require((0..<tree.numberOfRows).map(tree.level(forRow:)) == [0, 1, 2, 2, 1, 2, 2, 2, 2, 1, 0, 0], "Incorrect sidebar hierarchy")
        for (index, (filter, recordings, providers)) in rows.enumerated() {
            tree.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            for _ in 0..<30 {
                await pump(0.05)
                if library.filter == filter && library.visibleRecordings.count == recordings &&
                    library.visibleCoding.map(\.providerName).sorted() == providers { break }
            }
            require(library.filter == filter && library.visibleRecordings.count == recordings &&
                    library.visibleCoding.map(\.providerName).sorted() == providers, "Wrong contents for \(filter.rawValue)")
            if filter == .untranscribed { require(library.selectedRecording?.url.lastPathComponent == pending.lastPathComponent, "Expected the recording awaiting transcription") }
        }
        tree.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false); await pump()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = descendants(host).compactMap { $0 as? NSScrollView }.first {
            ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 700 && $0.contentView.bounds.height > 100
        }
        guard let scroll else { throw RecorderError.message("Missing conversation scroll view") }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        await pump()
        func firstVisibleParagraph() -> String? {
            guard let document = scroll.documentView else { return nil }
            return descendants(document).compactMap { view -> (String, CGFloat)? in
                guard let field = view as? NSTextField, !field.stringValue.isEmpty else { return nil }
                let rect = field.convert(field.bounds, to: document)
                guard scroll.documentVisibleRect.contains(rect) else { return nil }
                return (field.stringValue, rect.minY - scroll.documentVisibleRect.minY)
            }.min { $0.1 < $1.1 }?.0
        }
        let paragraphAtTop = firstVisibleParagraph()
        let offset = scroll.contentView.bounds.origin.y
        let saved = library.selection
        let visibleWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        func hasLibrarySearch() -> Bool {
            window.toolbar?.items.contains(where: { $0 is NSSearchToolbarItem }) == true
        }
        require(offset > 100 && hasLibrarySearch(), "Expected a scrolled conversation and library search toolbar, offset \(offset), items \(window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? [])")
        for (index, page) in LibraryCalendarPage.allCases.enumerated() {
            let row = rows.count + index
            tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await pump()
            require(tree.selectedRow == row && library.destination == .calendar(page), "Sidebar did not select \(page.rawValue) in place")
            require(!hasLibrarySearch() && saved == library.selection && library.filter == .claudeCode, "Calendar navigation changed activity state or retained its search field")
            require(Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)) == visibleWindows, "Sidebar selection opened another window")
            let rect = tree.rect(ofRow: row)
            let point = tree.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
            guard let menu = tree.menu(for: event), let item = menu.item(withTitle: "Open in New Window") else {
                throw RecorderError.message("Missing pop-out action for \(page.rawValue)")
            }
            menu.performActionForItem(at: menu.index(of: item))
            await pump()
            guard let popout = NSApp.windows.first(where: {
                $0.isVisible && !visibleWindows.contains($0.windowNumber) &&
                $0.title.localizedCaseInsensitiveCompare(page.rawValue) == .orderedSame
            }) else { throw RecorderError.message("Context menu did not open a separate \(page.rawValue) window") }
            require(library.destination == .calendar(page), "Opening a separate window changed the library destination")
            popout.close()
        }
        tree.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false); await pump()
        require(library.destination == .activity(.claudeCode) && library.selection == saved && hasLibrarySearch(), "Returning to activity lost selection or search")
        require(scroll.window === window && abs(scroll.contentView.bounds.origin.y - offset) < 2 &&
                paragraphAtTop != nil && firstVisibleParagraph() == paragraphAtTop, "Returning to activity lost the conversation scroll position: wanted \(offset), got \(scroll.contentView.bounds.origin.y), attached \(scroll.window === window)")
        library.destination = .activity(.transcribed)
        library.search = "clear transcript"
        await library.updateSearch(debounce: false)?.value
        let callID = library.selectedRecording?.id
        library.destination = .calendar(.people); await pump()
        library.destination = .activity(.transcribed); await pump()
        require(callID != nil && library.selectedRecording?.id == callID && library.search == "clear transcript",
                "Visiting the directory lost the selected call or its search")
        library.search = ""; await library.updateSearch(debounce: false)?.value
        print("PASS inline calendar navigation, independent windows, and activity scroll restoration")
        tree.selectRowIndexes(IndexSet(integer:7),byExtendingSelection:false); await pump()
        guard let awaitingSummary = library.selectedRecording, awaitingSummary.hasTranscript else {
            throw RecorderError.message("Needs summary should select the transcribed call")
        }
        try CallSummaryStore.save("A fixture summary", for: awaitingSummary, source: awaitingSummary.latestTranscript, author: "agent")
        for _ in 0..<100 where !library.visibleRecordings.isEmpty { await pump(0.05) }
        require(library.activity.isEmpty && library.selection == nil, "Agent-saved summary did not clear the queue")
        let summaryFile = CallSummaryStore.url(for: awaitingSummary.url, isDirectory: awaitingSummary.isDirectory)
        try Data("unreadable".utf8).write(to: summaryFile, options: .atomic)
        await library.refresh()?.value
        require(library.visibleRecordings.isEmpty, "An unreadable saved summary was treated as missing")
        try FileManager.default.removeItem(at: summaryFile)
        await library.refresh()?.value
        require(library.selectedRecording?.id == awaitingSummary.id, "A missing summary did not return to the queue")
        try await library.setScope(.personal, for: awaitingSummary)
        require(library.activity.isEmpty, "Marking a call Personal left it in Needs summary")
        library.filter = .activity
        require(!library.visibleRecordings.contains { $0.id == awaitingSummary.id }, "A personal call leaked into All activity")
        library.filter = .personal
        await library.refresh()?.value
        require(library.visibleRecordings.map(\.id) == [awaitingSummary.id], "Personal did not show exactly the reclassified call")
        try await library.setScope(.work, for: awaitingSummary)
        require(library.activity.isEmpty, "Moving a call to Work left it in Personal")
        library.filter = .needsSummary
        await library.refresh()?.value
        require(library.selectedRecording?.id == awaitingSummary.id, "Moving to Work failed to restore the call to Needs summary")
        tree.collapseItem(tree.item(atRow: 4)); await pump()
        require(tree.numberOfRows == totalRows - 4 && library.filter == .recordings, "Collapsing Recordings lost the active filter")
        tree.expandItem(tree.item(atRow: 4)); await pump()
        require(tree.numberOfRows == totalRows, "Expanding Recordings did not restore its children")
        library.filter = .claudeCode; library.search = "hexagons"
        await library.updateSearch(debounce: false)?.value
        require(library.visibleCoding.isEmpty, "A Codex search result leaked into Claude Code")
        library.filter = .codex
        require(library.selectedCoding?.providerName == "Codex", "Switching providers lost the matching search result")
        print("PASS native sidebar hierarchy, branch selection, disclosure, and provider-scoped search")

        func setImport(_ provider: CodingProvider, enabled: Bool, expectedRows: Int) async {
            library.coding.refresh(.enabled(provider, enabled), discover: true)
            for _ in 0..<100 {
                await pump(0.02)
                if !library.coding.busy && tree.numberOfRows == expectedRows { break }
            }
            require(!library.coding.busy && tree.numberOfRows == expectedRows, "Wrong sidebar after changing \(provider.name) import")
        }
        library.search = ""
        library.filter = .claudeCode
        await setImport(.claudeCode, enabled: false, expectedRows: totalRows - 1)
        require(library.filter == .coding, "Disabling the selected provider left its filter active")
        tree.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false); await pump(0.05)
        require(library.filter == .codex, "Claude Code was visible with only Codex enabled")
        await setImport(.codex, enabled: false, expectedRows: totalRows - 2)
        require(library.filter == .coding && library.visibleCoding.count == 2, "Pausing both providers hid saved sessions")
        await setImport(.claudeCode, enabled: true, expectedRows: totalRows - 1)
        tree.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false); await pump(0.05)
        require(library.filter == .claudeCode, "Re-enabling Claude Code did not restore its sidebar row")
        print("PASS provider sidebar visibility follows the import toggles and preserves saved sessions")

        library.filter = .coding; library.search = "preserves"
        await library.updateSearch(debounce: false)?.value
        guard let session = library.selectedCoding else { throw RecorderError.message("Coding search failed to select a result") }
        require(library.codingHits[session.id]?.messageID == "answer", "Coding search lost the message citation")
        try await checkSessionScrolling(session: session, directory: library.coding.directory)
        let history = try archive.history(id: session.id)
        for messages in [history.conversation, history.messages] {
            let rows = CodingConversationRow.group(messages)
            let calls = rows.filter { $0.toolCount > 0 }
            require(calls.map(\.toolCount) == [3, 1], "Tool groups lost calls or crossed a user turn")
            require(calls[0].id == "answer" && calls[0].contains("tools-2") && calls[1].id == "tools-3",
                    "Grouped tool calls lost their message anchors")
            require(calls[0].toolMessages.flatMap(\.tools) == ["Read", "Read", "InspectLayout"], "Tool disclosure lost the order of repeated calls")
        }
        typealias Thread = CodingConversationRow.AssistantThread
        let activeRows = CodingConversationRow.group(history.conversation)
        let threads = Dictionary(uniqueKeysWithValues: activeRows.compactMap { row in row.thread.map { (row.id, $0) } })
        require(threads == [
            "investigate": Thread(connectsAbove: false, connectsBelow: true, isReply: false),
            "answer": Thread(connectsAbove: true, connectsBelow: true, isReply: false),
            "reply": Thread(connectsAbove: true, connectsBelow: false, isReply: true),
            "tools-3": Thread(connectsAbove: false, connectsBelow: false, isReply: false)
        ], "Assistant updates, reply, or trailing tool activity were linked incorrectly")
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        func message(_ id: String, role: String = "Assistant", date: Date = today, tools: [String] = []) -> CodingMessage {
            CodingMessage(id: id, role: role, text: tools.isEmpty ? id : "", parentID: nil, timestamp: date, tools: tools)
        }
        let boundaries = CodingConversationRow.group([
            message("update"), message("overnight tools", date: tomorrow, tools: ["Read"]),
            CodingMessage(id: "empty", role: "Assistant", text: " \n", parentID: nil, timestamp: tomorrow, tools: []),
            message("interrupt", role: "Compaction summary", date: tomorrow), message("standalone", date: tomorrow)
        ])
        require(boundaries.map(\.id) == ["update", "overnight tools", "interrupt", "standalone"]
                && boundaries[1].dayHeading == tomorrow, "Overnight activity lost its day heading or anchor")
        require(boundaries.map(\.thread) == [Thread(connectsAbove: false, connectsBelow: false, isReply: false),
                                             Thread(connectsAbove: false, connectsBelow: false, isReply: false), nil, nil],
                "A date boundary promoted an update to a reply or a thread crossed a compaction")
        // SwiftUI exposes virtual text cells through AppKit's attribute interface.
        func visibleText(_ node: NSObject) -> [String] {
            let children = node.accessibilityAttributeValue(.children) as? [NSObject] ?? []
            let text = node.accessibilityAttributeValue(.value) as? String
            return (text.map { [$0] } ?? []) + children.flatMap(visibleText)
        }
        for (query, heading, provider) in [("preserves", "Current decision", "Claude Code"), ("archivedterm", "Earlier decision", "Claude Code"), ("InspectLayout", "Current decision", "Claude Code"), ("hexagons", "Grid layout", "Codex"), ("reviewneedle", "Check the reviewneedle result.", "Claude Code")] {
            library.search = query
            await library.updateSearch(debounce: false)?.value
            guard let session = library.selectedCoding, let hit = library.codingHits[session.id] else { throw RecorderError.message("Missing coding search hit") }
            let detail = NSHostingView(rootView: Group {
                if query == "archivedterm" || query == "InspectLayout" {
                    let ref = BoardReference(source: .coding, itemID: session.id, anchor: hit.messageID, label: heading)
                    BoardCitationView(reference: ref, library: library)
                } else {
                    CodingSessionDetail(session: session, directory: library.coding.directory, hit: hit)
                }
            })
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = detail; window.displayIfNeeded()
            var text = ""
            for _ in 0..<40 {
                await pump(0.05)
                detail.layoutSubtreeIfNeeded()
                text = visibleText(detail).joined(separator: "\n")
                if text.contains(heading) && (query != "InspectLayout" || text.contains("InspectLayout")) { break }
            }
            require(text.contains(heading) && !text.contains("## " + heading), "Coding message heading did not render: " + text)
            require(text.contains(provider), "The detail is missing its coding provider")
            if query == "InspectLayout" {
                require(hit.messageID == "tools-2" && text.contains("InspectLayout") && text.contains("Read"),
                        "Opening a tool search did not expand its group")
            }
            if query == "reviewneedle" {
                require(hit.messageID == "review" && text.contains("App.swift:17 · warning") && text.contains("A saved setting is lost."),
                        "Opening a review finding did not expand and render its location and scenario")
                require(!text.contains("<task-notification>"), "The task wrapper appeared in the conversation")
                window.orderOut(nil)
                continue
            }
            let bold = provider == "Codex" ? "hexagons" : "The retry"
            if provider == "Codex" {
                let rows = CodingConversationRow.group(try archive.history(id: session.id).conversation)
                require(text.contains("I’ll check how the cells line up.") && rows.compactMap(\.thread) == [
                    Thread(connectsAbove: false, connectsBelow: true, isReply: false),
                    Thread(connectsAbove: true, connectsBelow: false, isReply: true)
                ], "The Codex update and reply did not form one turn")
            }
            require(text.contains(bold) && !text.contains("**" + bold + "**"), "Inline Markdown did not render")
            if query == "preserves" { require(text.contains("```\n**literal**"), "Code fence lost literal Markdown") }
            require(!detail.hasAmbiguousLayout, "Coding detail layout is ambiguous")
            window.orderOut(nil)
        }
        print("PASS coding search opens labeled Claude Code and Codex sessions with rendered Markdown")
        try await checkProviderToggles(project: project, coding: library.coding)

        let piStore = root.appendingPathComponent("PiStore", isDirectory: true)
        try FileManager.default.createDirectory(at: piStore, withIntermediateDirectories: true)
        let piLog = #"""
        {"type":"session","version":3,"id":"fixture","cwd":"/projects/fixture"}
        {"type":"message","id":"prompt","parentId":null,"message":{"role":"user","content":"Pi sidebar fixture"}}
        """#
        try Data(piLog.utf8).write(to: piStore.appendingPathComponent("session.jsonl"))
        library.search = ""
        library.filter = .coding
        let pausedRows = tree.numberOfRows
        library.coding.refresh(.piDirectory(piStore))
        await setImport(.pi, enabled: true, expectedRows: pausedRows + 1)
        require(library.coding.piSessionsDirectory == piStore, "Pi store selection was lost")
        // Claude is the only other enabled provider and precedes Pi in the outline.
        tree.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        for _ in 0..<50 {
            await pump(0.02)
            if library.filter == .pi && library.visibleCoding.count == 1 { break }
        }
        require(library.filter == .pi && library.visibleCoding.map(\.providerName) == ["Pi"], "Pi sidebar filter did not show its session")
        await setImport(.pi, enabled: false, expectedRows: pausedRows)
        require(library.filter == .coding, "Pausing Pi left its sidebar filter selected")
        print("PASS Pi folder selection, import, and provider sidebar navigation")
    }

    @MainActor static func checkSessionScrolling(session: CodingSession, directory: URL) async throws {
        let detail = NSHostingView(rootView: CodingSessionDetail(session: session, directory: directory, hit: nil))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 540, height: 660),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = detail
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func isTextVisible(_ text: String) -> Bool {
            guard let scroll = descendants(detail).compactMap({ $0 as? NSScrollView }).first,
                  let document = scroll.documentView else { return false }
            return descendants(document).compactMap { $0 as? NSTextField }.contains { field in
                field.stringValue == text && scroll.documentVisibleRect.contains(field.convert(field.bounds, to: document))
            }
        }
        for _ in 0..<40 {
            await pump(0.05)
            if isTextVisible("End of reply 31.") { break }
        }
        require(isTextVisible("End of reply 31."), "The last paragraph must be visible when the chat opens")

        // Click the floating control through this window's event handler.
        let location = NSPoint(x: detail.bounds.width - 65, y: 26)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        for _ in 0..<60 {
            await pump(0.05)
            if isTextVisible("Document the retry behavior") { break }
        }
        require(isTextVisible("Document the retry behavior"), "Jump to top must reveal the first message")
        print("PASS last paragraph visible on open and first prompt visible after the floating Jump to top")
    }

    static func checkQuestionReplies() throws {
        func message(_ id: String, _ role: String, _ text: String) -> CodingMessage {
            .init(id: id, role: role, text: text, parentID: nil, timestamp: nil, tools: [])
        }
        func entry(_ question: String, _ answer: String, _ call: String, _ index: Int) throws -> [String: String] {
            let id = try JSONSerialization.data(withJSONObject: ["request_user_input_async", call, index] as [Any])
            return ["question": question, "answer": answer, "questionItemId": String(decoding: id, as: UTF8.self)]
        }
        func wrap(_ entries: [[String: String]]) throws -> String {
            let json = try JSONEncoder().encode(entries)
            return "<send_user_message_question_reply>\n" + String(decoding: json, as: UTF8.self) + "\n</send_user_message_question_reply>"
        }
        let first = try entry("Which branch?", "New branch", "call_a", 0)
        let second = try entry("Which tests?", "All tests", "call_a", 1)
        let missing = try entry("Which files?", "Both", "call_missing", 0)
        let one = try wrap([first])
        let plain = message("prompt", "Assistant", "Which branch?")
        let question = message("call_a", "Assistant", "Which branch?\n- New branch")
        let reply = message("reply", "User", one)
        func answers(_ messages: [CodingMessage]) throws -> [CodexQuestionReply.Answer] {
            guard case .answers(let answers) = CodingConversationRow.group(messages, provider: .codex).last?.questionReply else {
                throw RecorderError.message("Structured Codex answers were not recognized")
            }
            return answers
        }
        let direct = try answers([question, reply])
        require(direct.map(\.reference) == [.adjacent] && direct.map(\.answer) == ["New branch"], "Adjacent prompt repeated its question")
        let delayed = try answers([question, plain, reply])
        require(delayed.map(\.reference) == [.earlier("call_a")], "A newer message with the same text stole the link")
        let orphan = try answers([plain, reply])
        require(orphan.map(\.reference) == [.embedded], "A missing original linked by text alone")
        let batch = try answers([message("call_a", "Assistant", "Which branch?\n\nWhich tests?"),
                                 message("batch", "User", try wrap([second, missing, first]))])
        require(batch.map(\.reference) == [.earlier("call_a"), .embedded, .earlier("call_a")] &&
                batch.map(\.answer) == ["All tests", "Both", "New branch"], "Batched answers lost their questions or order")
        let repeated = message("call_a#2", "Assistant", question.text)
        let ambiguous = try answers([question, repeated, reply])
        let selected = try answers([repeated, plain, reply])
        require(ambiguous.map(\.reference) == [.embedded] && selected.map(\.reference) == [.earlier("call_a#2")],
                "Rolled-back questions must link only to an unambiguous occurrence")
        let bad = one.replacingOccurrences(of: "\"answer\"", with: "\"unknown\"")
        guard case .unrecognized = CodingConversationRow.group([message("bad", "User", bad)], provider: .codex).first?.questionReply else {
            throw RecorderError.message("An unfamiliar envelope failed to fall back to the original")
        }
        let example = message("example", "User", "For example:\n```\n" + one + "\n```")
        require(CodingConversationRow.group([example], provider: .codex)[0].questionReply == nil &&
                CodingConversationRow.group([reply], provider: .claudeCode)[0].questionReply == nil,
                "Ordinary messages containing protocol examples were reinterpreted")
        print("PASS Codex question replies, exact links, multiple answers, and original-text fallback")
    }

    @MainActor static func checkProviderToggles(project: URL, coding: CodingCoordinator) async throws {
        func addProject(_ name: String) throws {
            let row = #"{"type":"user","uuid":"first","cwd":"/fixture/\#(name)","message":{"content":"fixture"}}"#
            try Data(row.utf8).write(to: project.appendingPathComponent(UUID().uuidString + ".jsonl"))
        }
        for n in 0..<400 { try addProject("project-\(n)") }
        let settings = NSHostingView(rootView: CodingSettingsView(coding: coding))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 620, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = settings; window.orderBack(nil)
        defer { window.orderOut(nil) }
        func settle() async throws {
            for _ in 0..<250 {
                await pump(0.02)
                window.displayIfNeeded()
                if !coding.busy { return }
            }
            throw RecorderError.message("Timed out waiting for coding preferences")
        }
        func renderedCheckboxes(_ view: NSView) -> Int {
            let folder = (view as? NSButton)?.toolTip?.hasPrefix("/fixture") == true
            return (folder ? 1 : 0) + view.subviews.reduce(0) { $0 + renderedCheckboxes($1) }
        }
        try await settle()
        func projects() -> [CodingProjectFolder] { coding.folders.first { $0.path == "/fixture" }?.children ?? [] }
        require(projects().count == 400, "Settings did not discover the fixture projects")
        let visible = renderedCheckboxes(settings)
        require(visible > 0 && visible < 100, "Settings created \(visible) checkboxes for 400 projects")
        try addProject("discovered-on-refresh")
        let db = try SearchDatabase(url: coding.directory.appendingPathComponent("History.sqlite"), durable: true)
        try db.execute("BEGIN IMMEDIATE")
        for enabled in [true, false, true] {
            coding.refresh(.enabled(.codex, enabled), discover: true)
            require(coding.providers.contains(.codex) == enabled, "Toggle waited for the database or a scan")
            await pump(0.02)
        }
        try db.execute("COMMIT")
        try await settle()
        let archive = try CodingArchive(directory: coding.directory)
        let saved = try archive.settings()
        require(saved.providers == [.codex, .claudeCode], "Rapid toggles did not persist the final choice")
        require(projects().count == 400, "Enabling Codex rescanned Claude or discarded its project list")
        coding.refresh(.enabled(.codex, false), discover: true)
        try await settle()
        require(projects().count == 400, "Disabling Codex rescanned Claude")
        coding.refresh(discover: true)
        try await settle()
        require(projects().contains { $0.name == "discovered-on-refresh" }, "Explicit discovery missed a new project")
        print("PASS bounded project controls, responsive rapid toggles, persistence, and provider-scoped discovery")
    }
}
