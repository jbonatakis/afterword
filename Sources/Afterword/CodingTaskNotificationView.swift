import SwiftUI
import RecorderCore

struct CodingTaskReport: Sendable {
    struct Finding: Decodable, Sendable {
        let file, summary: String
        let line: Int?
        let severity, failureScenario: String?
    }

    let notification: CodingTaskNotification
    let findings: [Finding]

    init(_ notification: CodingTaskNotification) {
        self.notification = notification
        guard var result = notification.result?[...] else { findings = []; return }
        if let firstLine = result.firstIndex(of: "\n"), result[..<firstLine].trimmingCharacters(in: .whitespacesAndNewlines) == "```json",
           result.hasSuffix("```") {
            result = result[result.index(after: firstLine)...].dropLast(3)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        findings = (try? decoder.decode([Finding].self, from: Data(result.utf8))) ?? []
    }

    var title: String {
        let name = findings.isEmpty ? "Background task" : "Background review"
        let heading = notification.status.map { "\(name) \($0)" } ?? name
        guard !findings.isEmpty else { return heading }
        return "\(heading) · \(findings.count) \(findings.count == 1 ? "finding" : "findings")"
    }

    var needsAttention: Bool {
        ["failed", "error", "interrupted", "stopped", "killed", "cancelled", "canceled"].contains(notification.status?.lowercased() ?? "")
    }
}

struct CodingTaskNotificationView: View {
    let report: CodingTaskReport
    let message: CodingMessage
    let recorded: Bool
    let matched: Bool
    @State private var expanded = false

    var body: some View {
        let notice = report.notification
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).frame(width: 10)
                        Label(report.title, systemImage: report.needsAttention ? "exclamationmark.circle" : "list.bullet.rectangle")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).font(.callout.weight(.medium))
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if let date = message.timestamp {
                    Text(date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                if recorded { OriginalMessageButton(original: message.text) }
            }
            if !expanded, report.needsAttention, let reason = notice.result ?? notice.summary {
                Text(verbatim: reason).lineLimit(2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if expanded {
                if let summary = notice.summary {
                    Text(verbatim: summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !report.findings.isEmpty {
                    ForEach(report.findings.indices, id: \.self) { index in
                        let finding = report.findings[index]
                        VStack(alignment: .leading, spacing: 4) {
                            let location = finding.file + (finding.line.map { ":\($0)" } ?? "")
                            Text(verbatim: [location, finding.severity].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Text(verbatim: finding.summary)
                            if let scenario = finding.failureScenario { Text(verbatim: scenario).foregroundStyle(.secondary) }
                        }
                        .textSelection(.enabled).padding(.vertical, 4)
                    }
                } else if let result = notice.result {
                    MarkdownContent(markdown: result, fillsWidth: false)
                } else if notice.summary == nil && notice.status == nil {
                    Text(verbatim: message.text).textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if matched { Capsule().fill(Color.accentColor).frame(width: 2) }
        }
        .padding(.top, 12)
        .onChange(of: matched, initial: true) { _, selected in if selected { expanded = true } }
    }
}
