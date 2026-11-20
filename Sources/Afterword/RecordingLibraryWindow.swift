import AppKit
import SwiftUI

/// Keep the main window and its hosting controller alive independently of scene
/// restoration. SwiftUI supplies the content, sidebar, search, and toolbar.
@MainActor final class RecordingLibraryWindow: NSWindowController, NSWindowDelegate {
    private let library: RecordingLibraryModel
    private let playback: RecordingPlayback

    init(library: RecordingLibraryModel, recorder: RecordingCoordinator, playback: RecordingPlayback, showControls: @escaping () -> Void) {
        self.library = library; self.playback = playback
        let window = LibraryCommandWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Afterword"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 940, height: 660)
        window.tabbingMode = .disallowed
        window.contentViewController = NSHostingController(rootView: RecordingLibraryView(
            library: library, recorder: recorder, playback: playback, showControls: showControls))
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("RecordingLibraryWindow")
        if !window.setFrameUsingName("RecordingLibraryWindow") { window.center() }
    }
    required init?(coder: NSCoder) { fatalError("Use init(library:recorder:playback:showControls:)") }

    func present() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        library.refreshOnOpen()
    }
    func windowWillClose(_ notification: Notification) { playback.pause() }
}
