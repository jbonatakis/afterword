import SwiftUI
import AppKit
import RecorderCore

struct AgentAccessSettings: View {
    @ObservedObject var library: RecordingLibraryModel
    @State private var configuration = AgentAccessConfiguration()
    @State private var error: String?
    @State private var loaded = false
    private var server: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AfterwordMCP").path }
    private var folders: [String] { Array(Set(library.roots.map(\.path) + configuration.folders)).sorted() }

    var body: some View {
        Form {
            Section {
                Toggle("Enable agent access", isOn: Binding(get: { configuration.enabled }, set: { enabled in
                    var next = configuration; next.enabled = enabled; save(next)
                }))
                Text("Let MCP clients read the saved activity you choose to share.")
                    .font(.caption).foregroundStyle(.secondary)
                if library.sources.contains(.board) {
                    Toggle("Allow agents to manage the task board", isOn: Binding(get: { configuration.allowBoardManagement }, set: { allowed in
                        var next = configuration
                        next.allowBoardManagement = allowed
                        save(next)
                    })).disabled(!configuration.enabled)
                    Text("Agents can manage all tickets, columns, and swimlanes. Ticket titles and notes are shared. Agents see citations only from sources you share with them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if library.sources.contains(.coding) {
                    Toggle("Share imported coding sessions", isOn: Binding(get: { configuration.allowCodingSessions }, set: { allowed in
                        var next = configuration; next.allowCodingSessions = allowed; save(next)
                    })).disabled(!configuration.enabled)
                    Text("Includes saved prompts, replies, project paths, and tool names from imported projects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if library.sources.contains(.recordings) {
                    Toggle("Allow agents to access personal calls", isOn: Binding(get: { configuration.allowPersonalCalls }, set: { allowed in
                        var next = configuration; next.allowPersonalCalls = allowed; save(next)
                    })).disabled(!configuration.enabled)
                    Text("Agents can explicitly request personal calls in allowed folders. Everyday searches still use work activity.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow agents to save summaries", isOn: Binding(get: { configuration.allowSummaryWrites }, set: { allowed in
                        var next = configuration; next.allowSummaryWrites = allowed; save(next)
                    })).disabled(!configuration.enabled)
                    Text("Agents can create and update summaries in allowed folders. Previous versions are kept, and newer edits are protected from being overwritten.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if library.sources.contains(.github) { GitHubGrantSettings(github: library.github, enabled: configuration.enabled) }
            if library.sources.contains(.recordings) {
                Section("Allowed recording folders") {
                    if folders.isEmpty { Text("Add a recording folder to the library first.").foregroundStyle(.secondary) }
                    ForEach(folders, id: \.self) { path in
                        Toggle(isOn: Binding(get: { configuration.folders.contains(path) }, set: { allowed in
                            var next = configuration
                            if allowed { next.folders.append(path) } else { next.folders.removeAll { $0 == path } }
                            save(next)
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    if configuration.enabled && configuration.folders.isEmpty {
                        Text("No calls are accessible until you select a folder.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("MCP server") {
                LabeledContent("Transport", value: "stdio")
                Text(server).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Copy Server Path") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(server, forType: .string)
                }
                Text("Clients launch this executable with no arguments. The server works while Afterword is closed. Access changes apply to subsequent requests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Your connected client controls which model receives retrieved text, including whether it uses a cloud service.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .disabled(!loaded)
        .onAppear {
            do { configuration = try AgentAccessStore.load(); loaded = true; error = nil }
            catch { self.error = "Agent access settings could not be loaded: \(error.localizedDescription)" }
        }
    }
    private func save(_ next: AgentAccessConfiguration) {
        do { try AgentAccessStore.save(next); configuration = try AgentAccessStore.load(); error = nil }
        catch { self.error = "Agent access settings could not be saved: \(error.localizedDescription)" }
    }
}
