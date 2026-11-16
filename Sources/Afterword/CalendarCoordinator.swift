import AppKit
import EventKit
import Combine
import RecorderCore

struct AvailableCalendar: Identifiable, Sendable {
    let id: String
    let title: String
    let source: String
}

protocol CalendarReading: Sendable {
    func requestAccess() async throws -> Bool
    func read(selected: Set<String>, now: Date) async -> ([AvailableCalendar], [CalendarMeeting])
}

actor CalendarReader: CalendarReading {
    private let store = EKEventStore()
    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }
    func read(selected: Set<String>, now: Date) -> ([AvailableCalendar], [CalendarMeeting]) {
        let calendars = store.calendars(for: .event)
        let choices = calendars.map { AvailableCalendar(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
        let selectedCalendars = calendars.filter { selected.contains($0.calendarIdentifier) }
        guard !selectedCalendars.isEmpty else { return (choices, []) }
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(2 * 86400),
                                                                     calendars: selectedCalendars))
        let meetings = events.compactMap { event -> CalendarMeeting? in
            guard !event.isAllDay, event.status != .canceled, event.endDate > now,
                  let link = MeetingLinks.find(in: [event.url?.absoluteString, event.location, event.notes]) else { return nil }
            var people = event.attendees ?? []
            if let organizer = event.organizer, !people.contains(where: { $0.url == organizer.url }),
               !organizer.url.absoluteString.lowercased().contains("@group.calendar.google.com") { people.append(organizer) }
            let guests = people.compactMap { participant -> MeetingGuest? in
                guard participant.url.scheme?.lowercased() == "mailto" else { return nil }
                let email = String(participant.url.absoluteString.dropFirst(7)).components(separatedBy: "?")[0].removingPercentEncoding ?? ""
                guard email.contains("@"), !email.lowercased().hasSuffix("@group.calendar.google.com") else { return nil }
                let kind: IdentityKind
                switch participant.participantType { case .group: kind = .group; case .room, .resource: kind = .resource; default: kind = .person }
                return MeetingGuest(email: email, name: participant.name, kind: kind, isSelf: participant.isCurrentUser, declined: participant.participantStatus == .declined)
            }.sorted { $0.email < $1.email }
            let id = CalendarMeeting.occurrenceID(externalID: event.calendarItemExternalIdentifier, localID: event.calendarItemIdentifier,
                                                 occurrence: event.occurrenceDate ?? event.startDate)
            return CalendarMeeting(reference: .init(occurrenceID: id, title: event.title ?? "Call", start: event.startDate, end: event.endDate,
                                                    calendar: event.calendar.title, joinURL: link), guests: guests,
                                   guestListAvailable: event.hasAttendees, isOwnInvite: guests.contains(where: \.isSelf))
        }
        return (choices, CalendarMeeting.deduplicated(meetings))
    }
}

@MainActor final class CalendarCoordinator: ObservableObject {
    @Published private(set) var calendars: [AvailableCalendar] = []
    @Published private(set) var meetings: [CalendarMeeting] = []
    @Published private(set) var directory = PeopleDirectory()
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var directoryError: String?
    @Published var reminder: CalendarMeeting?
    @Published private(set) var connected: Bool
    @Published private(set) var connecting = false
    @Published private(set) var enabled: Bool
    @Published private(set) var selected: Set<String>
    @Published private(set) var leadSeconds: Int
    @Published private(set) var authorized = false
    private let reader: any CalendarReading
    private let hasAccess: @Sendable () -> Bool
    private let defaults: UserDefaults
    private let directoryURL: URL
    private weak var recorder: RecordingCoordinator?
    private var ledger: MeetingReminderLedger
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var connectionGeneration = UUID()
    private var timer: Timer?
    private var lastRefresh = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var stateSubscription: AnyCancellable?
    private var noticesSubscription: AnyCancellable?
    private var startingFromCalendar = false
    private var upcomingWindow: NSWindowController?
    private var peopleWindow: NSWindowController?
    private var reminderWindow: NSWindowController?
    private var reminderSubscription: AnyCancellable?

