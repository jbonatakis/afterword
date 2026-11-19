import SwiftUI
import RecorderCore

struct AttendanceEditor: View {
    @State private var recording: LibraryRecording
    let version: LibraryTranscript?
    @ObservedObject var library: RecordingLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var roster: AttendanceRoster
    @State private var picker: AttendeePickerTarget?
    private var attendees: [CallAttendee] { roster.attendees }
    private var directory: PeopleDirectory {
        (try? roster.directory(includingPendingIn: library.peopleDirectory)) ?? library.peopleDirectory
    }
    @State private var confirmOnly = false
    @State private var saving = false
    @State private var error: String?
    init(recording: LibraryRecording, version: LibraryTranscript?, library: RecordingLibraryModel) {
        _recording = State(initialValue: recording)
        self.version = version; self.library = library
        _roster = State(initialValue: AttendanceRoster(recording.details.callAttendees))
    }
    private var onlyPerson: CallAttendee? {
        let active = attendees.filter(\.active)
        return active.count == 1 && !attendees.contains(where: { $0.kind == .group && $0.attendance != .absent }) ? active.first : nil
    }
    var body: some View {
        let people = directory
        let labels = people.labels(for: attendees)
        VStack(alignment: .leading, spacing: 14) {
            Text("Who attended?").font(.title2.weight(.semibold))
            Text("Add anyone who joined, or exclude someone who missed the call. Excluding someone clears their speaker labels from this call.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Add attendee…", systemImage: "person.badge.plus") { picker = .add }
                Spacer()
                Button("Mark all people attended") {
                    for index in attendees.indices where attendees[index].kind == .person { roster.attendees[index].attendance = .attended }
                }
                Button("Exclude everyone") {
                    for index in attendees.indices { roster.attendees[index].attendance = .absent }
                }
            }.font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if attendees.isEmpty { Text("No attendees yet").foregroundStyle(.secondary) }
                    ForEach($roster.attendees) { $person in
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: person.kind == .group ? "person.3" : person.attendance == .absent ? "person.slash" : "person")
                                .frame(width: 24).foregroundStyle(person.attendance == .absent ? .secondary : .primary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(labels[person.name] ?? person.name).font(.headline)
                                if let email = person.email, email != (labels[person.name] ?? person.name) { Text(email).font(.caption).foregroundStyle(.secondary) }
                                if person.kind == .group {
                                    Text("Group · never assigned as a speaker").font(.caption).foregroundStyle(.secondary)
                                } else if !person.groupIDs.isEmpty {
                                    Text("Suggested by group roster").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if person.kind == .person {
                                if people.identity(for: person) == nil {
                                    Button("Link to person…") { picker = .link(person) }.buttonStyle(.link)
                                }
                                Menu {
                                    Button("Edit name for this call…") { picker = .rename(person) }
                                    if person.localDisplayName != nil || person.hasLocalName == true {
                                        Button("Use original or directory name") { person.localDisplayName = nil; person.hasLocalName = nil }
                                    }
                                    if people.identity(for: person) != nil {
                                        Button("Link to another person…") { picker = .link(person) }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions for " + person.name)
                                Picker("Attendance for \(labels[person.name] ?? person.name)", selection: $person.attendance) {
                                    Text("Expected").tag(Attendance.expected)
                                    Text("Attended").tag(Attendance.attended)
                                    Text("Didn’t attend").tag(Attendance.absent)
                                }.labelsHidden().frame(width: 145)
                            } else {
                                Button(person.attendance == .absent ? "Restore group" : "Exclude group") {
                                    person.attendance = person.attendance == .absent ? .expected : .absent
                                }
                            }
                            if person.kind == .person, person.attendance == .absent {
                                Button("Restore") { person.attendance = .expected }.buttonStyle(.link)
                            }
                        }
                        Divider()
                    }
                }.padding(.vertical, 4)
            }.frame(height: min(310, max(100, CGFloat(attendees.count) * 67)))
            if attendees.contains(where: { $0.kind == .group }) {
                Text("After checking the individual attendees, exclude the group placeholder. This keeps its remembered roster and listed people intact.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if recording.details.participants.count == 1 && attendees.filter(\.active).count > 1 {
                Text("Saving clears the previous one-person speaker default. Speakers you assigned explicitly keep their labels.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let onlyPerson {
                Toggle("Only \(labels[onlyPerson.name] ?? onlyPerson.name) attended — label unassigned speech", isOn: $confirmOnly)
                Text("Applies to the selected transcript and future transcriptions of this call. Any open transcript draft still needs Save.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save attendance") { save() }.keyboardShortcut(.defaultAction).disabled(saving || library.managing)
            }
        }.padding(24).frame(width: 600).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(saving)
            .onChange(of: onlyPerson?.id) { _, _ in confirmOnly = false }
            .disabled(saving)
            .sheet(item: $picker) { target in
                if case .rename(let attendee) = target {
                    AttendeeNameEditor(name: labels[attendee.name] ?? attendee.name) { name in
                        if let index = roster.attendees.firstIndex(where: { $0.id == attendee.id }) {
                            roster.attendees[index].localDisplayName = name
                        }
                    }
                } else {
                    AttendeePicker(target: target, directory: people, personal: recording.details.scope == .personal,
                               choose: { person in try roster.select(person, from: people, linking: target.row?.id) },
                               create: { name, email, remember in
                                   try roster.add(name: name, email: email, remember: remember, in: people, linking: target.row?.id)
                               })
                }
            }
    }
    private func save() {
        saving = true; error = nil
        Task {
            do {
                try await library.saveAttendance(roster, for: recording, version: version, confirmOnly: confirmOnly ? onlyPerson?.id : nil)
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

private enum AttendeePickerTarget: Identifiable {
    case add, link(CallAttendee), rename(CallAttendee)
    var row: CallAttendee? {
        switch self {
        case .add: return nil
        case .link(let row), .rename(let row): return row
        }
    }
    var id: String { row?.id ?? "add" }
}

private struct AttendeeNameEditor: View {
    @State var name: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name for this call").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { save(name.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 340)
    }
}

private struct AttendeePicker: View {
    let target: AttendeePickerTarget
    let directory: PeopleDirectory
    let choose: (KnownIdentity) throws -> Void
    let create: (String, String, Bool) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var email: String
    @State private var remember: Bool
    @State private var error: String?
    @FocusState private var searching: Bool

    init(target: AttendeePickerTarget, directory: PeopleDirectory, personal: Bool,
         choose: @escaping (KnownIdentity) throws -> Void, create: @escaping (String, String, Bool) throws -> Void) {
        self.target = target
        self.directory = directory
        self.choose = choose
        self.create = create
        _query = State(initialValue: target.row?.localDisplayName ?? target.row?.name ?? "")
        _email = State(initialValue: target.row?.email ?? "")
        _remember = State(initialValue: !personal)
    }

    private var typedName: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedEmail: String { email.isEmpty && typedName.contains("@") ? typedName : email }
    private var existing: KnownIdentity? { directory.identity(email: typedEmail) }
    private var matches: [KnownIdentity] {
        let results = AttendanceRoster.choices(matching: query, in: directory)
        if let existing, existing.kind == .person, Set(existing.emails).isDisjoint(with: directory.selfEmails) {
            return [existing] + results.filter { $0.id != existing.id }
        }
        return results
    }
    private var actionTitle: String {
        if remember { return target.row == nil ? "Create person and add" : "Create person and link" }
        return target.row == nil ? "Add to this call only" : "Save for this call only"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.row.map { "Link " + ($0.localDisplayName ?? $0.name) } ?? "Add attendee")
                .font(.title2.weight(.semibold))
            TextField("Search by name or email", text: $query).textFieldStyle(.roundedBorder).focused($searching)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if matches.isEmpty { Text("No matching people").foregroundStyle(.secondary).padding(.vertical, 6) }
                    ForEach(matches) { person in
                        Button {
                            perform { try choose(person) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.name)
                                    if !person.emails.isEmpty {
                                        Text(person.emails.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Choose " + person.name)
                        Divider()
                    }
                }
            }.frame(height: 150)
            if !typedName.isEmpty {
                Divider()
                Text("Guest details").font(.headline)
                TextField("Email (optional)", text: $email).textFieldStyle(.roundedBorder)
                Toggle("Save to People & groups", isOn: $remember)
                if let existing {
                    Text("This address belongs to " + existing.name + ". Choose the saved person to use this address.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(actionTitle) { perform { try create(typedName, typedEmail, remember) } }
                    .disabled(typedName.isEmpty || existing != nil)
            }
        }.padding(22).frame(width: 420).onAppear { searching = true }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
