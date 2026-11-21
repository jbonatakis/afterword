import SwiftUI
import AppKit
import RecorderCore

struct CalendarSettings: View {
    @ObservedObject var calendar: CalendarCoordinator
    @State private var emails = ""
    @State private var emailError: String?
    @State private var savingEmails = false
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
                        let values = emails.components(separatedBy: .newlines)
                        savingEmails = true
                        Task {
                            defer { savingEmails = false }
                            do { try await calendar.setSelfEmails(values); emailError = nil }
                            catch { emailError = error.localizedDescription }
                        }
                    }.disabled(savingEmails)
                }
                if let emailError { Text(emailError).foregroundStyle(.red) }
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
    var embedded = false
    var showPeople: (() -> Void)?
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    if !embedded { Text("Upcoming calls").font(.title2.weight(.semibold)) }
                    Text("Next two days").foregroundStyle(.secondary)
                }
                Spacer()
                Button("People & groups", action: showPeople ?? calendar.showPeople)
                Button { calendar.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh calendar")
                    .disabled(!calendar.connected || calendar.connecting)
                Button {
                    calendar.library?.settingsTab = "calendar"
                    openSettings()
                } label: { Label("Calendar settings", systemImage: "gearshape").labelStyle(.iconOnly) }
                .help("Calendar settings")
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }.padding(22).frame(minWidth: 570, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
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
    private struct ClipSelection: Identifiable { let id: String }
    @ObservedObject var calendar: CalendarCoordinator
    var embedded = false
    @State private var selection: String?
    @State private var search = ""
    @State private var editing: KnownIdentity?
    @State private var clipSelection: ClipSelection?
    private var people: [KnownIdentity] {
        calendar.directory.people.filter { person in
            !person.emails.contains(where: calendar.directory.selfEmails.contains) &&
            (search.isEmpty || person.name.localizedStandardContains(search) || person.emails.contains { $0.localizedStandardContains(search) })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        let matches = people
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !embedded { Text("People & groups").font(.title2.weight(.semibold)) }
                Spacer()
                if calendar.library != nil {
                    Button("All voice clips…") { clipSelection = ClipSelection(id: "") }
                }
                Button("Add person or group") { editing = .init(name: "", emails: []) }
            }.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    TextField("Search names or emails", text: $search)
                        .textFieldStyle(.roundedBorder).padding(10)
                    List(matches, selection: $selection) { person in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(person.name).lineLimit(1)
                                if let email = person.emails.first {
                                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        } icon: { Image(systemName: person.directorySymbol) }
                        .padding(.vertical, 3).tag(person.id)
                    }.listStyle(.inset)
                }.frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
                Group {
                    if let person = matches.first(where: { $0.id == selection }) {
                        profile(person)
                    } else if matches.isEmpty {
                        if search.isEmpty {
                            ContentUnavailableView("No people or groups", systemImage: "person.2",
                                                   description: Text("Add a person or group to remember their name and email addresses."))
                        } else {
                            ContentUnavailableView.search(text: search)
                        }
                    } else {
                        ContentUnavailableView("Select a person or group", systemImage: "person.2")
                    }
                }.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            }
            CalendarError(calendar: calendar)
        }.frame(minWidth: 540, minHeight: 420).background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: matches.map(\.id), initial: true) { _, ids in
                if !ids.contains(where: { $0 == selection }) { selection = ids.first }
            }
            .sheet(item: $clipSelection) { selection in
                if let library = calendar.library { PersonVoiceClipsView(calendar: calendar, library: library, owner: selection.id) }
            }
            .sheet(item: $editing) { identity in
                IdentityEditor(calendar: calendar, identity: identity) {
                    if !people.contains(where: { $0.id == identity.id }) { search = "" }
                    selection = identity.id
                }
            }
    }

    private func profile(_ person: KnownIdentity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(person.kind == .group ? "Group" : person.kind == .resource ? "Ignored resource" : "Person")
                        .foregroundStyle(.secondary)
                }
                if !person.emails.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email addresses").font(.headline)
                        ForEach(person.emails, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                }
                if person.kind == .group {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Members").font(.headline)
                        let members = calendar.directory.people.filter { person.memberIDs.contains($0.id) }
                            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        if members.isEmpty {
                            Text("No members added").foregroundStyle(.secondary)
                        }
                        ForEach(members) { member in Text(member.name) }
                    }
                }
                HStack {
                    Button("Edit…") { editing = person }
                    if person.kind == .person && calendar.library != nil {
                        Button("Voice clips…") { clipSelection = ClipSelection(id: "person:" + person.id) }
                    }
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension KnownIdentity {
    var directorySymbol: String {
        switch kind {
        case .person: "person"
        case .group: "person.3"
        case .resource: "video"
        }
    }
}

private struct IdentityEditor: View {
    @ObservedObject var calendar: CalendarCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var identity: KnownIdentity
    @State private var emails: String
    @State private var error: String?
    @State private var saving = false
    let onSaved: () -> Void
    init(calendar: CalendarCoordinator, identity: KnownIdentity, onSaved: @escaping () -> Void) {
        self.onSaved = onSaved
        self.calendar = calendar; _identity = State(initialValue: identity)
        _emails = State(initialValue: identity.emails.joined(separator: "\n"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(identity.name.isEmpty ? "New identity" : "Edit identity").font(.title2.weight(.semibold))
            Form {
                TextField("Preferred name", text: $identity.name)
                TextField(identity.kind == .person ? "Email addresses (optional)" : "Email addresses", text: $emails, axis: .vertical).lineLimit(2...4)
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
                    var edited = identity
                    edited.emails = emails.components(separatedBy: .newlines)
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await calendar.updateIdentity(edited); onSaved(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }.disabled(saving).interactiveDismissDisabled(saving).padding(24).frame(width: 500).background(Color(nsColor: .windowBackgroundColor))
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
