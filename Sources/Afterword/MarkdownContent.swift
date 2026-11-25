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

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
    var body: some View {
        let blocks = MarkdownBlock.parse(markdown)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .heading(let text): inline(text).font(.headline).padding(.top, 6)
                case let .listItem(marker, depth, text):
                    HStack(alignment: .top, spacing: 9) {
                        Text(verbatim: marker).fixedSize()
                        inline(text).frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(depth) * 16)
                case .quote(let text):
                    inline(text).foregroundStyle(.secondary).padding(.leading, 11)
                        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
                case .code(let text): Text(verbatim: text).font(.system(.callout, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4))
                case .rule: Divider()
                case .table(let rows):
                    VStack(spacing: 0) {
                        ForEach(rows.indices, id: \.self) { row in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(rows[row].indices, id: \.self) { column in
                                    inline(rows[row][column]).fontWeight(row == 0 ? .semibold : .regular).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(8)
                            Divider()
                        }
                    }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                case .text(let text): inline(text).frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
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
