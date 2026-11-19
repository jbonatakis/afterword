import SwiftUI
import RecorderCore

struct CallDetailsEditor: View {
    let recording: LibraryRecording
    @ObservedObject var library: RecordingLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var managingAttendance = false
    private var current: LibraryRecording { library.recordings.first { $0.id == recording.id } ?? recording }
    @State private var tags: String
    @State private var description: String
    @State private var saving = false
    @State private var error: String?

    init(recording: LibraryRecording, library: RecordingLibraryModel) {
        self.recording = recording; self.library = library
        _title = State(initialValue: recording.name)
        _tags = State(initialValue: recording.details.tags.joined(separator: ", "))
        _description = State(initialValue: recording.details.description)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit call details").font(.title2.weight(.semibold))
            Form {
                TextField("Title", text: $title)
                LabeledContent("Participants") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(current.participantDisplayNames.isEmpty ? "No active participants" : current.participantDisplayNames.joined(separator: ", "))
                        Button("Manage attendees…") { managingAttendance = true }
                    }
                }
                TextField("Tags", text: $tags, prompt: Text("Comma-separated tags"))
                LabeledContent("Description") {
                    TextEditor(text: $description).frame(height: 100).editorBorder().accessibilityLabel("Description")
                }
            }.textFieldStyle(.roundedBorder).disabled(saving)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(saving || library.managing || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 530).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(saving)
        .sheet(isPresented: $managingAttendance) {
            AttendanceEditor(recording: current, version: current.latestTranscript, library: library)
        }
    }
    private func save() {
        error = nil
        saving = true
        Task {
            do { try await library.saveMetadata(title: title, tags: tags.components(separatedBy: ","), description: description, for: recording); dismiss() }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

@MainActor final class TranscriptDraft: ObservableObject {
    let version: LibraryTranscript
    let paragraphs: [TranscriptParagraph]
    let focusedParagraph: Int?
    @Published var text: [String]
    @Published var participants: [String?]
    private var originalParticipants: [String?]
    @Published var saving = false
    @Published var error: String?
    init(version: LibraryTranscript, focusedParagraph: Int?, details: CallDetails) {
        self.version = version; self.focusedParagraph = focusedParagraph
        paragraphs = version.document?.paragraphs ?? []
        text = paragraphs.map(\.text)
        let names = paragraphs.map { details.participantName($0.participant, for: version) }
        participants = names; originalParticipants = names
    }
    var changed: Bool {
        zip(text, paragraphs).contains { $0.0.trimmingCharacters(in: .whitespacesAndNewlines) != $0.1.text } || participants != originalParticipants
    }
    func updateParticipants(_ names: [String], renames: [String: String]) {
        func update(_ name: String?) -> String? {
            guard let name else { return nil }
            if name.isEmpty { return "" }
            let renamed = renames[name] ?? name
            return names.contains(renamed) ? renamed : ""
        }
        originalParticipants = originalParticipants.map(update)
        participants = participants.map(update)
    }
}

struct InlineTranscriptActions: View {
    let recording: LibraryRecording
    @ObservedObject var draft: TranscriptDraft
    @ObservedObject var library: RecordingLibraryModel
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            if draft.saving { ProgressView().controlSize(.small) }
            Button("Cancel", action: cancel).disabled(draft.saving).help("Exit transcript editing (Escape)")
            Button("Save") { Task { await library.saveTranscriptDraft(for: recording) } }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.changed || draft.saving || library.managing)
                .help("Save edits as a new version; keep the original (⌘S)")
        }
    }
}

struct InlineTranscriptNotice: View {
    @ObservedObject var draft: TranscriptDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Editing transcript · Save keeps the original version").foregroundStyle(.secondary)
            if let error = draft.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.font(.caption)
    }
}

