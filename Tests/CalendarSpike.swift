import AppKit
import EventKit
import CryptoKit

// Read-only EventKit feasibility probe. Reports go to ignored build/, never
// to the recorder's library. Join paths/tokens and event notes are not emitted.
private struct Options {
    var output: URL
    var calendarIDs: [String] = []
    var matches: [String] = []
    var scan = false
    var daysBefore = 7
    var daysAfter = 14
    init(_ arguments: [String]) throws {
        output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/calendar-spike/report.json")
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]; index += 1
            if flag == "--list" { continue }
            if flag == "--scan" { scan = true; continue }
            guard index < arguments.count else { throw ProbeError.message("Missing value for \(flag)") }
            let value = arguments[index]; index += 1
            switch flag {
            case "--output": output = URL(fileURLWithPath: value)
            case "--calendar": calendarIDs.append(value)
            case "--match": matches.append(value)
            case "--days-before": guard let n = Int(value), (0...31).contains(n) else { throw ProbeError.message("Invalid lookback") }; daysBefore = n
            case "--days-after": guard let n = Int(value), (1...31).contains(n) else { throw ProbeError.message("Invalid lookahead") }; daysAfter = n
            default: throw ProbeError.message("Unknown option: \(flag)")
            }
        }
        if scan && (calendarIDs.isEmpty || matches.isEmpty) { throw ProbeError.message("Scanning requires explicit --calendar and --match options") }
    }
}
private enum ProbeError: Error { case message(String) }

@MainActor private final class CalendarProbe: NSObject, NSApplicationDelegate {
    private let store = EKEventStore()
    private var options: Options?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let options = try Options(Array(CommandLine.arguments.dropFirst())); self.options = options
                try write(["status": "requestingCalendarAccess"], to: options.output)
                let authorization = EKEventStore.authorizationStatus(for: .event)
                if authorization != .fullAccess {
                    guard authorization == .notDetermined || authorization == .writeOnly else {
                        throw ProbeError.message("Calendar access is denied or restricted. Enable Calendar Spike in System Settings → Privacy & Security → Calendars to continue.")
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    guard try await store.requestFullAccessToEvents() else { throw ProbeError.message("Calendar access was not granted") }
                }
                let calendars = store.calendars(for: .event)
                if !options.scan {
                    try write(["status": "ok", "calendars": calendars.map(calendar)], to: options.output)
                } else {
                    let selected = calendars.filter { options.calendarIDs.contains($0.calendarIdentifier) }
                    guard selected.count == Set(options.calendarIDs).count else { throw ProbeError.message("A selected calendar is unavailable") }
                    let now = Date(), clock = Calendar.current
                    let start = clock.date(byAdding: .day, value: -options.daysBefore, to: clock.startOfDay(for: now))!
                    let end = clock.date(byAdding: .day, value: options.daysAfter, to: clock.startOfDay(for: now))!
                    let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: selected))
                        .sorted { $0.startDate < $1.startDate }
                    let targets = events.filter { event in
                        let people = (event.attendees ?? []) + (event.organizer.map { [$0] } ?? [])
                        let searchable = ([event.title ?? ""] + people.flatMap { [$0.name ?? "", $0.url.absoluteString] }).joined(separator: "\n")
                        return options.matches.contains { searchable.localizedStandardContains($0) }
                            || people.contains { $0.participantType == .group }
                    }
                    let participants = events.flatMap { $0.attendees ?? [] }
                    try write([
                        "status": "ok", "readOnly": true, "generatedAt": iso(now),
                        "range": ["start": iso(start), "end": iso(end)],
                        "calendars": selected.map(calendar),
                        "summary": ["eventsInRange": events.count, "matchedEvents": targets.count,
                                    "eventsWithAttendees": events.filter { $0.hasAttendees }.count,
                                    "eventsWithRecognizedMeetingLink": events.filter { links($0).contains { $0["provider"] != nil } }.count,
                                    "attendeeTypeCounts": Dictionary(grouping: participants, by: { type($0.participantType) }).mapValues(\.count),
                                    "currentUserAttendeeCount": participants.filter(\.isCurrentUser).count] as [String: Any],
                        "events": targets.map(event)
                    ], to: options.output)
                }
            } catch {
                if let output = options?.output { try? write(["status": "error", "authorizationStatus": EKEventStore.authorizationStatus(for: .event).rawValue, "error": String(describing: error)], to: output) }
                else { fputs("Calendar probe failed: \(error)\n", stderr) }
            }
            NSApp.terminate(nil)
        }
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func calendar(_ value: EKCalendar) -> [String: Any] {
        ["id": value.calendarIdentifier, "title": value.title, "source": value.source.title, "sourceType": value.source.sourceType.rawValue]
    }
    private func type(_ value: EKParticipantType) -> String {
        switch value {
        case .person: return "person"
        case .group: return "group"
        case .room: return "room"
        case .resource: return "resource"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
    private func person(_ value: EKParticipant) -> [String: Any] {
        var result: [String: Any] = ["type": type(value.participantType), "isCurrentUser": value.isCurrentUser,
                                    "role": value.participantRole.rawValue, "status": value.participantStatus.rawValue]
        if let name = value.name { result["name"] = name }
        if value.url.scheme?.lowercased() == "mailto" {
            result["email"] = String(value.url.absoluteString.dropFirst(7)).components(separatedBy: "?")[0].removingPercentEncoding
        } else { result["addressScheme"] = value.url.scheme ?? "none" }
        return result
    }
    private func event(_ value: EKEvent) -> [String: Any] {
        var result: [String: Any] = [
            "reference": SHA256.hash(data: Data(value.calendarItemIdentifier.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined(),
            "title": value.title ?? "", "start": iso(value.startDate), "end": iso(value.endDate),
            "calendar": value.calendar.title, "allDay": value.isAllDay, "status": value.status.rawValue,
            "recurring": value.hasRecurrenceRules, "detachedOccurrence": value.isDetached,
            "hasExternalIdentifier": value.calendarItemExternalIdentifier != nil,
            "fields": ["urlPresent": value.url != nil, "locationCharacters": value.location?.count ?? 0, "notesCharacters": value.notes?.count ?? 0],
            "links": links(value), "attendees": (value.attendees ?? []).map(person)
        ]
        if let organizer = value.organizer { result["organizer"] = person(organizer) }
        if let external = value.calendarItemExternalIdentifier {
            result["externalReference"] = SHA256.hash(data: Data(external.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        }
        if let occurrence = value.occurrenceDate { result["occurrenceDate"] = iso(occurrence) }
        return result
    }
    private func links(_ event: EKEvent) -> [[String: String]] {
        let fields = [("url", event.url?.absoluteString), ("location", event.location), ("notes", event.notes)]
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var result: [[String: String]] = [], seen = Set<String>()
        for (field, text) in fields {
            guard let text else { continue }
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                var link = ["field": field, "host": host]
                if host == "meet.google.com", !url.path.isEmpty, url.path != "/" { link["provider"] = "Google Meet" }
                if (host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoomgov.com" || host.hasSuffix(".zoomgov.com")),
                   url.path.hasPrefix("/j/") || url.path.hasPrefix("/my/") || url.path.hasPrefix("/w/") { link["provider"] = "Zoom" }
                if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host), url.path.contains("meet") || url.path.hasPrefix("/l/") { link["provider"] = "Microsoft Teams" }
                let key = field + "|" + host + "|" + (link["provider"] ?? "")
                if seen.insert(key).inserted { result.append(link) }
            }
        }
        return result
    }
}

@main private enum CalendarSpike {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = CalendarProbe(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
