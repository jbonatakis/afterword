import SwiftUI
import RecorderCore

struct GitHubLibraryLinks {
    var items: [String: String] = [:]
    var open: (String) -> Void = { _ in }
}
private struct GitHubLinksKey: EnvironmentKey { static let defaultValue = GitHubLibraryLinks() }
extension EnvironmentValues {
    var githubLibraryLinks: GitHubLibraryLinks {
        get { self[GitHubLinksKey.self] }
        set { self[GitHubLinksKey.self] = newValue }
    }
}

/// Native, selectable Markdown with block spacing. No HTML or remote resources are loaded.
struct MarkdownContent: View {
    let markdown: String
    var fillsWidth = true
    @Environment(\.githubLibraryLinks) private var githubLinks
    private struct Block: Identifiable {
        let id: Int
        let kind: String
        let text: String
        var rows: [[String]] = []
    }
    private var blocks: [Block] {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [Block] = [], paragraph: [String] = [], code: [String] = [], index = 0
        var fence: Substring?
        func append(_ kind: String, _ text: String, rows: [[String]] = []) { result.append(.init(id: result.count, kind: kind, text: text, rows: rows)) }
        func flush() { if !paragraph.isEmpty { append("text", paragraph.joined(separator: " ")); paragraph = [] } }
        func cells(_ line: String) -> [String] { line.trimmingCharacters(in: CharacterSet(charactersIn: " |\t")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            let marker = line.first
            let run = line.prefix(while: { $0 == marker })
            if let opening = fence {
                if marker == opening.first, run.count >= opening.count, run.endIndex == line.endIndex {
                    append("code", code.joined(separator: "\n"))
                    code.removeAll(keepingCapacity: true)
                    fence = nil
                } else {
                    code.append(lines[index - 1])
                }
                continue
            }
            if (marker == "`" || marker == "~"), run.count >= 3,
               marker != "`" || !line[run.endIndex...].contains("`") {
                flush(); fence = run; continue
            }
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
                case "bullet": HStack(alignment: .top, spacing: 9) { Text("•"); inline(block.text).frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading) }
                case "quote":
                    inline(block.text).foregroundStyle(.secondary).padding(.leading, 11)
                        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
                case "code": Text(verbatim: block.text).font(.system(.callout, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4))
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
                default: inline(block.text).frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
                }
            }
            if !githubLinks.items.isEmpty {
                ForEach(GitHubReference.qualified(in: markdown), id: \.self) { reference in
                    if let id = githubLinks.items[reference] {
                        Button {
                            githubLinks.open(id)
                        } label: {
                            Label(reference, systemImage: "arrow.triangle.branch")
                        }
                        .buttonStyle(.link).help("Open in Afterword")
                    }
                }
            }
        }.font(.body).lineSpacing(4).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
    }
}
