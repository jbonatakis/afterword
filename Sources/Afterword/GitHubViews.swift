import RecorderCore
import SwiftUI

struct GitHubSettingsView: View {
    @ObservedObject var github: GitHubCoordinator
    @AppStorage("githubPublicClientID") private var customID = ""
    @State private var remove: GitHubSelection?
    @State private var disconnect = false
    @State private var repositorySearch = ""
    private var bundledID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "AfterwordGitHubClientID") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    private var clientID: String { (bundledID ?? customID).trimmingCharacters(in: .whitespacesAndNewlines) }
    private var remaining: [GitHubRepository] {
        let selected = Set(github.snapshot.selections.map(\.id))
        return github.snapshot.available.filter {
            !selected.contains($0.id) && (repositorySearch.isEmpty || $0.name.localizedCaseInsensitiveContains(repositorySearch))
        }
    }
    var body: some View {
        Form {
            Section("GitHub.com account") {
                if let viewer = github.snapshot.account { LabeledContent("Connected account", value: viewer.login) }
                if let code = github.deviceCode {
                    LabeledContent("Device code") { Text(code).monospaced().textSelection(.enabled) }
                    HStack {
                        Button("Copy code and open GitHub") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            NSWorkspace.shared.open(URL(string: "https://github.com/login/device")!)
                        }
                        Button("Cancel") { github.cancel() }
                    }
                } else if github.snapshot.account == nil || github.snapshot.locked {
                    if bundledID == nil {
                        TextField("GitHub App client ID", text: $customID)
                        if clientID.isEmpty {
                            Link(
                                "Register a read-only GitHub App",
                                destination: URL(
                                    string:
                                        "https://github.com/settings/apps/new?name=Afterword%20History&url=https%3A%2F%2Fgithub.com%2Fjbonatakis%2Fafterword&issues=read&pull_requests=read&webhook_active=false&public=true"
                                )!)
                            Text("Enable device flow and expiring user tokens, then install the app on your selected repositories.")
                                .font(.caption)
                        } else {
                            Link("Manage GitHub App registrations", destination: URL(string: "https://github.com/settings/apps")!)
                        }
                    }
                    if github.snapshot.locked { Text("History is locked. Reconnect the same GitHub account to verify access.") }
                    Button(github.snapshot.locked ? "Reconnect GitHub" : "Connect GitHub") { github.connect(clientID: clientID) }
                        .disabled(clientID.isEmpty || github.busy)
                }
                if github.snapshot.account != nil {
                    HStack {
                        Button("Refresh") { github.refresh() }.disabled(github.busy || github.snapshot.locked)
                        Button("Disconnect and remove history…", role: .destructive) { disconnect = true }
                    }
                }
                if github.busy { ProgressView().controlSize(.small) }
                if let message = github.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if github.snapshot.account != nil && !github.snapshot.locked {
                Section("Imported repositories") {
                    if github.snapshot.selections.isEmpty {
                        Text("Choose a repository below to import your contributions from the last 90 days.")
                    }
                    ForEach(github.snapshot.selections) { selection in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(selection.repo.name).font(.headline)
                            Text(
                                selection.paused
                                    ? "Paused · \(selection.queued) pages queued"
                                    : "\(selection.status) · \(selection.queued) pages queued"
                            ).font(.caption)
                            if let success = selection.lastSuccess { Text("Last synced \(success.formatted())").font(.caption) }
                            if let checked = selection.checked { Text("Access checked \(checked.formatted())").font(.caption) }
                            Picker(
                                "Import depth",
                                selection: Binding(get: { selection.allHistory }, set: { github.change(.depth(selection.id, $0)) })
                            ) {
                                Text("Last 90 days").tag(false)
                                Text("All my available history").tag(true)
                            }
                            Toggle(
                                "Share this repository through MCP",
                                isOn: Binding(get: { selection.shared }, set: { github.change(.share(selection.id, $0)) }))
                            HStack {
                                Button(selection.paused ? "Resume sync" : "Pause sync") {
                                    github.change(.pause(selection.id, !selection.paused))
                                }
                                Button("Remove…", role: .destructive) { remove = selection }
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Section("Available repositories") {
                    Link("Manage GitHub App installations", destination: URL(string: "https://github.com/settings/installations")!)
                    TextField("Filter repositories", text: $repositorySearch)
                    ForEach(remaining) { repo in
                        HStack {
                            Text(repo.name)
                            Spacer()
                            Button("Import") { github.change(.select(repo)) }
                        }
                    }
                    if remaining.isEmpty { Text("No matching repositories available to add.").foregroundStyle(.secondary) }
                }
            }
        }.formStyle(.grouped)
            .alert("Disconnect GitHub and remove local history?", isPresented: $disconnect) {
                Button("Disconnect and remove", role: .destructive) { github.disconnect() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes saved GitHub contributions, repository grants and the account credentials from this Mac.")
            }
            .alert(
                "Remove repository?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }),
                presenting: remove
            ) { selection in
                Button("Remove", role: .destructive) {
                    github.change(.remove(selection.id))
                    remove = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove \($0.repo.name) from local history and revoke agent access?")
            }
    }
}

struct GitHubItemView: View {
    let hit: GitHubHit
    let directory: URL
    let revision: String
    @State private var actions: [GitHubPassage] = []
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(hit.item.title).font(.title2.bold()).textSelection(.enabled)
                Text(
                    "\(hit.repository)#\(hit.item.number) · \(hit.item.type == "pr" ? "Pull request" : "Issue") opened by \(hit.item.author) · \(hit.item.state.capitalized)"
                )
                if let url = URL(string: hit.item.url) { Link("Open on GitHub", destination: url) }
                if let date = hit.verified { Text("Access checked \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error) }
                ForEach(actions) { action in
                    Divider()
                    HStack {
                        Text(
                            [action.kind.label, action.verdict?.replacingOccurrences(of: "_", with: " ").capitalized].compactMap { $0 }
                                .joined(separator: " · ")
                        ).bold()
                        Spacer()
                        if let url = URL(string: action.url) { Link(action.date.formatted(), destination: url) }
                    }
                    if let path = action.path {
                        Text(path + (action.line.map { ":\($0)" } ?? "")).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if !action.text.isEmpty { MarkdownContent(markdown: action.text) }
                    if let date = action.edited { Text("Edited \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.task(id: revision + hit.id) {
            let id = hit.id
            let directory = directory
            do {
                let next = try await Task.detached(priority: .userInitiated) {
                    try GitHubArchive(directory: directory).timeline(id, shared: false)
                }.value
                if !Task.isCancelled {
                    actions = next
                    error = nil
                }
            } catch {
                if !Task.isCancelled {
                    actions = []
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

struct GitHubGrantSettings: View {
    @ObservedObject var github: GitHubCoordinator
    let enabled: Bool
    var body: some View {
        Section("Shared GitHub repositories") {
            if github.snapshot.locked {
                Text("Reconnect GitHub to verify repository access.")
            } else if github.snapshot.selections.isEmpty {
                Text("Choose repositories in GitHub settings to make them available here.").foregroundStyle(.secondary)
            } else {
                ForEach(github.snapshot.selections) { repo in
                    Toggle(repo.repo.name, isOn: Binding(get: { repo.shared }, set: { github.change(.share(repo.id, $0)) })).disabled(
                        !enabled)
                }
            }
        }
    }
}
