import SwiftUI
import RecorderCore

struct CallDetailsEditor: View {
    let recording: LibraryRecording
    @ObservedObject var library: RecordingLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var participants: String
    @State private var tags: String
    @State private var description: String
    @State private var saving = false
    @State private var error: String?

    init(recording: LibraryRecording, library: RecordingLibraryModel) {
        self.recording = recording; self.library = library
        _title = State(initialValue: recording.name)
        _participants = State(initialValue: recording.details.participants.joined(separator: "\n"))
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
                        TextEditor(text: $participants).frame(height: 60).editorBorder().accessibilityLabel("Participants")
                        Text("One name per line").font(.caption).foregroundStyle(.secondary)
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
        saving = true; error = nil
        let details = CallDetails(title: title, participants: participants.components(separatedBy: .newlines),
                                  tags: tags.components(separatedBy: ","), description: description)
        Task {
            do { try await library.saveDetails(details, for: recording); dismiss() }
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
    @Published var saving = false
    @Published var error: String?
    init(version: LibraryTranscript, focusedParagraph: Int?) {
        self.version = version; self.focusedParagraph = focusedParagraph
        paragraphs = version.document?.paragraphs ?? []
        text = paragraphs.map(\.text)
    }
    var changed: Bool {
        zip(text, paragraphs).contains { $0.0.trimmingCharacters(in: .whitespacesAndNewlines) != $0.1.text }
    }
}

struct InlineTranscriptActions: View {
    let recording: LibraryRecording
    @ObservedObject var draft: TranscriptDraft
    @ObservedObject var library: RecordingLibraryModel
    var body: some View {
        HStack(spacing: 8) {
            if draft.saving { ProgressView().controlSize(.small) }
            Button("Cancel") { library.cancelTranscriptEditing(recording) }.disabled(draft.saving)
            Button("Save") { Task { await library.saveTranscriptDraft(for: recording) } }
                .keyboardShortcut("s", modifiers: .command).buttonStyle(.borderedProminent)
                .disabled(!draft.changed || draft.saving || library.managing)
                .help("Save edits as a new version; keep the original")
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

private extension View {
    func editorBorder() -> some View {
        padding(5).background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.25)))
    }
}
