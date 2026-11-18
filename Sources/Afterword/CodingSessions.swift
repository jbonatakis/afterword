import SwiftUI
import RecorderCore

private struct CodingSnapshot {
    let settings: CodingImportSettings?
    let available: [String]
    let accounts: [LocalCodexAccount]
    let sessions: [CodingSession]
    let issue: String?
}

private actor CodingImportWorker {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func refresh(change: CodingCoordinator.Change?, discover: Bool) throws -> CodingSnapshot {
        if change == nil && !CodingArchive.exists(in: directory) {
            return .init(settings: nil, available: [], accounts: [], sessions: [], issue: nil)
        }
        let archive = try CodingArchive(directory: directory)
        switch change {
        case .enabled(let provider, let value): try archive.setEnabled(value, for: provider)
        case .account(let selection): try archive.setCodexAccount(selection)
        case .folder(let path, let included): try archive.setProjectFolder(path, included: included)
        case nil: break
        }
        let result = try archive.refresh(discoverProjects: discover)
        return try .init(settings: archive.settings(), available: result.projects, accounts: result.accounts, sessions: archive.sessions(),
                         issue: result.issues.isEmpty ? nil : result.issues.joined(separator: "\n"))
    }
}

@MainActor final class CodingCoordinator: ObservableObject {
    enum Change: Equatable { case enabled(CodingProvider, Bool), account(CodexAccountSelection), folder(String, Bool) }
    let directory: URL
    private let worker: CodingImportWorker
    @Published private(set) var providers: Set<CodingProvider> = []
    @Published private(set) var codexAccount = CodexAccountSelection.automatic
    @Published private(set) var accounts: [LocalCodexAccount] = []
    var enabled: Bool { !providers.isEmpty }
    @Published private(set) var selection = CodingProjectSelection()
    @Published private(set) var projects: [String] = []
    @Published private(set) var available: [String] = []
    @Published private(set) var sessions: [CodingSession] = []
    @Published private(set) var busy = false
    @Published private(set) var issue: String?
    var changed: (() -> Void)?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var wantsDiscovery = false
    private var pendingChanges: [Change] = []

    init(directory: URL) {
        self.directory = directory
        worker = CodingImportWorker(directory: directory)
    }
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.enabled == true { self?.refresh() } }
        }
    }
    func stop() { timer?.invalidate(); task?.cancel() }
    func refresh(_ change: Change? = nil, discover: Bool = false) {
        guard !busy else {
            if let change { pendingChanges.append(change) }
            wantsDiscovery = wantsDiscovery || discover
            return
        }
        busy = true
        task = Task(priority: .utility) {
            do {
                let next = try await worker.refresh(change: change, discover: discover)
                guard !Task.isCancelled else { return }
                let nextProviders = next.settings?.providers ?? []
                let rules = next.settings?.projectSelection ?? CodingProjectSelection()
                let nextProjects = Set(next.sessions.map(\.project)).union(rules.exact).sorted()
                if selection != rules { selection = rules }
                let updated = sessions != next.sessions || projects != nextProjects || providers != nextProviders
                providers = nextProviders; projects = nextProjects; sessions = next.sessions; issue = next.issue
                codexAccount = next.settings?.codexAccount ?? .automatic
                if discover || !rules.folders.isEmpty || !projects.isEmpty || !providers.contains(.codex) { accounts = next.accounts }
                if discover || !enabled { available = next.available }
                if updated { changed?() }
            } catch { issue = error.localizedDescription }
            busy = false
            if !pendingChanges.isEmpty || wantsDiscovery {
                let next = pendingChanges.isEmpty ? nil : pendingChanges.removeFirst()
                let discover = wantsDiscovery
                wantsDiscovery = false; refresh(next, discover: discover)
            }
        }
    }
}

