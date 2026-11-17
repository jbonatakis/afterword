import SwiftUI
import RecorderCore

struct AttendanceEditor: View {
    let recording: LibraryRecording
    let version: LibraryTranscript?
    @ObservedObject var library: RecordingLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var attendees: [CallAttendee]
    @State private var confirmOnly = false
    @State private var saving = false
    @State private var error: String?
    init(recording: LibraryRecording, version: LibraryTranscript?, library: RecordingLibraryModel) {
        self.recording = recording; self.version = version; self.library = library
        _attendees = State(initialValue: recording.details.callAttendees)
    }
    private var onlyPerson: CallAttendee? {
        let active = attendees.filter(\.active)
        return active.count == 1 && !attendees.contains(where: { $0.kind == .group && $0.attendance != .absent }) ? active.first : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who attended?").font(.title2.weight(.semibold))
            Text("Invitations and group rosters show expected guests. Excluding someone removes them from speaker choices and clears their labels. Their speech stays in the transcript as Other participants.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Mark all people attended") {
                    for index in attendees.indices where attendees[index].kind == .person { attendees[index].attendance = .attended }
                }
                Button("Exclude everyone") {
                    for index in attendees.indices { attendees[index].attendance = .absent }
                }
            }.font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($attendees) { $person in
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: person.kind == .group ? "person.3" : person.attendance == .absent ? "person.slash" : "person")
                                .frame(width: 24).foregroundStyle(person.attendance == .absent ? .secondary : .primary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recording.displayName(person.name)).font(.headline)
                                if let email = person.email, email != recording.displayName(person.name) { Text(email).font(.caption).foregroundStyle(.secondary) }
                                if person.kind == .group {
                                    Text("Group · never assigned as a speaker").font(.caption).foregroundStyle(.secondary)
                                } else if !person.groupIDs.isEmpty {
                                    Text("Suggested by group roster").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if person.kind == .person {
                                Picker("Attendance for \(recording.displayName(person.name))", selection: $person.attendance) {
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
            if let onlyPerson {
                Toggle("Only \(recording.displayName(onlyPerson.name)) attended — label unassigned speech", isOn: $confirmOnly)
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
    }
    private func save() {
        saving = true; error = nil
        Task {
            do {
                try await library.saveAttendance(attendees, for: recording, version: version, confirmOnly: confirmOnly ? onlyPerson?.id : nil)
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
