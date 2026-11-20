import SwiftUI
import RecorderCore

struct ProjectFolderChanges: Equatable {
    let original, selection: CodingProjectSelection
}

private struct CodingSnapshot {
    let settings: CodingImportSettings?
    let folders: [CodingProjectFolder]
    let projects: [String]
    let accounts: [LocalCodexAccount]
    let branches: [String]
    let revision: String
    let issue: String?
}

private actor CodingImportWorker {
    let directory: URL
    private var available: [String] = []
    init(directory: URL) { self.directory = directory }

    func refresh(change: CodingCoordinator.Change?, discover: Bool) throws -> CodingSnapshot {
        try Task.checkCancellation()
        if change == nil && !CodingArchive.exists(in: directory) {
            available = []
            return .init(settings: nil, folders: [], projects: [], accounts: [], branches: [], revision: "", issue: nil)
        }
        let archive = try CodingArchive(directory: directory)
        var issues: [String] = []
        switch change {
        case .enabled(let provider, let value): try archive.setEnabled(value, for: provider)
        case .account(let selection): try archive.setCodexAccount(selection)
        case .folders(let changes):
            do { try archive.applyProjectSelection(changes.selection, replacing: changes.original) }
            catch { issues.append(error.localizedDescription) }
        case nil: break
        }
        let result = try archive.refresh(discoverProjects: discover)
        issues += result.issues
        let settings = try archive.settings()
        let projects = try Set(archive.sessionProjects()).union(settings.projectSelection.exact)
        if discover || settings.providers.isEmpty { available = result.projects }
        let paths = projects.union(available).union(settings.projectSelection.folders.keys)
        return try .init(settings: settings, folders: CodingProjectFolder.tree(paths: paths), projects: projects.sorted(),
                     accounts: result.accounts, branches: archive.sessionBranches(), revision: archive.revision,
                     issue: issues.isEmpty ? nil : issues.joined(separator: "\n"))
    }
}

@MainActor final class CodingCoordinator: ObservableObject {
    enum Change: Equatable {
        case enabled(CodingProvider, Bool), account(CodexAccountSelection)
        case folders(ProjectFolderChanges)

        var folderSelection: CodingProjectSelection? {
            if case .folders(let changes) = self { return changes.selection }
            return nil
        }
    }
    let directory: URL
    private let worker: CodingImportWorker
    @Published private(set) var providers: Set<CodingProvider> = []
    @Published private(set) var codexAccount = CodexAccountSelection.automatic
    @Published private(set) var accounts: [LocalCodexAccount] = []
    var enabled: Bool { !providers.isEmpty }
    @Published private var selection = CodingProjectSelection()
    var effectiveSelection: CodingProjectSelection {
        pendingChanges.reversed().lazy.compactMap(\.folderSelection).first ?? activeChange?.folderSelection ?? selection
    }
    @Published private(set) var projects: [String] = []
    @Published private(set) var folders: [CodingProjectFolder] = []
    @Published private(set) var branches: [String] = []
    @Published private(set) var sessions: [CodingSession] = []
    private var cursor: CodingSessionPage.Cursor?
    var hasMore: Bool { cursor != nil }
    private(set) var pageGeneration = UUID()
    private var pageRevision: String?
    private var importRevision: String?
    private var browseFilter = CodingBrowseFilter()
    private var pageTask: Task<Void, Never>?
    var pageChanged: (() -> Void)?
    private static let pageSize = 200
    @Published private(set) var busy = false
    @Published private(set) var issue: String?
    var changed: (() -> Void)?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var wantsDiscovery = false
    @Published private var activeChange: Change?
    @Published private var pendingChanges: [Change] = []