struct CodingSettingsView: View {
    @ObservedObject var coding: CodingCoordinator
    @State private var removing: String?
    private var folders: [CodingProjectFolder] {
        let paths = Set(coding.available + coding.projects).union(coding.selection.folders.keys)
        return CodingProjectFolder.tree(paths: paths)
    }
    var body: some View {
        Form {
            Section {
                ForEach(CodingProvider.allCases, id: \.self) { provider in
                    Toggle("Import \(provider.name) sessions", isOn: Binding(get: { coding.providers.contains(provider) },
                        set: { coding.refresh(.enabled(provider, $0), discover: true) }))
                }
                if coding.providers.contains(.codex), !coding.accounts.isEmpty || coding.codexAccount != .automatic {
                    Picker("Codex account", selection: Binding(get: { coding.codexAccount }, set: { coding.refresh(.account($0), discover: true) })) {
                        Text(coding.accounts.count > 1 ? "Choose an account…" : "Use the local account automatically").tag(CodexAccountSelection.automatic)
                        ForEach(coding.accounts) { account in
                            let project = account.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Local account"
                            Text("\(project) · \(account.lastUsed.formatted(date: .abbreviated, time: .omitted)) · \(account.shortID)")
                                .tag(CodexAccountSelection.account(account.id))
                        }
                        if case .account(let saved) = coding.codexAccount, !coding.accounts.contains(where: { $0.id == saved }) {
                            Text("Previously selected account").tag(coding.codexAccount)
                        }
                        Text("Only chats without an account").tag(CodexAccountSelection.unscoped)
                    }
                    if coding.accounts.count > 1 && coding.codexAccount == .automatic {
                        Text("Several accounts have chats on this Mac. Choose one by its recent project to include those chats.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Folder selections apply to every enabled source and include future projects beneath each checked folder. Afterword saves prompts, replies, and tool names locally. Pausing a source keeps its saved sessions available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Projects") {
                ForEach(folders) { folder in
                    ProjectFolderRow(folder: folder, selection: coding.selection, importing: coding.enabled, depth: 0) { path, included in
                        if included { coding.refresh(.folder(path, true)) } else { removing = path }
                    }
                }
                if coding.enabled {
                    Button("Refresh projects") { coding.refresh(discover: true) }
                    if folders.isEmpty && !coding.busy {
                        Text("No local sessions with a project directory were found.").foregroundStyle(.secondary)
                    }
                }
            }
            if coding.busy { ProgressView("Checking coding sessions…").controlSize(.small) }
            if let issue = coding.issue { Text(issue).foregroundStyle(.red) }
        }
        .formStyle(.grouped).disabled(coding.busy)
        .onAppear { coding.refresh(discover: true) }
        .confirmationDialog("Remove saved sessions in this folder?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { path in
            Button("Remove folder history", role: .destructive) { coding.refresh(.folder(path, false)) }
            Button("Cancel", role: .cancel) {}
        } message: { path in Text("Afterword will remove its saved sessions for \(path) and its subfolders, and stop importing them.") }
    }
}

private struct ProjectFolderRow: View {
    let folder: CodingProjectFolder
    let selection: CodingProjectSelection
    let importing: Bool
    let depth: Int
    let change: (String, Bool) -> Void
    @State private var expanded: Bool?

    var body: some View {
        let open = expanded ?? (depth < 2)
        let state = selection.state(at: folder.path, hasChildren: !folder.children.isEmpty)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                if folder.children.isEmpty {
                    Color.clear.frame(width: 16, height: 1)
                } else {
                    Button { expanded = !open } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.caption.bold()).frame(width: 16, height: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(open ? "Collapse \(folder.name)" : "Expand \(folder.name)")
                }
                ProjectFolderCheckbox(name: folder.name, path: folder.path, state: state) {
                    change(folder.path, importing && state != .on)
                }.fixedSize().disabled(!importing && state == .off)
                    .contextMenu {
                        if importing && state != .on { Button("Include folder and subfolders") { change(folder.path, true) } }
                        if state != .off { Button("Remove folder history…", role: .destructive) { change(folder.path, false) } }
                    }
            }
            if open {
                ForEach(folder.children) { child in
                    ProjectFolderRow(folder: child, selection: selection, importing: importing, depth: depth + 1, change: change)
                }.padding(.leading, 18)
            }
        }
    }
}

/// AppKit exposes a checkbox's mixed state to both keyboard users and VoiceOver.
private struct ProjectFolderCheckbox: NSViewRepresentable {
    let name, path: String
    let state: CodingProjectSelection.State
    let toggle: () -> Void

    final class Coordinator: NSObject {
        var toggle: () -> Void
        var state: NSControl.StateValue = .off
        init(_ toggle: @escaping () -> Void) { self.toggle = toggle }
        @objc func click(_ sender: NSButton) {
            sender.state = state
            toggle()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(toggle) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: name, target: context.coordinator, action: #selector(Coordinator.click(_:)))
        button.allowsMixedState = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.toggle = toggle
        button.title = name
        button.toolTip = path
        button.setAccessibilityIdentifier(path)
        button.isEnabled = context.environment.isEnabled
        switch state {
        case .on: button.state = .on
        case .off: button.state = .off
        case .mixed: button.state = .mixed
        }
        context.coordinator.state = button.state
    }
}

struct CodingSessionDetail: View {
    let session: CodingSession
    let directory: URL
    let hit: CodingHit?
    @State private var history: CodingHistory?
    @State private var recorded = false
    @State private var issue: String?
    @State private var anchor: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.title).font(.title2.bold()).textSelection(.enabled)
            Text([session.providerName, session.project, session.branch].compactMap { $0 }.joined(separator: "  ·  "))
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Picker("View", selection: $recorded) {
                Text("Conversation").tag(false)
                Text("Recorded history").tag(true)
            }.pickerStyle(.segmented).fixedSize()
            Divider()
            if let history {
                let messages = recorded ? history.messages : history.conversation
                if messages.isEmpty {
                    ContentUnavailableView("No saved messages", systemImage: "text.bubble")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(messages) { message in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(message.role == "User" ? "You" : message.role).font(.headline)
                                            if let date = message.timestamp { Text(date.formatted()).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        if !message.text.isEmpty { MarkdownContent(markdown: message.text) }
                                        if !message.tools.isEmpty {
                                            DisclosureGroup("\(message.tools.count) tool call\(message.tools.count == 1 ? "" : "s")") {
                                                Text(message.tools.joined(separator: ", ")).font(.caption).textSelection(.enabled)
                                            }.fixedSize(horizontal: false, vertical: true)
                                        }
                                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(message.id == anchor ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .id(message.id)
                                }
                            }
                        }
                        .task(id: anchor) { if let anchor { await Task.yield(); proxy.scrollTo(anchor, anchor: .top) } }
                    }
                }
            } else if let issue { Text(issue).foregroundStyle(.red) } else { ProgressView() }
            Spacer(minLength: 0)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: session.updated) {
            let id = session.id
            let result = await Task.detached(priority: .userInitiated) { Result { try CodingArchive(directory: directory).history(id: id) } }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let value): history = value; issue = nil
            case .failure(let error): history = nil; issue = error.localizedDescription
            }
        }
        .onChange(of: hit?.messageID, initial: true) { _, id in
            if let hit { recorded = hit.archived }
            anchor = id
        }
    }
}
