import AppKit
import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleCallRecording = Self("toggleCallRecording", initial: .init(.r, modifiers: [.control, .option, .command]))
}

/// Registers at app launch, independent of whether the menu or Settings has opened.
@MainActor final class RecordingShortcut: ObservableObject {
    let name: KeyboardShortcuts.Name
    @Published private(set) var label = ""
    @Published private(set) var issue: String?
    var onToggle: (() -> Void)?
    private var refreshTask: Task<Void, Never>?

    init(name: KeyboardShortcuts.Name = .toggleCallRecording) {
        self.name = name
        // Key-up produces one action per press, including when the key is held.
        KeyboardShortcuts.onKeyUp(for: name) { [weak self] in self?.onToggle?() }
        refresh()
    }

    func refresh() {
        let shortcut = KeyboardShortcuts.getShortcut(for: name)
        label = shortcut.map(String.init(describing:)) ?? "Disabled"
        issue = shortcut != nil && !KeyboardShortcuts.isEnabled(for: name)
            ? "This shortcut could not be registered. Another app may be using it. Choose a different shortcut in Settings."
            : nil
    }

    func refreshAfterEditing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            // The recorder resumes global shortcuts after leaving its editing field.
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func restoreDefault() {
        KeyboardShortcuts.reset(name)
        refreshAfterEditing()
    }

    func shutdown() {
        refreshTask?.cancel()
        KeyboardShortcuts.removeHandler(for: name)
    }
}

struct RecordingShortcutSettings: View {
    @ObservedObject var shortcut: RecordingShortcut
    var body: some View {
        Section("Keyboard shortcut") {
            KeyboardShortcuts.Recorder("Start / stop recording", name: shortcut.name) { _ in shortcut.refreshAfterEditing() }
            Text("Works in other apps while Afterword is running. Click the field and press your shortcut; clear it to disable. Holding the keys triggers only once, when released.")
                .font(.caption).foregroundStyle(.secondary)
            if let issue = shortcut.issue {
                Text(issue).font(.caption).foregroundStyle(.orange)
            }
            Button("Restore default shortcut") { shortcut.restoreDefault() }
                .controlSize(.small)
        }.onAppear { shortcut.refresh() }
    }
}

struct RecordingShortcutHint: View {
    @ObservedObject var shortcut: RecordingShortcut
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Start / stop shortcut: \(shortcut.label)")
                .foregroundStyle(.secondary)
            if let issue = shortcut.issue { Text(issue).foregroundStyle(.orange) }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
            .onAppear { shortcut.refresh() }
    }
}
