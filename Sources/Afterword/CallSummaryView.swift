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
                    Button { copy(selected.markdown) } label: { Label("Copy", systemImage: "doc.on.doc") }.help("Copy summary as Markdown")
                    Button { library.beginSummaryEditing(recording) } label: { Image(systemName: "pencil") }
                        .help("Edit current summary").accessibilityLabel("Edit summary")
                        .disabled(library.managing || library.transcriptDrafts[recording.id] != nil || selected.id != versions.first?.id)
                }
                if selected.id != versions.first?.id {
                    Text("Previous version · Select Current to edit the saved summary.").font(.caption).foregroundStyle(.secondary)
                }
                if selected.sourceChanged(in: recording) {
                    Label("The transcript or speaker assignments have changed since this summary was created. Review it before relying on it.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    SummaryMarkdown(markdown: selected.markdown).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView {
                    Label("No summary yet", systemImage: "doc.text")
                } description: {
                    Text("Ask your connected agent to summarize this call and save it here, or write a summary yourself.")
                } actions: {
                    Button("Add summary") { library.beginSummaryEditing(recording) }
                        .disabled(library.managing || library.transcriptDrafts[recording.id] != nil)
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: recording.summary?.current?.id) { _, _ in selectedID = nil }
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

/// Native, selectable Markdown with block spacing. No HTML or remote resources are loaded.
struct SummaryMarkdown: View {
    let markdown: String
    private struct Block: Identifiable {
        let id: Int
        let kind: String
        let text: String
        var rows: [[String]] = []
    }
    private var blocks: [Block] {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [Block] = [], paragraph: [String] = [], code: [String] = [], fenced = false, index = 0
        func append(_ kind: String, _ text: String, rows: [[String]] = []) { result.append(.init(id: result.count, kind: kind, text: text, rows: rows)) }
        func flush() { if !paragraph.isEmpty { append("text", paragraph.joined(separator: " ")); paragraph = [] } }
        func cells(_ line: String) -> [String] { line.trimmingCharacters(in: CharacterSet(charactersIn: " |\t")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.hasPrefix("```") {
                flush()
                if fenced { append("code", code.joined(separator: "\n")); code = [] }
                fenced.toggle(); continue
            }
            if fenced { code.append(lines[index - 1]); continue }
            if line.isEmpty { flush(); continue }
            if line.contains("|"), index < lines.count {
                let separator = cells(lines[index])
                if separator.count > 1 && separator.allSatisfy({ $0.contains("---") && $0.allSatisfy { "-: ".contains($0) } }) {
                    flush(); var rows = [cells(line)]; index += 1
                    while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        rows.append(cells(lines[index])); index += 1
                    }
                    append("table", "", rows: rows); continue
                }
            }
            if line.hasPrefix("#"), let space = line.firstIndex(of: " "), line[..<space].allSatisfy({ $0 == "#" }) {
                flush(); append("heading", String(line[line.index(after: space)...])); continue
            }
            if line == "---" || line == "***" { flush(); append("rule", ""); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush(); append("bullet", String(line.dropFirst(2))); continue
            }
            if line.hasPrefix("> ") { flush(); append("quote", String(line.dropFirst(2))); continue }
            if let dot = line.firstIndex(of: "."), !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); append("text", line); continue
            }
            paragraph.append(line)
        }
        flush(); if !code.isEmpty { append("code", code.joined(separator: "\n")) }
        return result
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                switch block.kind {
                case "heading": inline(block.text).font(.headline).padding(.top, 6)
                case "bullet": HStack(alignment: .top, spacing: 9) { Text("•"); inline(block.text).frame(maxWidth: .infinity, alignment: .leading) }
                case "quote": HStack(alignment: .top) { Rectangle().fill(.quaternary).frame(width: 3); inline(block.text).foregroundStyle(.secondary) }
                case "code": Text(block.text).font(.system(.callout, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4))
                case "rule": Divider()
                case "table":
                    VStack(spacing: 0) {
                        ForEach(block.rows.indices, id: \.self) { row in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(block.rows[row].indices, id: \.self) { column in
                                    inline(block.rows[row][column]).fontWeight(row == 0 ? .semibold : .regular).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(8)
                            Divider()
                        }
                    }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                default: inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.font(.body).lineSpacing(4).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
    }
}
