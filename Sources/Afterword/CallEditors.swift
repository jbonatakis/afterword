import SwiftUI
import RecorderCore

private struct ParticipantRow: Identifiable {
    let id = UUID()
    let originalName: String?
    var originalDisplayName: String? = nil
    var name: String
    var storedName: String {
        let edited = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return edited == originalDisplayName ? originalName ?? edited : edited
    }
}

struct CallDetailsEditor: View {
    let recording: LibraryRecording
    @ObservedObject var library: RecordingLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var participants: [ParticipantRow]
    @State private var tags: String
    @State private var description: String
    @State private var saving = false
    @State private var error: String?

    init(recording: LibraryRecording, library: RecordingLibraryModel) {
        self.recording = recording; self.library = library
        _title = State(initialValue: recording.name)
        _participants = State(initialValue: recording.details.participants.map { raw in
            let display = recording.displayName(raw)
            return ParticipantRow(originalName: raw, originalDisplayName: display, name: display)
        })
        _tags = State(initialValue: recording.details.tags.joined(separator: ", "))
        _description = State(initialValue: recording.details.description)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit call details").font(.title2.weight(.semibold))
            Form {
                TextField("Title", text: $title)
                LabeledContent("Participants") {
                    VStack(alignment: .leading, spacing: 4) {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach($participants) { $participant in
                                    HStack {
                                        TextField("Name", text: $participant.name).labelsHidden().accessibilityLabel("Participant name")
                                        Button {
                                            participants.removeAll { $0.id == participant.id }
                                        } label: { Image(systemName: "minus.circle") }
                                            .buttonStyle(.borderless).help("Remove participant").accessibilityLabel("Remove participant")
                                    }
                                }
                            }
                        }.frame(height: min(120, CGFloat(participants.count) * 28))
                        Button("Add participant", systemImage: "plus") { participants.append(.init(originalName: nil, name: "")) }
                            .buttonStyle(.borderless)
                        Text("List the other people on the call. Renaming updates their labels; removing clears their assignments. One person labels automatic sections; adding people keeps existing assignments.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    }
    private func save() {
        error = nil
        let names = participants.map(\.storedName).filter { !$0.isEmpty }
        let displayed = CallDetails(participants: participants.map(\.name)).normalized.participants
        let details = CallDetails(title: title, participants: names,
                                  tags: tags.components(separatedBy: ","), description: description)
        guard details.normalized.participants.count == names.count, displayed.count == names.count else { error = "Use a different name for each participant."; return }
        let renames = Dictionary(uniqueKeysWithValues: participants.compactMap { row -> (String, String)? in
            let name = row.storedName
            guard let original = row.originalName, !name.isEmpty, name != original else { return nil }
            return (original, name)
        })
        saving = true
        Task {
            do { try await library.saveDetails(details, for: recording, participantRenames: renames); dismiss() }
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
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Paragraph text", text: $draft.text[paragraph.id], axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 15)).lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(6).background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(focused ? 0.5 : 0.15)))
            .padding(-6).focused($focused).disabled(draft.saving)
            .accessibilityLabel("Edit \(paragraph.source.label) at \(Transcript.timestamp(paragraph.start))")
            .onAppear {
                if draft.focusedParagraph == paragraph.id { focused = true }
            }
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
            Button("Edit participants…", action: editParticipants)
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
