import AppKit
import SwiftUI

enum LibraryCommand: Int, CaseIterable {
    case rename, trash, details, editTranscript, save, copyTranscript, search, playPause, backward, forward

    var title: String {
        switch self {
        case .rename: return "Rename Call"
        case .trash: return "Move Call to Trash…"
        case .details: return "Edit Call Details…"
        case .editTranscript: return "Edit Transcript"
        case .save: return "Save Edits"
        case .copyTranscript: return "Copy Readable Transcript"
        case .search: return "Search Library"
        case .playPause: return "Play / Pause"
        case .backward: return "Back 10 Seconds"
        case .forward: return "Forward 10 Seconds"
        }
    }
    var key: String {
        switch self {
        case .rename: return "r"
        case .trash: return "\u{8}"
        case .details: return "i"
        case .editTranscript: return "e"
        case .save: return "s"
        case .copyTranscript: return "c"
        case .search: return "f"
        case .playPause: return " "
        case .backward: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .forward: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        }
    }
    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .details, .save, .search: return .command
        case .copyTranscript: return [.command, .shift]
        case .backward, .forward: return .option
        default: return []
        }
    }
    var hint: String {
        switch self {
        case .rename: return "R"
        case .trash: return "Delete / Backspace"
        case .details: return "⌘I"
        case .editTranscript: return "E"
        case .save: return "⌘S"
        case .copyTranscript: return "⌘⇧C"
        case .search: return "⌘F"
        case .playPause: return "Space"
        case .backward: return "⌥←"
        case .forward: return "⌥→"
        }
    }
    static func matching(_ event: NSEvent) -> Self? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if modifiers.isEmpty, [51, 117].contains(event.keyCode) { return .trash }
        return allCases.first { $0.modifiers == modifiers && $0.key == event.charactersIgnoringModifiers?.lowercased() }
    }
}

struct LibraryCommandBinding {
    var enabled: () -> Bool
    var perform: () -> Void
}

/// The bindings stay with the rendered view, including its selected transcript
/// version. AppKit asks for availability at the moment a key/menu is used.
struct LibraryCommandScope: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var bindings: [LibraryCommand: LibraryCommandBinding]
    var cancelEditing: LibraryCommandBinding? = nil
    func makeNSView(context: Context) -> LibraryCommandView { LibraryCommandView() }
    func updateNSView(_ view: LibraryCommandView, context: Context) {
        view.bindings = isEnabled ? bindings : [:]
        view.cancelEditing = isEnabled ? cancelEditing : nil
    }
}

final class LibraryCommandView: NSView {
    var bindings: [LibraryCommand: LibraryCommandBinding] = [:]
    var cancelEditing: LibraryCommandBinding?
}

@MainActor final class LibraryCommandWindow: NSWindow {
    private var handledKeys: Set<UInt16> = []

