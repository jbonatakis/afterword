import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI
import KeyboardShortcuts
import RecorderCore

/// Exercises the actual global registration and Settings control, with a fake
/// recording lifecycle. Never constructs an audio engine or captures audio.
@main struct ShortcutHarness {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await runChecks(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    @MainActor static func runChecks() async throws {
        let initial = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option, .command, .shift])
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--check-cleared" {
            let name = KeyboardShortcuts.Name(CommandLine.arguments[2], initial: initial)
            precondition(name.shortcut == nil, "Cleared shortcut returned after a fresh launch")
            print("PASS cleared shortcut persists across processes")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let previousApp = NSWorkspace.shared.frontmostApplication
        let rawName = "AfterwordShortcutCheck_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let name = KeyboardShortcuts.Name(rawName, initial: initial)
        let shortcut = RecordingShortcut(name: name)
        defer {
            shortcut.shutdown()
            UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_" + rawName)
            previousApp?.activate()
        }
        func pump(_ seconds: Double = 0.15) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        var lifecycle = Lifecycle(), events = 0, starts = 0, stops = 0
        shortcut.onToggle = {
            events += 1
            switch lifecycle.state.toggleAction {
            case .start: starts += 1; precondition(lifecycle.begin()); precondition(lifecycle.started(preview: false))
            case .stop: stops += 1; precondition(lifecycle.stop())
            case .none: break
            }
        }
        require(shortcut.issue == nil && KeyboardShortcuts.isEnabled(for: name), "Initial global registration failed")
        require(name.shortcut == initial, "Initial shortcut not stored")

        // A duplicate registration proves this key combination is reserved by
        // the app in the system hotkey registry, not just a local event monitor.
        var duplicate: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(initial.carbonKeyCode), UInt32(initial.carbonModifiers),
                                        EventHotKeyID(signature: 0x43525453, id: 1), GetApplicationEventTarget(), 0, &duplicate)
        if let duplicate { UnregisterEventHotKey(duplicate) }
        require(status != noErr, "Shortcut was not reserved globally")
        print("PASS default shortcut and global registration")

        guard CGPreflightPostEventAccess() else {
            print("SKIP key delivery/UI automation: keyboard event posting is not already authorized. No permission was requested.")
            return
        }
        func key(_ value: KeyboardShortcuts.Shortcut, down: Bool, repeatKey: Bool = false) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(value.carbonKeyCode), keyDown: down)!
            event.flags = CGEventFlags(rawValue: UInt64(value.modifiers.rawValue))
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
            event.post(tap: .cghidEventTap)
        }
        func press(_ value: KeyboardShortcuts.Shortcut) async { key(value, down: true); await pump(0.05); key(value, down: false); await pump() }
        require(NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                "Global key test must run while another app is focused")
        key(initial, down: true); await pump()
        for _ in 0..<8 { key(initial, down: true, repeatKey: true) }
        await pump(); require(events == 0, "Holding a key triggered recording before release")
        key(initial, down: false); await pump()
        require(events == 1 && starts == 1 && lifecycle.state == .recording, "First shortcut did not start once (events=\(events), starts=\(starts), state=\(lifecycle.state))")
        await press(initial)
        require(events == 2 && stops == 1 && lifecycle.state == .finalizing, "Second shortcut did not stop")
        await press(initial)
        require(events == 3 && starts == 1 && stops == 1 && lifecycle.state == .finalizing, "Shortcut acted during saving")
        lifecycle.finish()
        print("PASS background start/stop, held keys, and no action during saving")

        // Record a new combination through the same native control used by Settings.
        let replacement = KeyboardShortcuts.Shortcut(.t, modifiers: [.control, .option, .command, .shift])
        let field = KeyboardShortcuts.RecorderCocoa(for: name) { _ in shortcut.refreshAfterEditing() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        field.frame = NSRect(x: 35, y: 30, width: 250, height: 25)
        window.contentView!.addSubview(field)
        NSRunningApplication.current.activate()
        window.makeKeyAndOrderFront(nil); await pump(0.4)
        require(window.makeFirstResponder(field), "Shortcut field could not become first responder")
        await pump()
        print("Settings test active=\(app.isActive), keyWindow=\(window.isKeyWindow), editing=\(field.currentEditor() != nil)")
        let beforeEditing = events
        await press(replacement); await pump()
        require(name.shortcut == replacement, "Settings control did not store the recorded shortcut")
        require(events == beforeEditing, "Recording a shortcut triggered the action")
        shortcut.refresh()
        require(shortcut.issue == nil, "New shortcut did not register after editing")
        window.orderOut(nil); previousApp?.activate(); await pump()
        await press(initial); require(events == beforeEditing, "Old shortcut remained active after rebinding")
        await press(replacement); require(events == beforeEditing + 1, "New shortcut did not work globally")
        print("PASS Settings key capture, registration resumes, and old shortcut stops working")

        KeyboardShortcuts.setShortcut(nil, for: name); shortcut.refresh()
        let beforeClear = events
        await press(replacement)
        require(events == beforeClear && shortcut.label == "Disabled", "Clearing did not disable the shortcut")
        UserDefaults.standard.synchronize()
        let child = Process(); child.executableURL = Bundle.main.executableURL
        child.arguments = ["--check-cleared", rawName]
        try child.run(); child.waitUntilExit()
        require(child.terminationStatus == 0, "Persistence check failed")
        shortcut.restoreDefault(); await pump()
        require(name.shortcut == initial && shortcut.issue == nil, "Restore default failed")
        shortcut.shutdown()
        require(!KeyboardShortcuts.isEnabled(for: name), "Shutdown retained the hotkey")

        // A conflicting global key must be reported, not shown as working.
        var occupied: EventHotKeyRef?
        require(RegisterEventHotKey(UInt32(initial.carbonKeyCode), UInt32(initial.carbonModifiers),
                                   EventHotKeyID(signature: 0x43525453, id: 2), GetApplicationEventTarget(), 0, &occupied) == noErr,
                "Could not create conflict fixture")
        let conflicted = RecordingShortcut(name: name)
        require(conflicted.issue != nil, "Conflicting shortcut was silently accepted")
        conflicted.shutdown()
        if let occupied { UnregisterEventHotKey(occupied) }
        print("PASS clear, fresh-launch persistence, restore default, unregister, and conflict reporting")

        let renderedShortcut = RecordingShortcut(name: name)
        defer { renderedShortcut.shutdown() }
        let host = NSHostingView(rootView: Form { RecordingShortcutSettings(shortcut: renderedShortcut) }.formStyle(.grouped))
        host.frame = NSRect(x: 0, y: 0, width: 536, height: 270)
        let renderWindow = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        renderWindow.contentView = host; renderWindow.orderFront(nil); await pump()
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/hotkey-settings.png"))
        renderWindow.orderOut(nil)
        print("PASS Settings render; no recording engine or live audio used")
    }
}
