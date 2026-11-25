import AppKit
import Combine
import SwiftUI

/// Keep the main window and its hosting controller alive independently of scene
/// restoration. SwiftUI supplies the content, sidebar, search, and toolbar.
@MainActor final class RecordingLibraryWindow: NSWindowController, NSWindowDelegate {
    private let library: RecordingLibraryModel
    private let playback: RecordingPlayback

    private struct MessageAnchor {
        let id: String
        let offsetFromTop: CGFloat
        let reveal: () -> Void
    }
    private struct ScrollPosition {
        weak var view: NSScrollView?
        let bounds: NSRect
        let messages: [MessageAnchor]
        var requestedReveal = false
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
        pageObservation = library.$page.dropFirst().sink { [weak self] next in
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
            } else if next != nil, library.page == nil, let content = window.contentView {
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
            let viewport = scroll.documentVisibleRect
            let messages = messageMarkers(in: document).compactMap { marker -> MessageAnchor? in
                let frame = marker.convert(marker.bounds, to: document)
                guard frame.intersects(viewport) else { return nil }
                return MessageAnchor(id: marker.messageID, offsetFromTop: frame.minY - viewport.minY, reveal: marker.reveal)
            }.sorted { abs($0.offsetFromTop) < abs($1.offsetFromTop) }
            return [ScrollPosition(view: scroll, bounds: scroll.contentView.bounds, messages: messages)]
        }
        return view.subviews.flatMap(scrollPositions)
    }

    private static func messageMarkers(in view: NSView) -> [ConversationRowMarker.MarkerView] {
        if let marker = view as? ConversationRowMarker.MarkerView { return [marker] }
        return view.subviews.flatMap(messageMarkers)
    }

    // Switching toolbars can temporarily resize both activity columns. Restore each clip
    // after the library is visible and AppKit has given it its reading dimensions again.
    private func restoreActivityPosition() {
        guard !positions.isEmpty, library.page == nil, let window else { return }
        guard library.destination == savedDestination, library.selection == savedItem else {
            positions = []; layoutObservation = nil
            return
        }
        positions = positions.compactMap { position in
            guard let scroll = position.view, scroll.window === window else { return nil }
            let clip = scroll.contentView
            guard savedWindowSize != window.frame.size || position.bounds.size == clip.bounds.size else { return position }
            var bounds = clip.bounds
            bounds.origin = position.bounds.origin
            if let document = scroll.documentView, let first = position.messages.first {
                document.layoutSubtreeIfNeeded()
                let markers = Self.messageMarkers(in: document)
                // Lazy rows can be remeasured while the calendar is showing. Restore a
                // message's screen position even when its document coordinate changed.
                let anchorY = position.messages.lazy.compactMap { saved -> CGFloat? in
                    guard let marker = markers.first(where: { $0.messageID == saved.id }) else { return nil }
                    return marker.convert(marker.bounds, to: document).minY - saved.offsetFromTop
                }.first
                if let anchorY {
                    bounds.origin.y = anchorY
                } else if !position.requestedReveal {
                    // The lazy stack may have recycled every saved row. Try to reveal one
                    // once. A deleted message falls back to the original scroll offset.
                    var pending = position
                    pending.requestedReveal = true
                    first.reveal()
                    DispatchQueue.main.async { [weak self] in self?.restoreActivityPosition() }
                    return pending
                }
            }
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
            return nil
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
