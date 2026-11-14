import AppKit
import SwiftUI
import AVFoundation
import Combine
import RecorderCore

/// Exercises actual window event routing with isolated preferences and silent
/// generated audio. Never opens user recordings or starts capture.
@main struct LibraryKeyboardHarness {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func pump(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func focusWindow(_ window: NSWindow) async {
            for _ in 0..<40 {
                NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                await pump(0.1)
                if NSApp.isActive && NSApp.keyWindow === window { return }
            }
            require(false, "Could not focus the target window for keyboard delivery")
        }
        func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false, window: NSWindow) async {
            require(NSApp.isActive && NSApp.keyWindow === window, "Keyboard target lost focus before key \(code)")
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: repeatKey, keyCode: code)!
            NSApp.sendEvent(event)
            if !repeatKey {
                NSApp.sendEvent(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-keys-" + UUID().uuidString)
        let folder = root.appendingPathComponent("Call-keyboard-fixture-" + UUID().uuidString)
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2)!
        let temporary = folder.appendingPathComponent("Silent.caf")
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000 * 40)!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(buffer.frameLength)) }
            try file.write(from: buffer)
        }
        try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent("Mixed.m4a"))
        let input = try TranscriptionInput.resolve(folder)
        let document = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "fixture", language: "en", segments: [
            .init(source: .mixed, start: 0, end: 20, text: "A transcript for keyboard editing and search.", timing: "segment")
        ])
        _ = try document.save(beside: input)
        UserDefaults.standard.set(root.path, forKey: "destination")
        UserDefaults.standard.set(true, forKey: "noticesAccepted")
        UserDefaults.standard.set(false, forKey: "KeyboardShortcuts_toggleCallRecording")
        let recorder = RecordingCoordinator(peopleURL: root.appendingPathComponent("People.json")); recorder.shortcut.shutdown()
        defer { recorder.transcription.shutdown() }
        let library = RecordingLibraryModel(recorder: recorder)
        await library.refresh()?.value
        let states = CurrentValueSubject<RecordingState, Never>(.idle)
        let playback = RecordingPlayback(states: states.eraseToAnyPublisher())
        defer { playback.shutdown() }
        let controller = RecordingLibraryWindow(library: library, recorder: recorder, playback: playback, showControls: {})
        let window = controller.window as! LibraryCommandWindow
        NSApp.mainMenu = NSMenu(title: "Main"); LibraryKeyboardMenus.install()
        controller.present()
        for _ in 0..<80 {
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows]); window.makeKeyAndOrderFront(nil)
            await pump(0.1)
            if NSApp.keyWindow === window { break }
        }
        require(NSApp.keyWindow === window, "Library did not become key (active: \(NSApp.isActive), visible: \(window.isVisible), can become key: \(window.canBecomeKey))")
        await pump()
        let tables = views(window.contentView!).compactMap { $0 as? NSTableView }
        guard let list = tables.first(where: { $0.numberOfRows == 1 }) else {
            print("Table rows:", tables.map(\.numberOfRows)); fatalError("Call list not found")
        }
        func focusList() async { await focusWindow(window); window.makeFirstResponder(list); await pump(0.1) }
        await focusList()
        require(window.canPerform(.trash), "Delete unavailable with call-list focus")
        let callMenu = NSApp.mainMenu!.item(withTitle: "Call")!.submenu!
        callMenu.update()
        require(callMenu.items.first { $0.tag == LibraryCommand.trash.rawValue }!.isEnabled, "Trash menu did not validate")

        LibraryKeyboardMenus.showHelp(); await pump()
        guard let helpWindow = NSApp.keyWindow, helpWindow !== window else { fatalError("Help did not open its reference window") }
        require(!window.canPerform(.trash) && !window.canPerform(.playPause), "Library shortcuts leaked into Help")
        let helpView = helpWindow.contentView!
        helpView.layoutSubtreeIfNeeded()
        let bitmap = helpView.bitmapImageRepForCachingDisplay(in: helpView.bounds)!
        helpView.cacheDisplay(in: helpView.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/keyboard-help.png"))
        helpWindow.close(); window.makeKeyAndOrderFront(nil); await focusList()

        await key("r", code: 15, window: window); await pump()
        require(library.renamingID == library.selection, "R did not begin inline rename")
        guard let titleEditor = window.firstResponder as? NSTextView else { fatalError("Rename field did not get keyboard focus") }
        require(titleEditor.isEditable && !window.canPerform(.trash) && !window.canPerform(.playPause), "Title input leaked shortcuts")
        titleEditor.selectAll(nil); titleEditor.insertText("Renamed r e call", replacementRange: titleEditor.selectedRange())
        await key("\r", code: 36, window: window); await pump(0.7)
        require(library.selectedRecording?.name == "Renamed r e call" && library.renamingID == nil, "Return did not save rename")
        require(NSApp.isActive && NSApp.keyWindow === window && window.firstResponder === list, "Return lost library/list focus")
        await key("r", code: 15, window: window); await pump()
        await key("\u{1b}", code: 53, window: window); await pump()
        require(library.renamingID == nil, "Escape did not cancel rename")
        require(NSApp.isActive && NSApp.keyWindow === window && window.firstResponder === list,
                "Escape lost library/list focus (active: \(NSApp.isActive), key: \(NSApp.keyWindow === window), visible: \(window.isVisible), responder: \(String(describing: window.firstResponder)))")
        await key("r", code: 15, window: window); await pump()
        require(library.renamingID == library.selection, "R stopped working after Escape")
        await key("\u{1b}", code: 53, window: window); await pump()
        require(NSApp.isActive && NSApp.keyWindow === window && window.firstResponder === list, "Repeated rename/cancel lost focus")
        print("PASS R, typing protection, Return save, and repeated Escape cancellation with focus preserved")

        let originalRecording = library.selectedRecording!
        let originalTranscript = try Data(contentsOf: originalRecording.transcripts[0].url)
        await key("e", code: 14, window: window); await pump()
        require(library.transcriptDrafts[originalRecording.id]?.changed == false, "E did not open a clean draft")
        await key("\u{1b}", code: 53, window: window); await pump()
        require(library.transcriptDrafts[originalRecording.id] == nil && window.attachedSheet == nil, "Escape did not exit an unchanged transcript")
        require(NSApp.isActive && NSApp.keyWindow === window && window.firstResponder === list, "Exiting transcript editing lost list focus")
        await key("e", code: 14, window: window); await pump()
        guard let unsavedEditor = window.firstResponder as? NSTextView else { fatalError("Transcript did not regain edit focus") }
        unsavedEditor.selectAll(nil); unsavedEditor.insertText("Unsaved correction", replacementRange: unsavedEditor.selectedRange()); await pump()
        await key("\u{1b}", code: 53, window: window); await pump()
        require(window.attachedSheet != nil && library.transcriptDrafts[originalRecording.id]?.text == ["Unsaved correction"], "Escape discarded edits without confirmation")
        await key("\u{1b}", code: 53, window: window.attachedSheet!); await pump()
        require(window.attachedSheet == nil && library.transcriptDrafts[originalRecording.id]?.text == ["Unsaved correction"], "Escape in discard confirmation did not keep the draft")
        await key("\u{1b}", code: 53, window: window); await pump()
        require(window.attachedSheet != nil, "Escape could not reopen discard confirmation")
        await key("\r", code: 36, window: window.attachedSheet!); await pump()
        require(library.transcriptDrafts[originalRecording.id] == nil, "Return did not confirm discarding the draft")
        require(NSApp.isActive && NSApp.keyWindow === window && window.firstResponder === list, "Discarding transcript edits lost list focus")
        let savedTranscript = try Data(contentsOf: originalRecording.transcripts[0].url)
        require(savedTranscript == originalTranscript && library.selectedRecording?.transcripts.count == 1, "Cancelling changed a saved transcript")
        print("PASS transcript Escape, unsaved-change confirmation, keep/discard, and focus without reactivation")

        await key("f", code: 3, flags: .command, window: window); await pump()
        require((window.firstResponder as? NSTextView)?.isEditable == true, "Command-F did not focus search (key: \(NSApp.keyWindow === window), available: \(window.canPerform(.search)), responder: \(String(describing: window.firstResponder)))")
        require(!window.canPerform(.rename) && !window.canPerform(.trash) && !window.canPerform(.playPause) && !window.canPerform(.backward), "Search input leaked shortcuts")
        await key("r", code: 15, window: window)
        await key(" ", code: 49, window: window)
        await key("e", code: 14, window: window); await pump()
        require(library.search == "r e", "Search did not accept shortcut letters")
        await key("\u{7f}", code: 51, window: window); await pump()
        require(library.search == "r " && window.attachedSheet == nil, "Backspace in search opened Trash or failed to edit")
        library.search = ""; await pump(); await focusList()
        await key(" ", code: 49, window: window); await pump()
        require(playback.playing, "Space did not start silent playback")
        await key(" ", code: 49, window: window); await pump()
        require(!playback.playing, "Space did not pause playback")
        playback.seek(15)
        await key(LibraryCommand.backward.key, code: 123, flags: .option, window: window)
        require(abs(playback.position - 5) < 0.01, "Option-left did not seek back 10 seconds")
        await key(LibraryCommand.forward.key, code: 124, flags: .option, window: window)
        require(abs(playback.position - 15) < 0.01, "Option-right did not seek forward 10 seconds")
        states.send(.recording); await key(" ", code: 49, window: window)
        require(!playback.playing, "Playback bypassed active-capture protection")
        states.send(.idle)
        print("PASS search focus, text deletion, play/pause, seek, and capture priority")

        await key("e", code: 14, window: window); await pump()
        let recording = library.selectedRecording!
        guard let draft = library.transcriptDrafts[recording.id], let editor = window.firstResponder as? NSTextView else { fatalError("E did not focus transcript editing") }
        require(editor.isEditable && !window.canPerform(.trash) && !window.canPerform(.editTranscript), "Transcript editor leaked shortcuts")
        editor.selectAll(nil); editor.insertText("Corrected transcript", replacementRange: editor.selectedRange()); await pump()
        require(draft.changed && window.canPerform(.save), "Transcript save unavailable (key: \(NSApp.keyWindow === window), text: \(draft.text))")
        await key("s", code: 1, flags: .command, window: window)
        for _ in 0..<40 { await pump(0.1); if library.transcriptDrafts[recording.id] == nil { break } }
        require(library.transcriptDrafts[recording.id] == nil && library.selectedRecording?.transcripts.count == 2,
                "Command-S did not save a transcript version (key: \(NSApp.keyWindow === window), saving: \(draft.saving), error: \(draft.error ?? "none"), versions: \(library.selectedRecording?.transcripts.count ?? -1))")
        require(draft.text == ["Corrected transcript"], "Editor contents were not saved")
        require(NSApp.isActive && NSApp.keyWindow === window && window.firstResponder === list, "Saving transcript edits lost list focus")
        await focusList()
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        await key("c", code: 8, flags: [.command, .shift], window: window)
        let copied = pasteboard.string(forType: .string)
        pasteboard.clearContents(); pasteboard.writeObjects(previousItems)
        require(copied?.contains("Corrected transcript") == true, "Copy shortcut ignored the displayed version")
        print("PASS transcript edit focus, Command-S, version creation, and readable copy")

        await key("i", code: 34, flags: .command, window: window); await pump()
        require(window.attachedSheet != nil, "Command-I did not open details")
        require(!window.canPerform(.trash) && !window.canPerform(.playPause) && !window.canPerform(.save), "Commands leaked into details sheet")
        await key("\u{1b}", code: 53, window: window.attachedSheet!); await pump()
        require(window.attachedSheet == nil, "Escape did not dismiss details")
        if let sidebar = tables.first(where: { $0 !== list }) {
            window.makeFirstResponder(sidebar); await pump()
            require(!window.canPerform(.trash), "Delete was enabled in the sidebar")
        }
        await focusList(); await key("\u{7f}", code: 51, window: window); await pump()
        require(window.attachedSheet != nil && FileManager.default.fileExists(atPath: folder.path), "Delete did not ask before trashing")
        await key("\u{1b}", code: 53, window: window.attachedSheet!); await pump()
        require(window.attachedSheet == nil && FileManager.default.fileExists(atPath: folder.path), "Escape did not cancel Trash")
        await focusList(); await key("\u{f728}", code: 117, window: window); await pump()
        require(window.attachedSheet != nil, "Forward Delete did not open confirmation")
        await key("\r", code: 36, window: window.attachedSheet!); await pump(1)
        require(!FileManager.default.fileExists(atPath: folder.path) && library.selectedRecording == nil, "Return did not confirm Trash")
        // Only the uniquely named generated fixture can be removed here.
        let trashedFixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").appendingPathComponent(folder.lastPathComponent)
        try? FileManager.default.removeItem(at: trashedFixture)
        print("PASS details modal, list-only deletion, Escape cancellation, and Return-confirmed fixture Trash")
        controller.close()
        require(!window.canPerform(.rename) && !window.canPerform(.playPause), "Closed window retained shortcuts")
        print("PASS keyboard integration; no live capture or user recording changes")
    }
}
