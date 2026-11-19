import SwiftUI
import AppKit
import RecorderCore

@MainActor final class SummaryDraft: ObservableObject {
    let id = UUID()
    let recording: LibraryRecording
    @Published var markdown: String
    @Published var saving = false
    @Published var error: String?
    init(recording: LibraryRecording) {
        self.recording = recording; markdown = recording.summary?.current?.markdown ?? ""
    }
    var changed: Bool { markdown.trimmingCharacters(in: .whitespacesAndNewlines) != (recording.summary?.current?.markdown ?? "") }
}

struct CallSummaryView: View {
    let recording: LibraryRecording
    @ObservedObject var library: RecordingLibraryModel
    let cancelEditing: () -> Void
    @State private var selectedID: String?
    @State private var requestError: String?
    private struct SourceCheck: Equatable {
        let callID: String
        let revision: String?
        let summaryID: String
    }
    private var sourceCheck: SourceCheck? {
        guard let version = selected, version.sourceTranscript != nil else { return nil }
        return .init(callID: recording.id, revision: recording.indexRevision, summaryID: version.id)
    }
    @State private var staleSource: SourceCheck?
    private var requestButton: some View {
        Button("Copy summary request") {
            do { copy(try recording.agentSummaryRequest()) }
            catch { requestError = error.localizedDescription }
        }.disabled(recording.latestTranscript?.document == nil)
        .help("Copy a request for your connected agent to summarize this recording")
    }
    private var versions: [CallSummaryVersion] { recording.summary?.versions ?? [] }
    private var selected: CallSummaryVersion? { versions.first { $0.id == selectedID } ?? versions.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let draft = library.summaryDrafts[recording.id] {
                SummaryEditor(draft: draft, save: { Task { await library.saveSummaryDraft(for: recording) } }, cancel: cancelEditing)
            } else if let error = recording.summaryError {
                ContentUnavailableView("Couldn’t read this summary", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let selected {
                HStack {
                    if versions.count > 1 {
                        Picker("Version", selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                            ForEach(versions) { version in
                                Text("\(version.id == versions.first?.id ? "Current · " : "")\(version.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(version.author == "agent" ? "Agent" : "You")").tag(version.id)
                            }
                        }.labelsHidden().accessibilityLabel("Summary version")
                    } else {
                        Text("\(selected.author == "agent" ? "Saved by agent" : "Saved by you") · \(selected.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    requestButton
                    Button { copy(selected.markdown) } label: { Label("Copy", systemImage: "doc.on.doc") }.help("Copy summary as Markdown")
                    Button { library.beginSummaryEditing(recording) } label: { Image(systemName: "pencil") }
                        .help("Edit current summary").accessibilityLabel("Edit summary")
                        .disabled(library.managing || library.transcriptDrafts[recording.id] != nil || selected.id != versions.first?.id)
                }
                if selected.id != versions.first?.id {
                    Text("Previous version · Select Current to edit the saved summary.").font(.caption).foregroundStyle(.secondary)
                }
                if let sourceCheck, staleSource == sourceCheck {
                    Label("The transcript or speaker assignments have changed since this summary was created. Review it before relying on it.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.orange)
                }
                ScrollView {
                    MarkdownContent(markdown: selected.markdown).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView {
                    Label("No summary yet", systemImage: "doc.text")
                } description: {
                    Text("Ask your connected agent to summarize this call and save it here, or write a summary yourself.")
                } actions: {
                    requestButton
                    Button("Add summary") { library.beginSummaryEditing(recording) }
                        .disabled(library.managing || library.transcriptDrafts[recording.id] != nil)
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .alert("Couldn’t copy summary request", isPresented: Binding(get: { requestError != nil }, set: { if !$0 { requestError = nil } })) {
                Button("OK") { requestError = nil }
            } message: { Text(requestError ?? "") }
            .task(id: sourceCheck) {
                guard let key = sourceCheck, let version = selected else { return }
                let changed = await Self.sourceChanged(version, in: recording)
                guard !Task.isCancelled else { return }
                staleSource = changed ? key : nil
            }
            .onChange(of: recording.summary?.current?.id) { _, _ in selectedID = nil }
    }
    // Fingerprinting can serialize thousands of word timestamps. Keep it off
    // the main actor and inherit the cancellation of the selected summary.
    private nonisolated static func sourceChanged(_ version: CallSummaryVersion, in recording: LibraryRecording) async -> Bool {
        !Task.isCancelled && version.sourceChanged(in: recording)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct SummaryEditor: View {
    @ObservedObject var draft: SummaryDraft
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            Text("Edit summary").font(.headline)
            Spacer()
            if draft.saving { ProgressView().controlSize(.small) }
            Button("Cancel", action: cancel).disabled(draft.saving)
            Button("Save", action: save).disabled(draft.saving || !draft.changed || draft.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text("Markdown supported · ⌘S to save · Escape to cancel").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $draft.markdown).font(.body).focused($focused)
            .scrollContentBackground(.hidden).padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .accessibilityLabel("Summary Markdown").disabled(draft.saving)
            .task { focused = true }
        if let error = draft.error {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            Button("Copy draft") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft.markdown, forType: .string)
            }
        }
    }
}
