import Foundation

/// The block-level Markdown supported by Afterword. Inline markup stays in the text.
public enum MarkdownBlock: Equatable {
    case text(String)
    case heading(String)
    case listItem(marker: String, depth: Int, text: String)
    case quote(String)
    case code(String)
    case rule
    case table([[String]])

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: Substring?
        var listColumns: [Int] = []
        var index = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.text(paragraph.joined(separator: " ")))
                paragraph.removeAll(keepingCapacity: true)
            }
        }

        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            let marker = line.first
            let run = line.prefix(while: { $0 == marker })
            if let opening = fence {
                if marker == opening.first, run.count >= opening.count, run.endIndex == line.endIndex {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code.removeAll(keepingCapacity: true)
                    fence = nil
                } else {
                    code.append(raw)
                }
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }

            // Only items farther left can be parents. A blank line can separate siblings.
            let column = indentation(of: raw)
            while let last = listColumns.last, last >= column {
                listColumns.removeLast()
            }

            if (marker == "`" || marker == "~"), run.count >= 3,
               marker != "`" || !line[run.endIndex...].contains("`") {
                flushParagraph()
                fence = run
                continue
            }
            if line.contains("|"), index < lines.count {
                let separator = cells(lines[index])
                if separator.count > 1 && separator.allSatisfy({ $0.contains("---") && $0.allSatisfy { "-: ".contains($0) } }) {
                    flushParagraph()
                    var rows = [cells(line)]
                    index += 1
                    while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        rows.append(cells(lines[index]))
                        index += 1
                    }
                    blocks.append(.table(rows))
                    continue
                }
            }
            if line.hasPrefix("#"), let space = line.firstIndex(of: " "), line[..<space].allSatisfy({ $0 == "#" }) {
                flushParagraph()
                blocks.append(.heading(String(line[line.index(after: space)...])))
            } else if line == "---" || line == "***" {
                flushParagraph()
                blocks.append(.rule)
            } else if let item = listItemParts(line) {
                flushParagraph()
                blocks.append(.listItem(marker: item.marker, depth: listColumns.count, text: item.text))
                listColumns.append(column)
            } else if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        if !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    private static func indentation(of line: String) -> Int {
        var column = 0
        for character in line {
            switch character {
            case " ": column += 1
            case "\t": column += 4 - column % 4
            default: return column
            }
        }
        return column
    }

    private static func listItemParts(_ line: String) -> (marker: String, text: String)? {
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let prefix = line[..<space]
        let marker: String
        switch prefix {
        case "-", "*", "+": marker = "•"
        default:
            let digits = prefix.dropLast()
            guard prefix.last == "." || prefix.last == ")", (1...9).contains(digits.count),
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            marker = String(prefix)
        }
        let text = line[space...].drop(while: { $0 == " " || $0 == "\t" })
        return (marker, String(text))
    }

    private static func cells(_ line: String) -> [String] {
        line.trimmingCharacters(in: CharacterSet(charactersIn: " |\t"))
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