    init(directory: URL) {
        self.directory = directory
        worker = CodingImportWorker(directory: directory)
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.enabled == true { self?.refresh() } }
        }
        loadPage()
        refresh()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        task?.cancel(); task = nil; busy = false
        pageTask?.cancel(); pageTask = nil
        cursor = nil; pageRevision = nil; importRevision = nil; sessions = []
        wantsDiscovery = false; pendingChanges = []; activeChange = nil
    }
    func refresh(_ change: Change? = nil, discover: Bool = false) {
        guard timer != nil else { return }
        guard !busy else {
            if let change { pendingChanges.append(change) }
            wantsDiscovery = wantsDiscovery || discover
            return
        }
        busy = true
        activeChange = change
        task = Task(priority: .utility) {
            do {
                let next = try await worker.refresh(change: change, discover: discover)
                guard !Task.isCancelled else { return }
                let nextProviders = next.settings?.providers ?? []
                let rules = next.settings?.projectSelection ?? CodingProjectSelection()
                if selection != rules { selection = rules }
                let updated = importRevision != next.revision || projects != next.projects || providers != nextProviders
                importRevision = next.revision
                providers = nextProviders; projects = next.projects; folders = next.folders; issue = next.issue
                branches = next.branches
                if next.revision != pageRevision { loadPage() }
                codexAccount = next.settings?.codexAccount ?? .automatic
                if discover || !rules.folders.isEmpty || !projects.isEmpty || !providers.contains(.codex) { accounts = next.accounts }
                if updated { changed?() }
            } catch {
                guard !Task.isCancelled else { return }
                issue = error.localizedDescription
            }
            busy = false
            activeChange = nil
            if !pendingChanges.isEmpty || wantsDiscovery {
                let next = pendingChanges.isEmpty ? nil : pendingChanges.removeFirst()
                let discover = wantsDiscovery
                wantsDiscovery = false; refresh(next, discover: discover)
            }
        }
    }

    func setBrowseFilter(_ filter: CodingBrowseFilter) {
        guard filter != browseFilter else { return }
        browseFilter = filter
        cursor = nil; pageRevision = nil; sessions = []
        pageGeneration = UUID()
        if timer != nil { loadPage() }
    }

    func loadMore() {
        guard timer != nil, cursor != nil, pageTask == nil else { return }
        loadPage(append: true)
    }

    private func loadPage(append: Bool = false) {
        pageTask?.cancel()
        let directory = directory, filter = browseFilter
        let after = append ? cursor : nil, revision = pageRevision
        let size = Self.pageSize
        let loaded = sessions.count
        pageTask = Task {
            let read = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                var page = try CodingArchive.sessionPage(in: directory, filter: filter, after: after,
                                                        limit: append ? size : max(loaded, size))
                let canAppend = append && page.revision == revision
                if append && !canAppend {
                    // Imports can move or delete rows across the cursor. Replace the visible prefix atomically.
                    try Task.checkCancellation()
                    page = try CodingArchive.sessionPage(in: directory, filter: filter, limit: loaded + size)
                }
                return (page, canAppend)
            }
            do {
                let (page, canAppend) = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
                guard !Task.isCancelled else { return }
                pageTask = nil
                cursor = page.next
                pageRevision = page.revision
                if canAppend { sessions.append(contentsOf: page.sessions) } else { sessions = page.sessions }
                pageGeneration = UUID()
                pageChanged?()
            } catch {
                guard !Task.isCancelled else { return }
                pageTask = nil; pageRevision = nil; issue = error.localizedDescription
            }
        }
    }

}

struct CodingSettingsView: View {
    @ObservedObject var coding: CodingCoordinator
    @State private var draft: ProjectFolderChanges?
    @State private var confirmingRemoval = false

    var body: some View {
        let selection = draft?.selection ?? coding.effectiveSelection
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
            }.disabled(coding.busy)
            Section("Projects") {
                ForEach(coding.folders) { folder in
                    ProjectFolderRow(folder: folder, selection: selection, importing: coding.enabled, depth: 0) { path, included in
                        let original = draft?.original ?? coding.effectiveSelection
                        let next = selection.settingFolder(path, included: included)
                        draft = next == original ? nil : ProjectFolderChanges(original: original, selection: next)
                    }
                }
                if coding.enabled {
                    Button("Refresh projects") { coding.refresh(discover: true) }.disabled(coding.busy)
                    if coding.folders.isEmpty && !coding.busy {
                        Text("No local sessions with a project directory were found.").foregroundStyle(.secondary)
                    }
                }
            }
            if let issue = coding.issue { Text(issue).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            if coding.busy || draft != nil {
                HStack {
                    if coding.busy { ProgressView("Checking coding sessions…").controlSize(.small) }
                    Spacer()
                    if let changes = draft {
                        Button("Discard") { draft = nil }
                        Button("Apply") {
                            if changes.selection.removesProjects(from: changes.original) { confirmingRemoval = true }
                            else { apply(changes) }
                        }.buttonStyle(.borderedProminent)
                    }
                }.padding().background(.bar)
            }
        }
        .onAppear { coding.refresh(discover: true) }
        .confirmationDialog("Remove saved sessions from excluded folders?", isPresented: $confirmingRemoval, titleVisibility: .visible, presenting: draft) { changes in
            Button("Apply and remove history", role: .destructive) { apply(changes) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Afterword will delete its saved history for projects you deselected and stop importing their sessions.") }
    }

    private func apply(_ changes: ProjectFolderChanges) {
        coding.refresh(.folders(changes))
        draft = nil
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
                        if state != .off { Button("Exclude folder and subfolders") { change(folder.path, false) } }
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
            let result = await Task.detached(priority: .userInitiated) { Result { try CodingArchive.history(in: directory, id: id) } }.value
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
