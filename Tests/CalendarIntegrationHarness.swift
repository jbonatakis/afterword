import AppKit
import SwiftUI
import AVFoundation
@testable import RecorderCore

actor FixtureCalendarReader: CalendarReading {
    var meetings: [CalendarMeeting]
    init(_ meetings: [CalendarMeeting]) { self.meetings = meetings }
    func requestAccess() async throws -> Bool { true }
    func read(selected: Set<String>, now: Date) -> ([AvailableCalendar], [CalendarMeeting]) {
        ([.init(id: "fixture", title: "Work", source: "Fixture")], selected.contains("fixture") ? meetings : [])
    }
    func replace(_ meetings: [CalendarMeeting]) { self.meetings = meetings }
}

@main struct CalendarIntegrationHarness {
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw RecorderError.message(message) }
        }
        func pump() async { try? await Task.sleep(nanoseconds: 200_000_000) }
        UserDefaults.standard.set(root.path, forKey: "destination")
        UserDefaults.standard.set(true, forKey: "noticesAccepted")
        UserDefaults.standard.set(false, forKey: "KeyboardShortcuts_toggleCallRecording")
        let recorder = RecordingCoordinator(peopleURL: root.appendingPathComponent("People.json")); recorder.shortcut.shutdown()
        defer { recorder.transcription.shutdown() }
        let now = Date(), url = URL(string: "https://meet.google.com/abc-defg-hij")!
        let call = CalendarMeeting(reference: .init(occurrenceID: "one", title: "Avery / Casey", start: now.addingTimeInterval(45), end: now.addingTimeInterval(1845), calendar: "Work", joinURL: url),
                                   guests: [.init(email: "casey@example.com", isSelf: true), .init(email: "avery@example.com", name: "avery@example.com")])
        let groupCall = CalendarMeeting(reference: .init(occurrenceID: "two", title: "Group planning", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400), calendar: "Work", joinURL: url),
                                        guests: [.init(email: "casey@example.com", isSelf: true), .init(email: "avery@example.com"), .init(email: "studio@example.com", name: "Studio")])
        let reader = FixtureCalendarReader([call, groupCall])
        let calendar = CalendarCoordinator(recorder: recorder, directoryURL: root.appendingPathComponent("People.json"), reader: reader, hasAccess: { true })
        defer { calendar.shutdown() }
        calendar.select("fixture", enabled: true); calendar.setEnabled(true); await calendar.refresh()?.value
        try require(calendar.meetings.count == 2 && calendar.canStart, "Calendar load or self exclusion failed")
        var avery = calendar.directory.identity(email: "avery@example.com")!; avery.name = "Avery Willow"; try calendar.updateIdentity(avery)
        var group = calendar.directory.identity(email: "studio@example.com")!; group.kind = .group; group.memberIDs = [avery.id]; try calendar.updateIdentity(group)
        await calendar.refresh()?.value
        try require(calendar.preview(call).inferredParticipant == "Avery Willow", "Preferred name did not reach the meeting preview")
        try require(calendar.preview(groupCall).inferredParticipant == nil && calendar.preview(groupCall).participants == ["Avery Willow"], "Group became a speaker or allowed inference")
        calendar.startMonitoring(); await calendar.refresh()?.value; await pump()
        try require(calendar.reminder?.id == call.id, "Due reminder was not shown")
        try require(NSApp.windows.contains { $0.title == "Upcoming Call" && $0.isVisible }, "Native reminder panel is not visible")
        print("PASS fake calendar fetch, self email learning, preferred name, remembered group, and visible native reminder")
        try await render(CalendarReminderView(calendar: calendar), size: NSSize(width: 450, height: 365), name: "reminder")
        try await render(UpcomingMeetingsView(calendar: calendar), size: NSSize(width: 680, height: 590), name: "upcoming")
        try await render(CalendarSettings(calendar: calendar), size: NSSize(width: 560, height: 640), name: "settings")
        try await render(PeopleDirectoryView(calendar: calendar), size: NSSize(width: 700, height: 560), name: "people")
        calendar.dismissReminder(snooze: true); calendar.checkReminder(now: now.addingTimeInterval(10))
        try require(calendar.reminder == nil, "Snooze did not delay the prompt")
        calendar.checkReminder(now: Date().addingTimeInterval(61))
        try require(calendar.reminder?.id == call.id, "Snoozed prompt did not return")
        calendar.dismissReminder()
        calendar.checkReminder(now: Date().addingTimeInterval(62))
        try require(calendar.reminder == nil, "Dismissed prompt repeated")
        await reader.replace([])
        await calendar.startMeeting(call, join: false)
        try require(recorder.state == .idle && calendar.error != nil, "Stale event started recording")
        let declined = CalendarMeeting(reference: call.reference, guests: [.init(email: "casey@example.com", declined: true), .init(email: "avery@example.com")])
        await reader.replace([declined]); await calendar.refresh()?.value
        try require(calendar.meetings.isEmpty, "Declined meeting remained eligible through a shared-calendar alias")
        print("PASS reminder snooze/dismiss, stale-event start rejection, and declined-self filtering; capture was never started")

        let folder = root.appendingPathComponent("Call-fixture"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent("fixture.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!; buffer.frameLength = 1600
            buffer.floatChannelData![0].initialize(repeating: 0, count: 1600); try file.write(from: buffer)
        }
        try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent("Mixed.m4a"))
        let input = TranscriptionInput(tracks: [.init(source: .system, url: folder.appendingPathComponent("System.m4a")), .init(source: .microphone, url: folder.appendingPathComponent("Microphone.m4a"))], outputDirectory: folder, name: "Call-fixture")
        let document = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "fixture", language: "en", segments: [
            .init(source: .system, start: 0, end: 1, text: "First answer.", timing: "segment"),
            .init(source: .microphone, start: 2, end: 3, text: "A question.", timing: "segment"),
            .init(source: .system, start: 4, end: 5, text: "Second answer.", timing: "segment")])
        _ = try document.save(beside: input)
        let library = RecordingLibraryModel(recorder: recorder); await library.refresh()?.value
        var recording = library.recordings[0]
        let sam = CallAttendee(name: "Sam")
        let rows = [CallAttendee(id: avery.id, name: avery.name, email: avery.emails[0]), sam]
        try await library.saveDetails(.init(participants: rows.map(\.name), attendees: rows, allowSingleParticipantInference: false), for: recording)
        recording = library.recordings[0]
        await library.assignParticipant(avery.name, to: 0, recording: recording, version: recording.latestTranscript!)
        recording = library.recordings[0]
        try require(library.transcriptDrafts[recording.id] == nil, "Lightweight speaker assignment opened text editing")
        let version = recording.transcripts.first { $0.document?.editing != nil }!
        let originalBytes = try Data(contentsOf: version.url)
        try await render(AttendanceEditor(recording: recording, version: version, library: library), size: NSSize(width: 648, height: 410), name: "attendance")
        var absent = rows; absent[0].attendance = .absent
        try await library.saveAttendance(absent, for: recording, version: version, confirmOnly: nil)
        recording = library.recordings[0]
        try require(recording.details.participants == ["Sam"] && recording.automaticParticipant(for: version) == nil, "Exclusion silently transferred automatic speech")
        try require(recording.speakerLabel(for: version.document!.paragraphs[0], version: version) == "Other participants", "Excluded speaker label was not cleared")
        let afterBytes = try Data(contentsOf: version.url)
        try require(afterBytes == originalBytes, "Attendance modified original transcript bytes")
        library.beginTranscriptEditing(recording, version: version)
        library.transcriptDrafts[recording.id]!.text[1] = "Unsaved correction."
        try await library.saveAttendance(absent, for: recording, version: version, confirmOnly: sam.id)
        let draft = library.transcriptDrafts[recording.id]!
        try require(draft.text[1] == "Unsaved correction." && draft.participants[0] == "Sam" && draft.participants[2] == "Sam", "Explicit confirmation lost draft text or failed to label unassigned speech")
        try require(library.hasUnsavedEdits, "Attendance confirmation silently saved an open transcript draft")
        library.cancelTranscriptEditing(recording)
        recording = library.recordings[0]
        try await library.saveAttendance(absent, for: recording, version: version, confirmOnly: sam.id)
        recording = library.recordings[0]
        try require(recording.transcripts.contains { $0.document?.paragraphs.first?.participant == "Sam" }, "Explicit confirmation did not save speaker assignments")
        print("PASS attendance exclusion, no silent transfer, original preservation, inline speaker assignment, and explicit single-attendee labeling with/without unsaved drafts")
        print("PASS five own-view calendar/attendance renders; no screenshots, calendar access, meeting navigation, or live capture")
    }
    @MainActor static func render<V: View>(_ view: V, size: NSSize, name: String) async throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua); host.appearance = window.appearance
        window.contentView = host; window.orderFront(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        window.appearance!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/calendar-\(name).png"))
        window.orderOut(nil)
    }
}
