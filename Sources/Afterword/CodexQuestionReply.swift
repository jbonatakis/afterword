import SwiftUI

enum CodexQuestionReply: Sendable {
    enum Reference: Equatable, Sendable {
        case adjacent, earlier(String), embedded
    }

    struct Answer: Sendable {
        let question, answer: String
        let reference: Reference
    }

    case answers([Answer])
    case unrecognized

    private struct Entry: Decodable {
        let question, answer: String
        let questionItemId: String?
    }

    private struct ItemID: Decodable, Hashable {
        let call: String
        let index: Int

        init(from decoder: Decoder) throws {
            var fields = try decoder.unkeyedContainer()
            let tool = try fields.decode(String.self)
            call = try fields.decode(String.self)
            index = try fields.decode(Int.self)
            guard tool == "request_user_input_async", !call.isEmpty, index >= 0, fields.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: fields, debugDescription: "Unknown Codex question identifier")
            }
        }
    }

    static func link(in rows: inout [CodingConversationRow]) {
        var prompts: [String: [Int]] = [:]
        for i in rows.indices {
            let message = rows[i].message
            if message.role == "Assistant", rows[i].hasText {
                // The archive suffixes repeated source IDs after a rollback.
                var id = message.id
                if let hash = id.lastIndex(of: "#"), let occurrence = Int(id[id.index(after: hash)...]), occurrence >= 2 {
                    id = String(id[..<hash])
                }
                prompts[id, default: []].append(i)
            } else if message.role == "User" {
                let reply = parse(message.text) { item, question, single in
                    // Codex gives the displayed prompt the call ID. All items from one call share that row.
                    let matches = prompts[item.call, default: []].filter { rows[$0].message.text.contains(question) }
                    guard matches.count == 1, let index = matches.first else { return .embedded }
                    let prompt = rows[index]
                    if single, item.index == 0, index == i - 1, prompt.toolCount == 0, rows[i].dayHeading == nil,
                       prompt.message.text.hasPrefix(question),
                       prompt.message.text.dropFirst(question.count).split(separator: "\n").allSatisfy({ $0.hasPrefix("- ") }) {
                        return .adjacent
                    }
                    return .earlier(prompt.id)
                }
                rows[i].questionReply = reply
            }
        }
    }

    private static func parse(_ text: String, locate: (ItemID, String, Bool) -> Reference) -> Self? {
        let open = "<send_user_message_question_reply>", close = "</send_user_message_question_reply>"
        let start = text.drop(while: \.isWhitespace)
        guard start.hasPrefix(open) else { return nil }
        let body = start.dropFirst(open.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasSuffix(close) else { return .unrecognized }
        let decoder = JSONDecoder()
        guard let entries = try? decoder.decode([Entry].self, from: Data(body.dropLast(close.count).utf8)),
              !entries.isEmpty, entries.allSatisfy({ !$0.question.allSatisfy(\.isWhitespace) && !$0.answer.allSatisfy(\.isWhitespace) })
        else { return .unrecognized }

        var seen = Set<ItemID>()
        var answers: [Answer] = []
        for entry in entries {
            var reference = Reference.embedded
            if let rawID = entry.questionItemId, let id = try? decoder.decode(ItemID.self, from: Data(rawID.utf8)) {
                guard seen.insert(id).inserted else { return .unrecognized }
                reference = locate(id, entry.question, entries.count == 1)
            }
            answers.append(Answer(question: entry.question, answer: entry.answer, reference: reference))
        }
        return .answers(answers)
    }
}

struct CodexQuestionAnswers: View {
    let answers: [CodexQuestionReply.Answer]
    let jumpToQuestion: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(answers.indices, id: \.self) { index in
                let item = answers[index]
                VStack(alignment: .leading, spacing: 5) {
                    switch item.reference {
                    case .adjacent:
                        EmptyView()
                    case .earlier(let id):
                        Button { jumpToQuestion(id) } label: {
                            Self.quote(item.question, icon: "arrow.turn.up.left")
                        }
                        .buttonStyle(.plain).help("Go to original question")
                        .accessibilityLabel("Go to question: \(item.question)")
                    case .embedded:
                        EmbeddedQuestion(question: item.question)
                    }
                    Text(verbatim: item.answer).textSelection(.enabled)
                }
            }
        }
    }

    private struct EmbeddedQuestion: View {
        let question: String
        @State private var expanded = false

        var body: some View {
            Button { expanded.toggle() } label: {
                CodexQuestionAnswers.quote(question, icon: expanded ? "chevron.up" : "chevron.down", expanded: expanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") question: \(question)")
        }
    }

    private static func quote(_ text: String, icon: String, expanded: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: text).lineLimit(expanded ? nil : 1)
            Image(systemName: icon).font(.caption2).accessibilityHidden(true)
        }
        .font(.callout).foregroundStyle(.white.opacity(0.9)).padding(.leading, 7)
        .overlay(alignment: .leading) { Capsule().fill(.white.opacity(0.6)).frame(width: 2) }
        .contentShape(Rectangle())
    }
}

struct OriginalMessageButton: View {
    let original: String
    @State private var showingOriginal = false

    var body: some View {
        Button { showingOriginal = true } label: {
            Image(systemName: "doc.plaintext")
        }
        .buttonStyle(.plain).accessibilityLabel("Show original").help("Show original")
        .sheet(isPresented: $showingOriginal) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Original message").font(.headline)
                ScrollView {
                    Text(verbatim: original).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Done") { showingOriginal = false }
                    .keyboardShortcut(.defaultAction).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.body).foregroundStyle(.primary).padding(20).frame(width: 480, height: 280)
        }
    }
}