    init(recorder: RecordingCoordinator, directoryURL: URL, defaults: UserDefaults = .standard, reader: any CalendarReading = CalendarReader(),
         hasAccess: @escaping @Sendable () -> Bool = { EKEventStore.authorizationStatus(for: .event) == .fullAccess }) {
        self.reader = reader; self.hasAccess = hasAccess
        self.recorder = recorder; self.directoryURL = directoryURL; self.defaults = defaults
        let savedEnabled = defaults.bool(forKey: "calendarEnabled")
        let savedSelection = Set(defaults.stringArray(forKey: "calendarSelection") ?? [])
        // Preserve configured connections on upgrade; OS permission alone does not connect a fresh install.
        let savedConnection = defaults.object(forKey: "calendarConnected") as? Bool ?? (savedEnabled || !savedSelection.isEmpty)
        enabled = savedEnabled; selected = savedSelection; connected = savedConnection
        defaults.set(savedConnection, forKey: "calendarConnected")
        leadSeconds = defaults.object(forKey: "calendarLeadSeconds") == nil ? 60 : defaults.integer(forKey: "calendarLeadSeconds")
        ledger = defaults.data(forKey: "calendarReminderLedger").flatMap { try? JSONDecoder().decode(MeetingReminderLedger.self, from: $0) } ?? .init()
        do { directory = try PeopleDirectory.load(from: directoryURL) } catch { directoryError = error.localizedDescription }
        authorized = hasAccess()
    }
    var locked: Bool { recorder?.locked ?? true }
    var canStart: Bool { connected && authorized && !locked && directoryError == nil && !directory.selfEmails.isEmpty && recorder?.noticesAccepted == true }
    var startHelp: String? {
        if !connected || !authorized { return "Connect macOS Calendar and allow access in Calendar settings first." }
        if locked { return "Finish the current recording or audio test first." }
        if recorder?.noticesAccepted != true { return "Open Recording controls and acknowledge the recording notices first." }
        if directory.selfEmails.isEmpty { return "Add your email in Calendar settings so you are excluded from other participants." }
        return directoryError
    }
    func startMonitoring(refreshImmediately: Bool = true) {
        guard connected, timer == nil else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lastRefresh = .distantPast; self?.refresh() }
        })
        stateSubscription = recorder?.$state.sink { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if [.preparing, .recording, .previewing, .finalizing].contains(state) { self.reminder = nil }
                if self.startingFromCalendar, state == .recording { self.startingFromCalendar = false }
                if self.startingFromCalendar, [.error, .needsPermission, .recoverable].contains(state) {
                    self.startingFromCalendar = false
                    self.error = self.recorder?.message ?? "Recording could not start. Check Recording controls."
                    self.showUpcoming()
                }
                self.objectWillChange.send()
            }
        }
        noticesSubscription = recorder?.$noticesAccepted.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        reminderSubscription = $reminder.map { $0?.reminderKey }.removeDuplicates().sink { [weak self] key in
            Task { @MainActor in
                guard let self else { return }
                self.reminderWindow?.close(); self.reminderWindow = nil
                if key != nil, self.reminder != nil {
                    self.reminderWindow = CalendarWindows.reminder(calendar: self)
                    self.reminderWindow?.window?.orderFrontRegardless()
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastRefresh) >= 60 { self.refresh() }
                self.checkReminder()
            }
        }
        if refreshImmediately { refresh() }
    }
    private func stopMonitoring() {
        timer?.invalidate(); timer = nil; refreshTask?.cancel(); refreshTask = nil; generation = UUID()
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []; stateSubscription = nil; noticesSubscription = nil; reminderSubscription = nil
        reminderWindow?.close(); reminderWindow = nil
    }
    func shutdown() {
        connectionGeneration = UUID(); connecting = false; loading = false
        stopMonitoring()
        upcomingWindow?.close(); peopleWindow?.close()
    }
    func disconnect() {
        connectionGeneration = UUID(); connecting = false
        connected = false; defaults.set(false, forKey: "calendarConnected")
        enabled = false; defaults.set(false, forKey: "calendarEnabled")
        stopMonitoring()
        calendars = []; meetings = []; reminder = nil; loading = false; error = nil
        startingFromCalendar = false
        ledger = .init(); defaults.removeObject(forKey: "calendarReminderLedger")
    }
    func openPermissionSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
    func setEnabled(_ value: Bool) {
        guard connected else { return }
        enabled = value; defaults.set(value, forKey: "calendarEnabled")
        if !value { reminder = nil; meetings = [] }
        refresh()
    }
    func select(_ calendarID: String, enabled: Bool) {
        guard connected else { return }
        if enabled { selected.insert(calendarID) } else { selected.remove(calendarID) }
        defaults.set(Array(selected), forKey: "calendarSelection"); refresh()
    }
    func setLead(_ seconds: Int) { leadSeconds = seconds; defaults.set(seconds, forKey: "calendarLeadSeconds"); checkReminder() }
    func connect() async {
        guard !connecting else { return }
        connectionGeneration = UUID()
        let attempt = connectionGeneration
        connecting = true; error = nil
        refreshTask?.cancel(); refreshTask = nil; generation = UUID(); loading = false
        defer { if connectionGeneration == attempt { connecting = false } }
        do {
            let granted = try await reader.requestAccess()
            guard connectionGeneration == attempt, !Task.isCancelled else { return }
            authorized = hasAccess()
            guard granted, authorized else { throw RecorderError.message("Allow calendar access in System Settings → Privacy & Security → Calendars.") }
            let (available, _) = await reader.read(selected: [], now: Date())
            guard connectionGeneration == attempt, !Task.isCancelled else { return }
            authorized = hasAccess()
            guard authorized else { throw RecorderError.message("Calendar access was removed. Allow access in System Settings → Privacy & Security → Calendars.") }
            calendars = available
            if selected.isEmpty {
                let primary = available.filter { $0.title.contains("@") && !$0.title.hasSuffix("@group.calendar.google.com") }
                if primary.count == 1 { selected = [primary[0].id]; defaults.set(Array(selected), forKey: "calendarSelection") }
            }
            connected = true; defaults.set(true, forKey: "calendarConnected")
            enabled = true; defaults.set(true, forKey: "calendarEnabled")
            connecting = false
            startMonitoring(refreshImmediately: false)
            await refresh()?.value
        } catch {
            guard connectionGeneration == attempt else { return }
            self.error = error.localizedDescription
        }
    }
    @discardableResult func refresh() -> Task<Void, Never>? {
        refreshTask?.cancel(); generation = UUID()
        let generation = generation
        authorized = hasAccess()
        guard connected, authorized, !connecting else {
            if !connected || !authorized { calendars = []; meetings = []; reminder = nil }
            loading = false; lastRefresh = Date(); return nil
        }
        loading = true
        let selection = enabled ? selected : []
        refreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == generation, connected else { return }
            let (available, fetched) = await reader.read(selected: selection, now: Date())
            guard !Task.isCancelled, self.generation == generation, connected else { return }
            authorized = hasAccess()
            guard authorized else {
                calendars = []; meetings = []; reminder = nil; loading = false; lastRefresh = Date(); return
            }
            calendars = available; lastRefresh = Date(); loading = false
            var updated = directory
            for email in fetched.flatMap(\.guests).filter(\.isSelf).map(\.email) where !updated.selfEmails.contains(email) { updated.selfEmails.append(email) }
            let valid = fetched.filter { !$0.guests.contains { $0.declined && ($0.isSelf || updated.selfEmails.contains($0.email)) } }
            for meeting in valid { _ = meeting.callDetails(directory: &updated) }
            if updated != directory, directoryError == nil {
                do { try updated.save(to: directoryURL); directory = updated }
                catch { directoryError = error.localizedDescription }
            }
            meetings = valid
            if let reminder { self.reminder = valid.first(where: { $0.reminderKey == reminder.reminderKey }) }
            checkReminder()
        }
        return refreshTask
    }
    func preview(_ meeting: CalendarMeeting) -> CallDetails { var copy = directory; return meeting.callDetails(directory: &copy) }
    func updateIdentity(_ identity: KnownIdentity) throws {
        guard directoryError == nil else { throw RecorderError.message(directoryError!) }
        var copy = directory; try copy.update(identity); try copy.save(to: directoryURL); directory = copy
    }
    func setSelfEmails(_ values: [String]) throws {
        guard directoryError == nil else { throw RecorderError.message(directoryError!) }
        var copy = directory
        copy.selfEmails = Array(Set(values.map(KnownIdentity.email).filter { !$0.isEmpty })).sorted()
        guard copy.selfEmails.allSatisfy({ $0.contains("@") && !$0.contains(where: \.isWhitespace) }) else { throw RecorderError.message("Enter valid email addresses, one per line.") }
        try copy.save(to: directoryURL); directory = copy; refresh()
    }
    func checkReminder(now: Date = Date()) {
        guard connected else { return }
        if authorized != hasAccess() { refresh(); return }
        guard enabled, authorized, !loading else { return }
        if let reminder, reminder.reference.end <= now || reminder.reference.start < now.addingTimeInterval(-5 * 60) { self.reminder = nil }
        guard reminder == nil, let meeting = ledger.due(meetings, now: now, lead: Double(leadSeconds), recording: locked) else { return }
        ledger.markShown(meeting, now: now); saveLedger(); reminder = meeting
    }
    func dismissReminder(snooze: Bool = false) {
        if let reminder, snooze { ledger.snooze(reminder, until: Date().addingTimeInterval(60)); saveLedger() }
        reminder = nil
    }
    private func saveLedger() { defaults.set(try? JSONEncoder().encode(ledger), forKey: "calendarReminderLedger") }
    func startMeeting(_ displayed: CalendarMeeting, join: Bool) async {
        guard canStart else { error = startHelp; return }
        await refresh()?.value
        guard connected, enabled, authorized, let current = meetings.first(where: { $0.id == displayed.id }), current == displayed,
              current.reference.end > Date() else { error = "This meeting changed or is no longer available. Review the refreshed list before starting."; return }
        guard canStart else { error = startHelp; return }
        error = nil
        let details = preview(current)
        startingFromCalendar = true
        recorder?.start(callDetails: details)
        if recorder?.state == .preparing {
            ledger.markShown(current, now: Date()); saveLedger(); reminder = nil
            if join { NSWorkspace.shared.open(current.reference.joinURL) }
        } else {
            startingFromCalendar = false
            error = recorder?.message ?? "Recording could not start. Check the selected microphone."
        }
    }
    func showUpcoming() {
        startMonitoring()
        if upcomingWindow == nil { upcomingWindow = CalendarWindows.upcoming(calendar: self) }
        upcomingWindow?.showWindow(nil); upcomingWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true); refresh()
    }
    func showPeople() {
        if peopleWindow == nil { peopleWindow = CalendarWindows.people(calendar: self) }
        peopleWindow?.showWindow(nil); peopleWindow?.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
