import SwiftUI
import RecorderCore

enum CallEditor: Identifiable {
    case details(LibraryRecording)
    case transcript(LibraryRecording, LibraryTranscript)
    var id: String {
        switch self { case .details(let call): return "details:" + call.id
        case .transcript(_, let version): return "transcript:" + version.id }
    }
}

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

struct TranscriptEditor: View {
    let recording: LibraryRecording
    let version: LibraryTranscript
    @ObservedObject var library: RecordingLibraryModel
    @Environment(\.dismiss) private var dismiss
    private let paragraphs: [TranscriptParagraph]
    @State private var text: [String]
    @State private var saving = false
    @State private var error: String?

    init(recording: LibraryRecording, version: LibraryTranscript, library: RecordingLibraryModel) {
        self.recording = recording; self.version = version; self.library = library
        paragraphs = version.document?.paragraphs ?? []
        _text = State(initialValue: paragraphs.map(\.text))
    }
    private var changed: Bool {
        zip(text, paragraphs).contains { $0.0.trimmingCharacters(in: .whitespacesAndNewlines) != $0.1.text }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Edit transcript").font(.title2.weight(.semibold))
                Text(recording.name).font(.headline).lineLimit(2)
                Text("Save a new version while keeping the original. Each paragraph stays linked to its audio interval; clear its text to remove it from the new version.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(paragraphs.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(paragraphs[index].source.label).fontWeight(.semibold)
                                Spacer()
                                Text(Transcript.timestamp(paragraphs[index].start) + " – " + Transcript.timestamp(paragraphs[index].end)).monospacedDigit().foregroundStyle(.secondary)
                            }.font(.caption)
                            TextEditor(text: $text[index]).font(.body).frame(minHeight: 90, idealHeight: 110)
                                .editorBorder().accessibilityLabel("\(paragraphs[index].source.label) at \(Transcript.timestamp(paragraphs[index].start))")
                        }
                    }
                }.padding(24)
            }.disabled(saving)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    if saving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                    Button("Save new version") { save() }.keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent).disabled(!changed || saving || library.managing)
                }
            }.padding(20)
        }.frame(width: 660, height: 580).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(saving)
    }
    private func save() {
        saving = true; error = nil
        Task {
            do { try await library.saveTranscript(text, version: version, recording: recording); dismiss() }
            catch { self.error = error.localizedDescription }
            saving = false
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