struct InlineParagraphEditor: View {
    let paragraph: TranscriptParagraph
    @ObservedObject var draft: TranscriptDraft
    @FocusState.Binding var focusedParagraph: Int?
    var body: some View {
        TextField("Paragraph text", text: $draft.text[paragraph.id], axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 15)).lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(6).background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(focusedParagraph == paragraph.id ? 0.5 : 0.15)))
            .padding(-6).focused($focusedParagraph, equals: paragraph.id).disabled(draft.saving)
            .accessibilityLabel("Edit \(paragraph.source.label) at \(Transcript.timestamp(paragraph.start))")
    }
}

struct ParticipantPicker: View {
    let participant: String?
    let participants: [String]
    let automaticParticipant: String?
    var displayNames: [String: String] = [:]
    var speakerGroup: String? = nil
    var suggestedParticipant: String? = nil
    var assignGroup: ((String, String) -> Void)? = nil
    let start: Double
    let assign: (String?) -> Void
    let editParticipants: () -> Void
    private var displayName: String {
        if let suggestedName { return suggestedName + " · Suggested" }
        let name = participant ?? automaticParticipant
        return name?.isEmpty == false ? (displayNames[name!] ?? name!) : speakerGroup.map { "Speaker " + String($0.dropFirst()) } ?? TranscriptSource.system.label
    }
    private var suggestedName: String? {
        guard participant == nil, automaticParticipant == nil, let suggestedParticipant else { return nil }
        return displayNames[suggestedParticipant] ?? suggestedParticipant
    }
    var body: some View {
        Menu {
            if let speakerGroup, let assignGroup, !participants.isEmpty {
                let group = "Speaker " + String(speakerGroup.dropFirst())
                if let suggestedName, let suggestedParticipant {
                    Button("Confirm \(suggestedName) for \(group)") { assignGroup(speakerGroup, suggestedParticipant) }
                }
                Menu("Assign \(group) to…") {
                    ForEach(participants, id: \.self) { name in
                        Button(displayNames[name] ?? name) { assignGroup(speakerGroup, name) }
                    }
                }
                Section("This passage only") { passageActions }
            } else { passageActions }
            Divider()
            Button("Manage attendees…", action: editParticipants)
        } label: { Text(displayName).font(.callout.weight(.semibold)).lineLimit(1) }
            .menuStyle(.borderlessButton).fixedSize()
            .help(suggestedName == nil ? "Assign a speaker" : "Review the suggested speaker for this voice")
            .accessibilityLabel("Speaker at \(Transcript.timestamp(start))").accessibilityValue(displayName)
    }
    @ViewBuilder private var passageActions: some View {
        if let name = participant, !name.isEmpty, !participants.contains(name) { Text("Assigned: \(name)") }
        ForEach(participants, id: \.self) { name in
            Button { assign(name) } label: {
                if participant == name { Label(displayNames[name] ?? name, systemImage: "checkmark") } else { Text(displayNames[name] ?? name) }
            }
        }
        if !participants.isEmpty { Divider() }
        if let automaticParticipant {
            Button { assign(nil) } label: {
                if participant == nil { Label("Automatic · \(displayNames[automaticParticipant] ?? automaticParticipant)", systemImage: "checkmark") }
                else { Text("Automatic · \(displayNames[automaticParticipant] ?? automaticParticipant)") }
            }
        }
        Button { assign(automaticParticipant == nil && speakerGroup == nil ? nil : "") } label: {
            if participant == "" || (participant == nil && automaticParticipant == nil) { Label("Other participants", systemImage: "checkmark") }
            else { Text("Other participants") }
        }
    }
}

struct DraftParticipantPicker: View {
    let paragraph: TranscriptParagraph
    @ObservedObject var draft: TranscriptDraft
    let participants: [String]
    let automaticParticipant: String?
    var displayNames: [String: String] = [:]
    let assign: (String?) -> Void
    let editParticipants: () -> Void
    var body: some View {
        ParticipantPicker(participant: draft.participants[paragraph.id], participants: participants, automaticParticipant: automaticParticipant,
                          displayNames: displayNames, speakerGroup: paragraph.segments.first?.speakerGroup, start: paragraph.start, assign: assign, editParticipants: editParticipants).disabled(draft.saving)
    }
}

private extension View {
    func editorBorder() -> some View {
        padding(5).background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.25)))
    }
}
