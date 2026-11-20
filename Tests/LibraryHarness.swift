import AppKit
import SwiftUI
import AVFoundation
import Combine
@testable import RecorderCore
import Lookback

/// Own-window rendering and silent playback fixtures. Never starts capture or
/// changes the production app's defaults, files, or shortcut.
@main struct LibraryHarness {
    static let interactive = CommandLine.arguments.contains("--interactive")
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
    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-ui-" + UUID().uuidString)
        setenv("CLAUDE_CONFIG_DIR", root.appendingPathComponent("ClaudeConfig").path, 1)
        setenv("CODEX_HOME", root.appendingPathComponent("CodexHome").path, 1)
        let name = "io.local.afterword.librarycheck"
        guard Bundle.main.bundleIdentifier == name else { throw RecorderError.message("Run this harness in the Library Check test bundle") }
        UserDefaults.standard.removePersistentDomain(forName: name)
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: name) }
        if CommandLine.arguments.contains("--coding-pages") { try await checkCodingPages(root); return }
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
        require(library.sources == Set(ActivitySource.allCases), "Upgrading an existing recording library hid a source")
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

        try await checkCodingSidebar(root: root, library: library)
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
        library.setSources([.github])
        await library.refresh()?.value
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
        let view = NSHostingView(rootView: GitHubItemView(hit: hit, directory: library.github.directory, revision: "fixture"))
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

    @MainActor static func checkCodingSidebar(root: URL, library: RecordingLibraryModel) async throws {
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
        {"type":"assistant","uuid":"answer","parentUuid":"first","message":{"content":"## Current decision\n\n- **The retry** preserves the original message.\n\n````text\n```\n**literal**\n````"}}
        {"type":"assistant","uuid":"tools-1","parentUuid":"answer","message":{"content":[{"type":"tool_use","id":"t1","name":"Read"},{"type":"tool_use","id":"t2","name":"Read"}]}}
        {"type":"assistant","uuid":"tools-2","parentUuid":"tools-1","message":{"content":[{"type":"tool_use","id":"t3","name":"InspectLayout"}]}}
        {"type":"user","uuid":"again","parentUuid":"tools-2","message":{"content":"Run the integration tests once more and tell me whether the final result matches the expected behavior."}}
        {"type":"assistant","uuid":"tools-3","parentUuid":"again","message":{"content":[{"type":"tool_use","id":"t4","name":"Test"}]}}
        """#
        try Data(sessionText.utf8).write(to: source)
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
        {"type":"event_msg","payload":{"type":"agent_message","id":"answer","message":"## Grid layout\\n\\nUse **hexagons** for this grid."}}
        """
        try Data(rollout.utf8).write(to: rollouts.appendingPathComponent("rollout-fixture-\(thread).jsonl"))
        try archive.setEnabled(true, for: .codex)
        try archive.synchronize(reader: CodexReader(homeDirectory: codexHome))
        library.coding.refresh()
        for _ in 0..<100 { if !library.coding.busy { break }; await pump(0.02) }
        await library.refresh()?.value
        let sidebar = NSHostingView(rootView: LibrarySidebar(selection: Binding(get: { library.filter }, set: { library.filter = $0 }),
                                                           sources: library.sources, coding: library.coding))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 235, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = sidebar; window.displayIfNeeded()
        defer { window.orderOut(nil) }
        await pump()
        func outline(in view: NSView) -> NSOutlineView? {
            if let view = view as? NSOutlineView { return view }
            return view.subviews.lazy.compactMap { outline(in: $0) }.first
        }
        guard let tree = outline(in: sidebar) else { throw RecorderError.message("Missing library sidebar outline") }
        let rows: [(LibraryFilter, Int, [String])] = [
            (.activity, 2, ["Claude Code", "Codex"]), (.coding, 0, ["Claude Code", "Codex"]),
            (.codex, 0, ["Codex"]), (.claudeCode, 0, ["Claude Code"]),
            (.recordings, 2, []), (.transcribed, 1, []), (.untranscribed, 1, []), (.needsSummary, 1, []), (.personal, 0, []), (.github, 0, [])
        ]
        require((0..<tree.numberOfRows).map(tree.level(forRow:)) == [0, 1, 2, 2, 1, 2, 2, 2, 2, 1], "Incorrect sidebar hierarchy")
        for (index, (filter, recordings, providers)) in rows.enumerated() {
            tree.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            await pump(0.05)
            require(library.filter == filter && library.visibleRecordings.count == recordings &&
                    library.visibleCoding.map(\.providerName).sorted() == providers, "Wrong contents for \(filter.rawValue)")
            if filter == .untranscribed { require(library.selectedRecording?.url.lastPathComponent == pending.lastPathComponent, "Expected the recording awaiting transcription") }
        }
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
        require(tree.numberOfRows == 6 && library.filter == .recordings, "Collapsing Recordings lost the active filter")
        tree.expandItem(tree.item(atRow: 4)); await pump()
        require(tree.numberOfRows == rows.count, "Expanding Recordings did not restore its children")
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
        await setImport(.claudeCode, enabled: false, expectedRows: rows.count - 1)
        require(library.filter == .coding, "Disabling the selected provider left its filter active")
        tree.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false); await pump(0.05)
        require(library.filter == .codex, "Claude Code was visible with only Codex enabled")
        await setImport(.codex, enabled: false, expectedRows: rows.count - 2)
        require(library.filter == .coding && library.visibleCoding.count == 2, "Pausing both providers hid saved sessions")
        await setImport(.claudeCode, enabled: true, expectedRows: rows.count - 1)
        tree.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false); await pump(0.05)
        require(library.filter == .claudeCode, "Re-enabling Claude Code did not restore its sidebar row")
        print("PASS provider sidebar visibility follows the import toggles and preserves saved sessions")

        library.filter = .coding; library.search = "preserves"
        await library.updateSearch(debounce: false)?.value
        guard let session = library.selectedCoding else { throw RecorderError.message("Coding search failed to select a result") }
        require(library.codingHits[session.id]?.messageID == "answer", "Coding search lost the message citation")
        let history = try archive.history(id: session.id)
        for messages in [history.conversation, history.messages] {
            let rows = CodingConversationRow.group(messages)
            let calls = rows.filter { $0.toolCount > 0 }
            require(calls.map(\.toolCount) == [3, 1], "Tool groups lost calls or crossed a user turn")
            require(calls[0].id == "answer" && calls[0].contains("tools-2") && calls[1].id == "tools-3",
                    "Grouped tool calls lost their message anchors")
            require(calls[0].toolMessages.flatMap(\.tools) == ["Read", "Read", "InspectLayout"], "Tool disclosure lost the order of repeated calls")
        }
        // SwiftUI exposes virtual text cells through AppKit's attribute interface.
        func visibleText(_ node: NSObject) -> [String] {
            let children = node.accessibilityAttributeValue(.children) as? [NSObject] ?? []
            let text = node.accessibilityAttributeValue(.value) as? String
            return (text.map { [$0] } ?? []) + children.flatMap(visibleText)
        }
        for (query, heading, provider) in [("preserves", "Current decision", "Claude Code"), ("archivedterm", "Earlier decision", "Claude Code"), ("InspectLayout", "Current decision", "Claude Code"), ("hexagons", "Grid layout", "Codex")] {
            library.search = query
            await library.updateSearch(debounce: false)?.value
            guard let session = library.selectedCoding, let hit = library.codingHits[session.id] else { throw RecorderError.message("Missing coding search hit") }
            let detail = NSHostingView(rootView: CodingSessionDetail(session: session, directory: library.coding.directory, hit: hit))
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
            let bold = provider == "Codex" ? "hexagons" : "The retry"
            require(text.contains(bold) && !text.contains("**" + bold + "**"), "Inline Markdown did not render")
            if query == "preserves" { require(text.contains("```\n**literal**"), "Code fence lost literal Markdown") }
            require(!detail.hasAmbiguousLayout, "Coding detail layout is ambiguous")
            window.orderOut(nil)
        }
        print("PASS coding search opens labeled Claude Code and Codex sessions with rendered Markdown")
        try await checkProviderToggles(project: project, coding: library.coding)
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
