import SwiftUI
import AppKit
import RecorderCore

struct CalendarSettings: View {
    @ObservedObject var calendar: CalendarCoordinator
    @State private var emails = ""
    @State private var emailError: String?
    var body: some View {
        Form {
            Section("Connection") {
                Text("Suggest recording calls from calendars synced with macOS Calendar. Meeting links in the event identify Google Meet, Zoom, and Teams calls.")
                    .font(.callout).foregroundStyle(.secondary)
                if calendar.connecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting to macOS Calendar…")
                        Spacer()
                        Button("Cancel", action: calendar.disconnect)
                    }
                } else if calendar.connected {
                    HStack {
                        Label(calendar.authorized ? "Connected to macOS Calendar" : "Calendar access needed",
                              systemImage: calendar.authorized ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        Spacer()
                        Button("Disconnect", action: calendar.disconnect)
                    }
                    if !calendar.authorized {
                        Button("Allow Calendar Access") { Task { await calendar.connect() } }
                    }
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                    Button("Connect macOS Calendar") { Task { await calendar.connect() } }
                }
                Text("Disconnect stops calendar reads and reminders in Afterword. Saved calls and people are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open System Settings…", action: calendar.openPermissionSettings)
                Text("To change the macOS permission, open Privacy & Security → Calendars → Afterword.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if calendar.connected && calendar.authorized && !calendar.connecting {
                Section("Recording reminders") {
                    Toggle("Suggest recording upcoming calls", isOn: Binding(get: { calendar.enabled }, set: calendar.setEnabled))
                    Picker("Remind me", selection: Binding(get: { calendar.leadSeconds }, set: calendar.setLead)) {
                        Text("At start time").tag(0)
                        Text("30 seconds before").tag(30)
                        Text("1 minute before").tag(60)
                        Text("2 minutes before").tag(120)
                        Text("5 minutes before").tag(300)
                    }
                    Text("Afterword must stay running to show reminders. You can close its windows. Recording starts only when you choose it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if calendar.connected && calendar.authorized && !calendar.connecting {
                Section("Calendars") {
                    if calendar.calendars.isEmpty { Text("No calendars available. Add your account in macOS Calendar.").foregroundStyle(.secondary) }
                    ForEach(calendar.calendars) { item in
                        Toggle(isOn: Binding(get: { calendar.selected.contains(item.id) }, set: { calendar.select(item.id, enabled: $0) })) {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                Text(item.source).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Select your own calendar first. Shared copies of the same meeting are combined.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Your email addresses") {
                TextField("One address per line", text: $emails, axis: .vertical).lineLimit(2...4)
                    .accessibilityLabel("Your email addresses")
                HStack {
                    Text("Used to keep you out of the other participants list. Learned from your own invitations when available.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save emails") {
                        do { try calendar.setSelfEmails(emails.components(separatedBy: .newlines)); emailError = nil }
                        catch { emailError = error.localizedDescription }
                    }
                }
                if let emailError { Text(emailError).foregroundStyle(.red) }
            }
            Section {
                Button("People & groups…") { calendar.showPeople() }
                Text("Remember preferred names, email aliases, and group rosters locally on this Mac. Calendar events are never edited.").font(.caption).foregroundStyle(.secondary)
            }
            CalendarError(calendar: calendar)
        }.formStyle(.grouped)
            .onAppear { emails = calendar.directory.selfEmails.joined(separator: "\n"); calendar.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in calendar.refresh() }
            .onChange(of: calendar.directory.selfEmails) { old, new in
                if emails == old.joined(separator: "\n") { emails = new.joined(separator: "\n") }
            }
    }
}

struct UpcomingMeetingsView: View {
    @ObservedObject var calendar: CalendarCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Upcoming calls").font(.title2.weight(.semibold))
                    Text("Next two days").foregroundStyle(.secondary)
                }
                Spacer()
                Button("People & groups") { calendar.showPeople() }
                Button { calendar.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh calendar")
                    .disabled(!calendar.connected || calendar.connecting)
                SettingsLink { Image(systemName: "gearshape") }.help("Calendar settings")
            }
            if !calendar.connected || !calendar.authorized {
                ContentUnavailableView {
                    Label("Connect your calendar", systemImage: "calendar.badge.plus")
                } description: { Text("Find calls in the calendars already on your Mac.") } actions: {
                    if calendar.connecting {
                        ProgressView("Connecting…")
                        Button("Cancel", action: calendar.disconnect)
                    } else {
                        Button("Connect macOS Calendar") { Task { await calendar.connect() } }
                    }
                }
            } else if !calendar.enabled || calendar.selected.isEmpty {
                CalendarSettings(calendar: calendar)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if calendar.meetings.isEmpty {
                            ContentUnavailableView("No upcoming calls", systemImage: "calendar", description: Text(calendar.loading ? "Checking your calendars…" : "No Google Meet, Zoom, or Teams calls in the selected calendars over the next two days."))
                        }
                        ForEach(calendar.meetings) { meeting in
                            VStack(alignment: .leading, spacing: 10) {
                                MeetingSummary(meeting: meeting, details: calendar.preview(meeting))
                                MeetingActions(calendar: calendar, meeting: meeting)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            CalendarError(calendar: calendar)
        }.padding(22).frame(minWidth: 570, minHeight: 400).background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MeetingSummary: View {
    let meeting: CalendarMeeting
    let details: CallDetails
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(meeting.reference.title).font(.headline).lineLimit(2)
            Text(meeting.reference.start, format: .dateTime.weekday().month().day().hour().minute()).font(.callout)
            Text([MeetingLinks.provider(meeting.reference.joinURL), meeting.reference.calendar].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            if !details.participants.isEmpty {
                Label(details.participants.joined(separator: ", "), systemImage: "person.2").font(.callout).lineLimit(3)
            }
            let groups = details.callAttendees.filter { $0.kind == .group && $0.attendance != .absent }
            if !groups.isEmpty {
                Text("Groups: " + groups.map(\.name).joined(separator: ", ") + ". Review attendance after the call.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !meeting.guestListAvailable {
                Text("No guest list available. Add participants after recording.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MeetingActions: View {
    @ObservedObject var calendar: CalendarCoordinator
    let meeting: CalendarMeeting
    @State private var starting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button("Start recording") { start(join: false) }
                Button("Join & record") { start(join: true) }.buttonStyle(.borderedProminent)
                if starting { ProgressView().controlSize(.small) }
            }.disabled(!calendar.canStart || starting)
            if let help = calendar.startHelp { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func start(join: Bool) {
        starting = true
        Task { await calendar.startMeeting(meeting, join: join); starting = false }
    }
}

struct CalendarReminderView: View {
    @ObservedObject var calendar: CalendarCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let meeting = calendar.reminder {
                Label("Your call is coming up", systemImage: "calendar.badge.clock").font(.callout).foregroundStyle(.secondary)
                MeetingSummary(meeting: meeting, details: calendar.preview(meeting))
                MeetingActions(calendar: calendar, meeting: meeting)
                HStack {
                    Button("In 1 minute") { calendar.dismissReminder(snooze: true) }
                    Button("Dismiss") { calendar.dismissReminder() }
                    Spacer()
                    Button("Review calls") { calendar.showUpcoming() }
                }.font(.callout)
                CalendarError(calendar: calendar)
            }
        }.padding(22).frame(width: 450, alignment: .leading).fixedSize(horizontal: false, vertical: true).background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct CalendarError: View {
    @ObservedObject var calendar: CalendarCoordinator
    var body: some View {
        if let error = calendar.directoryError ?? calendar.error {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
        }
    }
}

struct PeopleDirectoryView: View {
    @ObservedObject var calendar: CalendarCoordinator
    @State private var search = ""
    @State private var editing: KnownIdentity?
    private var people: [KnownIdentity] {
        calendar.directory.people.filter { person in
            !person.emails.contains(where: calendar.directory.selfEmails.contains) &&
            (search.isEmpty || person.name.localizedStandardContains(search) || person.emails.contains { $0.localizedStandardContains(search) })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("People & groups").font(.title2.weight(.semibold))
                Spacer()
                Button("Add person or group") { editing = .init(name: "", emails: []) }
            }
            Text("Preferred names appear on matching speakers in your recording library. Group members are expected guests until you review attendance.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search names and email addresses", text: $search).textFieldStyle(.roundedBorder)
            List(people) { person in
                HStack {
                    Image(systemName: person.kind == .group ? "person.3" : person.kind == .resource ? "video" : "person")
                        .frame(width: 25)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name).font(.headline)
                        Text(person.emails.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(person.kind == .group ? "Group · \(person.memberIDs.count) \(person.memberIDs.count == 1 ? "member" : "members")" : person.kind == .resource ? "Ignored resource" : "Person")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Edit") { editing = person }
                }.padding(.vertical, 5)
            }
            CalendarError(calendar: calendar)
        }.padding(22).frame(minWidth: 580, minHeight: 420).background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $editing) { identity in IdentityEditor(calendar: calendar, identity: identity) }
    }
}

private struct IdentityEditor: View {
    @ObservedObject var calendar: CalendarCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var identity: KnownIdentity
    @State private var emails: String
    @State private var error: String?
    init(calendar: CalendarCoordinator, identity: KnownIdentity) {
        self.calendar = calendar; _identity = State(initialValue: identity)
        _emails = State(initialValue: identity.emails.joined(separator: "\n"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(identity.name.isEmpty ? "New identity" : "Edit identity").font(.title2.weight(.semibold))
            Form {
                TextField("Preferred name", text: $identity.name)
                TextField("Email addresses", text: $emails, axis: .vertical).lineLimit(2...4)
                Picker("Kind", selection: $identity.kind) {
                    Text("Person").tag(IdentityKind.person)
                    Text("Group / mailing list").tag(IdentityKind.group)
                    Text("Room / resource (ignore)").tag(IdentityKind.resource)
                }
            }
            if identity.kind == .group {
                Text("Optional group roster").font(.headline)
                Text("Only people you select here are remembered as group members. Inviting people to the same event does not add them to the group.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(calendar.directory.people.filter { $0.kind == .person && !$0.emails.contains(where: calendar.directory.selfEmails.contains) }.sorted { $0.name < $1.name }) { person in
                            Toggle(person.name, isOn: Binding(get: { identity.memberIDs.contains(person.id) }, set: { value in
                                identity.memberIDs.removeAll { $0 == person.id }
                                if value { identity.memberIDs.append(person.id) }
                            }))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 170)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        identity.emails = emails.components(separatedBy: .newlines)
                        try calendar.updateIdentity(identity); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 500).background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor enum CalendarWindows {
    static func upcoming(calendar: CalendarCoordinator) -> NSWindowController {
        window(title: "Upcoming Calls", size: NSSize(width: 680, height: 590), content: UpcomingMeetingsView(calendar: calendar))
    }
    static func people(calendar: CalendarCoordinator) -> NSWindowController {
        window(title: "People & Groups", size: NSSize(width: 700, height: 560), content: PeopleDirectoryView(calendar: calendar))
    }
    static func reminder(calendar: CalendarCoordinator) -> NSWindowController {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: 330), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Upcoming Call"; panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CalendarReminderView(calendar: calendar))
        panel.center()
        return NSWindowController(window: panel)
    }
    private static func window<Content: View>(title: String, size: NSSize, content: Content) -> NSWindowController {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: content)
        window.center()
        return NSWindowController(window: window)
    }
}
