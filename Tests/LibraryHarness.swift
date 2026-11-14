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
        UserDefaults.standard.removePersistentDomain(forName: name)
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
        require(library.visibleRecordings.count == 1, "Tag search failed")
        library.search = "Alex"
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
        library.assignParticipant("Sam", to: 0, recording: named, version: originalVersion)
        require(library.transcriptDrafts[recording.id]?.participants[0] == nil, "Participant assignment changed the microphone speaker")
        library.assignParticipant("Sam", to: 1, recording: named, version: originalVersion)
        require(library.transcriptDrafts[recording.id]?.participants[1] == "Sam", "Speaker menu selection did not update the draft")
        require(library.hasUnsavedEdits, "Inline changes were not tracked as unsaved")
        library.selection = nil; library.search = "no matching call"; await library.refresh()?.value
        require(library.transcriptDrafts[recording.id]?.text == corrected, "Navigating or refreshing lost inline edits")
        library.search = ""; library.selection = recording.id
        await library.saveTranscriptDraft(for: recording)
        for _ in 0..<50 { if !library.refreshing { break }; await pump(0.05) }
        require(library.selectedRecording?.transcripts.count == 2, "Editing did not create a version")
        require(library.transcriptDrafts[recording.id] == nil && !library.hasUnsavedEdits, "Successful save left a dirty draft")
        require(library.preferredTranscriptID != nil, "Edited version was not selected")
        require(library.selectedRecording?.transcripts.contains { $0.document?.editing != nil } == true, "Edited version lacks its origin")
        let namedDocument = library.recordings[0].transcripts.first { $0.document?.editing != nil }!.document!
        require(namedDocument.automaticParticipant == "Alex" && namedDocument.paragraphs[1].participant == "Sam", "Saved transcript lost the frozen automatic name or manual assignment")
        require(namedDocument.readableText.contains("Sam · 00:00:18"), "Readable transcript omitted assigned names")
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

        let updated = library.recordings[0]
        library.beginTranscriptEditing(updated, version: updated.transcripts[0], paragraph: 1)
        library.transcriptDrafts[updated.id]?.text[1] += " This correction is still a draft."
        for (view, width, height, suffix) in [
            (AnyView(CallDetailsEditor(recording: updated, library: library)), 578.0, 430.0, "call-details"),
            (AnyView(RecordingLibraryView(library: library, recorder: recorder, playback: playback, showControls: {})), 1180.0, 740.0, "transcript-inline")
        ] {
            let host = NSHostingView(rootView: view.preferredColorScheme(.light))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua); host.appearance = window.appearance
            window.contentView = host; window.orderFront(nil); await pump(0.3)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            window.appearance!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/\(suffix).png"))
            window.orderOut(nil)
        }
        library.cancelTranscriptEditing(updated)
        require(!library.hasUnsavedEdits && library.recordings[0].transcripts.count == 2, "Cancelling an inline draft wrote a transcript")
        print("PASS inline rename, draft navigation/save/cancel, and inline transcript rendering")

        let renameView = NSHostingView(rootView: RecordingLibraryView(library: library, recorder: recorder, playback: playback, showControls: {}).preferredColorScheme(.light))
        let renameWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 940, height: 660), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        renameWindow.appearance = NSAppearance(named: .aqua); renameView.appearance = renameWindow.appearance
        renameWindow.contentView = renameView; renameWindow.makeKeyAndOrderFront(nil); await pump()
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

        var stressSegments: [TranscriptSegment] = []
        for index in 0..<80 {
            let source: TranscriptSource = index.isMultiple(of: 2) ? .microphone : .system
            let text = "Passage \(index). " + String(repeating: "A longer paragraph exercises wrapping and selection. ", count: index % 10 + 1)
            stressSegments.append(TranscriptSegment(source: source, start: Double(index), end: Double(index + 1), text: text, timing: "segment"))
        }
        let stressParagraphs = TranscriptParagraph.make(from: stressSegments)
        func reader(_ query: String) -> ReadableTranscript {
            ReadableTranscript(paragraphs: stressParagraphs, edited: false, query: query, playback: playback, playbackDisabled: false,
                               draft: nil, canEdit: false, editParagraph: { _ in }, participants: ["Alex", "Sam"], automaticParticipant: "Alex",
                               assignParticipant: { _, _ in }, editParticipants: {})
        }
        let stressHost = NSHostingView(rootView: reader(""))
        let stressWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        stressWindow.contentView = stressHost; stressWindow.orderFront(nil); playback.play()
        for index in 0..<20 {
            stressWindow.setContentSize(NSSize(width: index.isMultiple(of: 2) ? 420 : 700, height: 500))
            stressHost.rootView = reader("Passage \(index * 3).")
            playback.seek(Double(index * 3))
            playback.changeTrack(index.isMultiple(of: 2) ? .microphone : .system, in: updated)
            await pump(0.06)
        }
        playback.pause(); stressWindow.orderOut(nil)
        print("PASS 80-paragraph reader resize/search/playback stress check")

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
        try await library.moveToTrash(updated, version: updated.transcripts[0], playback: playback, trash: move)
        for _ in 0..<50 { if !library.refreshing { break }; await pump(0.05) }
        require(library.recordings.first?.transcripts.count == 1, "Version deletion failed to refresh the library")
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
}
