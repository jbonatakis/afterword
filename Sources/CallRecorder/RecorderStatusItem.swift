import AppKit
import Combine
import SwiftUI
import RecorderCore

/// Keep one native popover and one hosting controller alive as the content
/// changes. AppKit resizes this popover without dismissing/re-presenting it.
@MainActor final class RecorderStatusItem: NSObject, NSPopoverDelegate {
    private let recorder: RecordingCoordinator
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let hosting: NSHostingController<RecorderView>
    private var changes: AnyCancellable?
    private var previousSymbol = ""
    private var previousLabel = ""

    init(recorder: RecordingCoordinator, showLibrary: @escaping () -> Void) {
        self.recorder = recorder
        hosting = NSHostingController(rootView: RecorderView(recorder: recorder))
        super.init()
        hosting.rootView = RecorderView(recorder: recorder, showLibrary: { [weak self] in
            self?.popover.performClose(nil)
            showLibrary()
        })
        hosting.sizingOptions = [.preferredContentSize]
        popover.animates = false
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hosting
        item.autosaveName = "CallRecorderStatusItem"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageLeading
        refreshLabel()
        changes = recorder.objectWillChange.sink { [weak self] in
            // Published properties send before their new values are installed.
            DispatchQueue.main.async { self?.refreshLabel() }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else { showPopover() }
    }

    func showPopover() {
        guard !popover.isShown else { return }
        if let button = item.button {
            hosting.view.layoutSubtreeIfNeeded()
            popover.contentSize = hosting.sizeThatFits(in: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
        }
    }

    private func refreshLabel() {
        guard let button = item.button else { return }
        let symbol = recorder.state == .recording ? "record.circle.fill" : recorder.state == .previewing ? "waveform" : "waveform.circle"
        let label = recorder.state == .recording ? "Afterword, Recording, \(recorder.elapsed)" : "Afterword, \(recorder.title)"
        if previousSymbol != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            previousSymbol = symbol
        }
        if previousLabel != label {
            button.title = recorder.state == .recording ? recorder.elapsed : ""
            button.toolTip = label
            button.setAccessibilityLabel(label)
            previousLabel = label
        }
    }

    func popoverDidClose(_ notification: Notification) {
        recorder.panelClosed()
    }

    func shutdown() {
        changes?.cancel()
        popover.close()
        NSStatusBar.system.removeStatusItem(item)
    }
}