    private var editingText: Bool {
        if let text = firstResponder as? NSTextView { return text.isEditable }
        if let field = firstResponder as? NSTextField { return field.isEditable }
        return false
    }
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private func binding(for command: LibraryCommand) -> LibraryCommandBinding? {
        guard let contentView else { return nil }
        return descendants(contentView).compactMap { ($0 as? LibraryCommandView)?.bindings[command] }.first
    }
    private var searchField: NSSearchField? {
        for item in toolbar?.items ?? [] {
            if let search = item as? NSSearchToolbarItem { return search.searchField }
            if let view = item.view, let field = descendants(view).compactMap({ $0 as? NSSearchField }).first { return field }
        }
        return contentView.flatMap { descendants($0).compactMap { $0 as? NSSearchField }.first }
    }
    func canPerform(_ command: LibraryCommand) -> Bool {
        guard NSApp.keyWindow === self, attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        if command == .search { return searchField != nil }
        if command != .save && editingText { return false }
        // Space should still activate a keyboard-focused native control.
        if command == .playPause, let control = firstResponder as? NSControl, !(control is NSTableView) { return false }
        return binding(for: command)?.enabled() == true
    }
    @discardableResult func perform(_ command: LibraryCommand) -> Bool {
        guard canPerform(command) else { return false }
        if command == .search {
            if let item = toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first { item.beginSearchInteraction() }
            if let field = searchField { makeFirstResponder(field); field.selectText(nil) }
        } else { binding(for: command)?.perform() }
        return true
    }
    @objc func runLibraryCommand(_ sender: NSMenuItem) {
        if let command = LibraryCommand(rawValue: sender.tag) { perform(command) }
    }
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(runLibraryCommand(_:)), let command = LibraryCommand(rawValue: item.tag) else { return super.validateMenuItem(item) }
        return canPerform(command)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.isARepeat && handledKeys.contains(event.keyCode) { return true }
        if cancelEditing(with: event) { return true }
        if let command = LibraryCommand.matching(event), canPerform(command) {
            if !event.isARepeat { perform(command); handledKeys.insert(event.keyCode) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyUp { handledKeys.remove(event.keyCode) }
        if event.type == .keyDown {
            if event.isARepeat && handledKeys.contains(event.keyCode) { return }
            if cancelEditing(with: event) { return }
            if let command = LibraryCommand.matching(event), canPerform(command) {
                if !event.isARepeat { perform(command); handledKeys.insert(event.keyCode) }
                return
            }
        }
        super.sendEvent(event)
    }
    private func cancelEditing(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty,
              NSApp.keyWindow === self, attachedSheet == nil, NSApp.modalWindow == nil,
              (firstResponder as? NSTextView)?.hasMarkedText() != true, let contentView,
              let action = descendants(contentView).compactMap({ ($0 as? LibraryCommandView)?.cancelEditing }).first(where: { $0.enabled() }) else { return false }
        if let searchField, firstResponder === searchField || firstResponder === searchField.currentEditor() { return false }
        // Consume this Escape before removing the field editor so it cannot
        // continue through AppKit's window-level cancellation handling.
        if !event.isARepeat { action.perform(); handledKeys.insert(event.keyCode) }
        return true
    }
    override func resignKey() { handledKeys.removeAll(); super.resignKey() }
}

@MainActor enum LibraryKeyboardMenus {
    static func install(recordings: Bool = true) {
        guard let main = NSApp.mainMenu else { return }
        for (title, commands) in [("Call", [LibraryCommand.rename, .trash, .details, .editTranscript, .save, .copyTranscript, .search]),
                                   ("Playback", [.playPause, .backward, .forward])] {
            if let existing = main.item(withTitle: title) { existing.isHidden = !recordings; continue }
            guard recordings else { continue }
            let menu = NSMenu(title: title)
            for command in commands {
                let item = NSMenuItem(title: command.title, action: #selector(LibraryCommandWindow.runLibraryCommand(_:)), keyEquivalent: command.key)
                item.keyEquivalentModifierMask = command.modifiers; item.tag = command.rawValue
                menu.addItem(item)
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = menu
            let index = main.items.firstIndex { ["Window", "Help"].contains($0.title) } ?? main.items.count
            main.insertItem(item, at: index)
        }
    }
    static func showHelp(recordings: Bool = true) { LibraryKeyboardHelp.shared.showShortcuts(recordings: recordings) }
}

@MainActor private final class LibraryKeyboardHelp: NSWindowController {
    static let shared = LibraryKeyboardHelp()
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 580), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: LibraryKeyboardHelpView())
        super.init(window: window); window.center()
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    func showShortcuts(recordings: Bool) {
        window?.contentViewController = NSHostingController(rootView: LibraryKeyboardHelpView(recordings: recordings))
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
}

struct LibraryKeyboardHelpView: View {
    var recordings = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 10) {
                ForEach(recordings ? LibraryCommand.allCases : [.search], id: \.rawValue) { command in
                    GridRow { Text(command.title); Text(command.hint).foregroundStyle(.secondary) }
                }
                Divider()
                GridRow { Text("Show Library"); Text("⌘1").foregroundStyle(.secondary) }
                if recordings { GridRow { Text("Upcoming Calls"); Text("⌘2").foregroundStyle(.secondary) } }
                GridRow { Text("Confirm / Cancel dialog"); Text("Return / Escape").foregroundStyle(.secondary) }
                if recordings { GridRow { Text("Exit rename or transcript editing"); Text("Escape").foregroundStyle(.secondary) } }
            }.font(.callout)
            if recordings {
                Text("Delete requires focus in the call list and asks for confirmation. Letter and playback shortcuts stay inactive while typing or using a dialog.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Escape returns to the call list. Unsaved transcript edits require confirmation before discarding.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Your global start/stop recording shortcut is configured in Settings → Recording.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(width: 500)
    }
}
