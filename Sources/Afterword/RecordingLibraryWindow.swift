import AppKit
import Combine
import SwiftUI

/// Keep the main window and its hosting controller alive independently of scene
/// restoration. SwiftUI supplies the content, sidebar, search, and toolbar.
@MainActor final class RecordingLibraryWindow: NSWindowController, NSWindowDelegate {
    private let library: RecordingLibraryModel
    private let playback: RecordingPlayback

    private struct ScrollPosition {
        weak var view: NSScrollView?
        let bounds: NSRect
    }
    private var positions: [ScrollPosition] = []
    private var savedWindowSize: NSSize = .zero
    private var savedDestination: LibraryDestination?
    private var savedItem: String?
    private var layoutObservation: AnyCancellable?
    private var pageObservation: AnyCancellable?

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
        pageObservation = library.$calendarPage.dropFirst().sink { [weak self] next in
            guard let self else { return }
            if next == nil, !positions.isEmpty {
                // A background window need not receive windowDidUpdate. A clip still reports
                // its new bounds when SwiftUI lays the activity columns back out.
                let clips = positions.compactMap { $0.view?.contentView }
                layoutObservation = Publishers.MergeMany(clips.map {
                    NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: $0)
                })
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.restoreActivityPosition() }
                DispatchQueue.main.async { [weak self] in self?.restoreActivityPosition() }
            } else if next != nil, library.calendarPage == nil, let content = window.contentView {
                layoutObservation = nil
                savedDestination = library.destination
                savedItem = library.selection
                savedWindowSize = window.frame.size
                positions = Self.scrollPositions(in: content)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(library:recorder:playback:showControls:)") }

    private static func scrollPositions(in view: NSView) -> [ScrollPosition] {
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           document.bounds.height > scroll.contentView.bounds.height {
            scroll.contentView.postsBoundsChangedNotifications = true
            return [ScrollPosition(view: scroll, bounds: scroll.contentView.bounds)]
        }
        return view.subviews.flatMap(scrollPositions)
    }

    // Switching toolbars can temporarily resize both activity columns. Restore each clip
    // after the library is visible and AppKit has given it its reading dimensions again.
    private func restoreActivityPosition() {
        guard !positions.isEmpty, library.calendarPage == nil, let window else { return }
        guard library.destination == savedDestination, library.selection == savedItem else {
            positions = []; layoutObservation = nil
            return
        }
        positions.removeAll { position in
            guard let scroll = position.view, scroll.window === window else { return true }
            let clip = scroll.contentView
            guard savedWindowSize != window.frame.size || position.bounds.size == clip.bounds.size else { return false }
            var bounds = clip.bounds
            bounds.origin = position.bounds.origin
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
            return true
        }
        if positions.isEmpty { layoutObservation = nil }
    }

    func present() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        library.refreshOnOpen()
    }
    func windowWillClose(_ notification: Notification) { playback.pause() }
}
