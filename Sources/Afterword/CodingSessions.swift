import SwiftUI
import RecorderCore

struct ProjectFolderChanges: Equatable, Sendable {
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
    private var available: [CodingProvider: [String]] = [:]
    private var accounts: [LocalCodexAccount] = []
    init(directory: URL) { self.directory = directory }

    func refresh(providers: Set<CodingProvider>, discover: Bool,
                 showProviders: @MainActor @Sendable (Set<CodingProvider>) -> Void) async throws -> CodingSnapshot {
        try Task.checkCancellation()
        if !CodingArchive.exists(in: directory) {
            available = [:]; accounts = []
            return .init(settings: nil, folders: [], projects: [], accounts: [], branches: [], revision: "", issue: nil)
        }
        let archive = try CodingArchive(directory: directory)
        var issues: [String] = []
        let settings = try archive.settings()
        await showProviders(settings.providers)
        available = available.filter { settings.providers.contains($0.key) }
        if !settings.providers.contains(.codex) { accounts = [] }
        for provider in CodingProvider.allCases where providers.contains(provider) && settings.providers.contains(provider) {
            try Task.checkCancellation()
            let result = try archive.refresh(discoverProjects: discover, provider: provider)
            try Task.checkCancellation()
            issues += result.issues
            if discover { available[provider] = result.projects }
            if provider == .codex, discover || !settings.projectSelection.exact.isEmpty || !settings.projectSelection.folders.isEmpty {
                accounts = result.accounts
            }
        }
        try Task.checkCancellation()
        let projects = try Set(archive.sessionProjects()).union(settings.projectSelection.exact)
        let paths = projects.union(available.values.joined()).union(settings.projectSelection.folders.keys)
        return try .init(settings: settings, folders: CodingProjectFolder.tree(paths: paths), projects: projects.sorted(),
                     accounts: accounts, branches: archive.sessionBranches(), revision: archive.revision,
                     issue: issues.isEmpty ? nil : issues.joined(separator: "\n"))
    }
}

// Preference writes must be able to finish while a reader is walking transcript files.
private actor CodingSettingsWriter {
    func save(_ change: CodingCoordinator.Change, in directory: URL) throws -> CodingImportSettings {
        try Task.checkCancellation()
        let archive = try CodingArchive(directory: directory)
        switch change {
        case .enabled(let provider, let value): try archive.setEnabled(value, for: provider)
        case .account(let account): try archive.setCodexAccount(account)
        case .piDirectory(let directory): try archive.setPiSessionsDirectory(directory)
        case .folders(let changes): try archive.applyProjectSelection(changes.selection, replacing: changes.original)
        }
        return try archive.settings()
    }
}

@MainActor final class CodingCoordinator: ObservableObject {
    enum Change: Equatable, Sendable {
        case enabled(CodingProvider, Bool), account(CodexAccountSelection)
        case piDirectory(URL?)
        case folders(ProjectFolderChanges)

        var folderSelection: CodingProjectSelection? {
            if case .folders(let changes) = self { return changes.selection }
            return nil
        }
    }
    let directory: URL
    private let worker: CodingImportWorker
    private let writer = CodingSettingsWriter()
    @Published private(set) var providers: Set<CodingProvider> = []
    private var savedProviders: Set<CodingProvider> = []
    @Published private(set) var codexAccount = CodexAccountSelection.automatic
    @Published private(set) var piSessionsDirectory: URL?
    @Published private(set) var accounts: [LocalCodexAccount] = []
    var enabled: Bool { !providers.isEmpty }
    @Published private var selection = CodingProjectSelection()
    var effectiveSelection: CodingProjectSelection {
        pendingChanges.reversed().lazy.compactMap(\.folderSelection).first ?? selection
    }
    @Published private(set) var projects: [String] = []
    @Published private(set) var folders: [CodingProjectFolder] = []
    @Published private(set) var branches: [String] = []
    @Published private(set) var sessions: [CodingSession] = []
    private var cursor: CodingSessionPage.Cursor?
    var hasMore: Bool { cursor != nil }
    private(set) var pageGeneration = UUID()
    private var pageRevision: String?
    private(set) var importRevision: String?
    private var browseFilter = CodingBrowseFilter()
    private var pageTask: Task<Void, Never>?
    var pageChanged: (() -> Void)?
    private static let pageSize = 200
    @Published private var scanning = false
    var busy: Bool { scanning || !pendingChanges.isEmpty }
    var checkingSessions: Bool { scanning && !requestedProviders.isDisjoint(with: providers) }
    @Published private(set) var issue: String?
    var changed: (() -> Void)?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var requestedProviders: Set<CodingProvider> = []
    private var wantsDiscovery = false
    @Published private var pendingChanges: [Change] = []
    private var saveIssue: String?

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
        task?.cancel(); task = nil; scanning = false
        saveTask?.cancel(); saveTask = nil
        pageTask?.cancel(); pageTask = nil
        cursor = nil; pageRevision = nil; importRevision = nil; sessions = []
        savedProviders = []; providers = []
        wantsDiscovery = false; requestedProviders = []; pendingChanges = []; saveIssue = nil
    }
    func refresh(_ change: Change? = nil, discover: Bool = false) {
        guard timer != nil else { return }
        let oldProviders = requestedProviders, oldDiscovery = wantsDiscovery
        switch change {
        case .enabled(let provider, false): requestedProviders.remove(provider)
        case .enabled(let provider, true): requestedProviders.insert(provider); wantsDiscovery = true
        case .account: requestedProviders.insert(.codex); wantsDiscovery = true
        case .piDirectory: requestedProviders.insert(.pi); wantsDiscovery = true
        case .folders, nil:
            requestedProviders.formUnion(CodingProvider.allCases)
            wantsDiscovery = wantsDiscovery || discover
        }
        if let change {
            pendingChanges.append(change)
            updateProviders()
        } else if task != nil && requestedProviders == oldProviders && wantsDiscovery == oldDiscovery {
            return
        }
        // Superseded scans may still be returning from a filesystem read. Only the
        // latest scan can publish, and interrupted providers stay scheduled.
        task?.cancel(); task = nil; scanning = false
        if !pendingChanges.isEmpty {
            savePendingChanges()
        } else {
            scan()
        }
    }

    private func updateProviders() {
        var next = savedProviders
        for case .enabled(let provider, let enabled) in pendingChanges {
            if enabled { next.insert(provider) } else { next.remove(provider) }
        }
        if next != providers { providers = next }
    }

    private func applySettings(_ settings: CodingImportSettings?) {
        savedProviders = settings?.providers ?? []
        updateProviders()
        let rules = settings?.projectSelection ?? CodingProjectSelection()
        if selection != rules { selection = rules }
        let account = settings?.codexAccount ?? .automatic
        if codexAccount != account { codexAccount = account }
        if piSessionsDirectory != settings?.piSessionsDirectory { piSessionsDirectory = settings?.piSessionsDirectory }
    }

    private func savePendingChanges() {
        guard saveTask == nil else { return }
        saveTask = Task {
            while let change = pendingChanges.first {
                do {
                    let settings = try await writer.save(change, in: directory)
                    guard !Task.isCancelled else { return }
                    pendingChanges.removeFirst()
                    applySettings(settings)
                } catch {
                    guard !Task.isCancelled else { return }
                    pendingChanges.removeFirst()
                    updateProviders()
                    saveIssue = error.localizedDescription
                    issue = saveIssue
                }
            }
            saveTask = nil
            scan()
        }
    }

    private func scan() {
        scanning = true
        let targets = requestedProviders, discover = wantsDiscovery
        task = Task(priority: .utility) {
            do {
                let next = try await worker.refresh(providers: targets, discover: discover) { enabled in
                    guard !Task.isCancelled else { return }
                    self.savedProviders = enabled
                    self.updateProviders()
                }
                guard !Task.isCancelled else { return }
                applySettings(next.settings)
                let updated = importRevision != next.revision || projects != next.projects
                importRevision = next.revision
                projects = next.projects; folders = next.folders; branches = next.branches
                accounts = next.accounts; issue = saveIssue ?? next.issue
                if next.revision != pageRevision { loadPage() }
                if updated { changed?() }
            } catch {
                guard !Task.isCancelled else { return }
                issue = error.localizedDescription
            }
            requestedProviders = []; wantsDiscovery = false; saveIssue = nil
            task = nil; scanning = false
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(CodingProvider.allCases, id: \.self) { provider in
                    Toggle(isOn: Binding(get: { coding.providers.contains(provider) },
                                         set: { coding.refresh(.enabled(provider, $0), discover: true) })) {
                        Text("Import \(provider.name) sessions").font(.body).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
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
                if coding.providers.contains(.pi) {
                    HStack {
                        Text("Pi session folder")
                        Text(coding.piSessionsDirectory?.path ?? "Automatic").foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { choosePiDirectory() }
                        if coding.piSessionsDirectory != nil {
                            Button("Use default") { coding.refresh(.piDirectory(nil)) }
                        }
                    }.controlSize(.small)
                }
                Text("Folder selections apply to every enabled source and include future projects beneath each checked folder. Afterword saves prompts, replies, and tool activity locally, including paths, commands, and excerpts from edits, scripts, and test results. Pausing a source keeps its saved sessions available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Projects").font(.headline)
                Spacer()
                if coding.enabled {
                    Button("Refresh projects") { coding.refresh(discover: true) }.disabled(coding.busy)
                }
            }
            if coding.enabled && coding.folders.isEmpty && !coding.busy {
                Text("No local sessions with a project directory were found.").foregroundStyle(.secondary)
            }
            ProjectFolderList(folders: coding.folders, selection: selection, importing: coding.enabled) { path, included in
                let original = draft?.original ?? coding.effectiveSelection
                let next = selection.settingFolder(path, included: included)
                draft = next == original ? nil : ProjectFolderChanges(original: original, selection: next)
            }
            if let issue = coding.issue { Text(issue).foregroundStyle(.red) }
        }
        .padding()
        .safeAreaInset(edge: .bottom) {
            if coding.checkingSessions || draft != nil {
                HStack {
                    if coding.checkingSessions { ProgressView("Checking coding sessions…").controlSize(.small) }
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

    private func choosePiDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Pi session folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = coding.piSessionsDirectory
        if panel.runModal() == .OK, let url = panel.url { coding.refresh(.piDirectory(url)) }
    }
}

private struct ProjectFolderList: View {
    let folders: [CodingProjectFolder]
    let selection: CodingProjectSelection
    let importing: Bool
    let change: (String, Bool) -> Void
    @State private var expanded: [String: Bool] = [:]

    private struct Row: Identifiable {
        let folder: CodingProjectFolder
        let depth: Int
        let open: Bool
        var id: String { folder.path }
    }

    private var rows: [Row] {
        var result: [Row] = []
        func append(_ folders: [CodingProjectFolder], depth: Int) {
            for folder in folders {
                let open = expanded[folder.path] ?? (depth < 2)
                result.append(Row(folder: folder, depth: depth, open: open))
                if open && !folder.children.isEmpty { append(folder.children, depth: depth + 1) }
            }
        }
        append(folders, depth: 0)
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    folderRow(row)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func folderRow(_ row: Row) -> some View {
        let folder = row.folder
        let state = selection.state(at: folder.path, hasChildren: !folder.children.isEmpty)
        return HStack(spacing: 4) {
            if folder.children.isEmpty {
                Color.clear.frame(width: 16, height: 1)
            } else {
                Button { expanded[folder.path] = !row.open } label: {
                    Image(systemName: row.open ? "chevron.down" : "chevron.right")
                        .font(.caption.bold()).frame(width: 16, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.open ? "Collapse \(folder.name)" : "Expand \(folder.name)")
            }
            ProjectFolderCheckbox(name: folder.name, path: folder.path, state: state) {
                change(folder.path, importing && state != .on)
            }.fixedSize().disabled(!importing && state == .off)
                .contextMenu {
                    if importing && state != .on { Button("Include folder and subfolders") { change(folder.path, true) } }
                    if state != .off { Button("Exclude folder and subfolders") { change(folder.path, false) } }
                }
        }.padding(.leading, CGFloat(row.depth) * 18).frame(height: 26)
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

struct CodingToolLocation: Hashable {
    let messageID: String
    let index: Int
    var event: Int? = nil
}

struct CodingToolEntry: Identifiable {
    let call: CodingToolCall
    var date: Date?
    private(set) var lastDate: Date?
    let id: CodingToolLocation
    var locations: [CodingToolLocation]

    var recordedTime: String? {
        guard let date else { return nil }
        let start = date.formatted(date: .omitted, time: .standard)
        guard let lastDate else { return start }
        let end = lastDate.formatted(date: .omitted, time: .standard)
        return start == end ? start : "\(start) – \(end)"
    }

    static func entries(_ messages: [CodingMessage]) -> [Self] {
        var entries: [Self] = []
        for message in messages {
            for (index, call) in message.displayedToolCalls.enumerated() {
                let location = CodingToolLocation(messageID: message.id, index: index)
                if !call.hasDetails, let last = entries.indices.last,
                   !entries[last].call.hasDetails, entries[last].call.name == call.name {
                    entries[last].locations.append(location)
                    if let date = message.timestamp {
                        if entries[last].date == nil { entries[last].date = date }
                        entries[last].lastDate = date
                    }
                } else {
                    entries.append(Self(call: call, date: message.timestamp, id: location, locations: [location]))
                }
            }
        }
        return entries
    }
}

private struct CodingToolGroup {
    let first: CodingToolCall
    var count = 0
    var testOutcomes: [String?] = []
    var events: [CodingToolCall] = []

    static func labels(_ calls: [CodingToolCall], namesOnly: Bool = false) -> [String] {
        var groups: [Self] = [], indices: [String: Int] = [:]
        for call in calls {
            let key = namesOnly || call.action == .other ? "other/" + call.name : call.action.rawValue
            let index = indices[key] ?? groups.count
            if index == groups.count {
                indices[key] = index
                groups.append(Self(first: call))
            }
            groups[index].count += 1
            if let events = call.events { groups[index].events += events }
            if call.action == .test { groups[index].testOutcomes.append(call.testOutcome) }
        }
        return groups.map { group in
            if namesOnly { return group.first.nameLabel(count: group.count) }
            let title = group.first.groupLabel(count: group.count)
            if !group.events.isEmpty { return title + " (reported " + labels(group.events).joined(separator: ", ") + ")" }
            guard group.testOutcomes.contains(where: { $0 != nil }) else { return title }
            return title + " (" + group.testOutcomes.map { $0 ?? "unreported" }.joined(separator: " → ") + ")"
        }
    }
}

/// A display row starts at a message and may include the assistant's following tool-only messages.
struct CodingConversationRow: Identifiable, Sendable {
    struct AssistantThread: Equatable, Sendable {
        let connectsAbove: Bool
        let connectsBelow: Bool
        let isReply: Bool
    }

    let message: CodingMessage
    let hasText: Bool
    let dayHeading: Date?
    let taskReport: CodingTaskReport?
    private(set) var toolMessages: [CodingMessage] = []
    private(set) var toolCount = 0
    private(set) var toolSummary = ""
    private(set) var toolEntries: [CodingToolEntry] = []
    private(set) var hasToolDetails = false
    private(set) var thread: AssistantThread?
    var questionReply: CodexQuestionReply?
    var id: String { message.id }

    static func group(_ messages: [CodingMessage], provider: CodingProvider? = nil) -> [Self] {
        var rows: [Self] = []
        let calendar = Calendar.current
        var previousDay: Date?
        for message in messages {
            let hasText = message.text.contains { !$0.isWhitespace }
            if message.role == "Assistant" && !hasText && message.tools.isEmpty { continue }
            let day = message.timestamp.map { calendar.startOfDay(for: $0) }
            let heading = day != previousDay ? day : nil
            let continuesAssistant = message.role == "Assistant" && !hasText && rows.last?.message.role == "Assistant" && heading == nil
            if !continuesAssistant {
                rows.append(Self(message: message, hasText: hasText, dayHeading: heading,
                                 taskReport: message.taskNotification.map(CodingTaskReport.init)))
            }
            if let day { previousDay = day }
            if !message.tools.isEmpty {
                let index = rows.count - 1
                rows[index].toolMessages.append(message)
                rows[index].toolCount += message.tools.count
            }
        }
        for i in rows.indices {
            let connectsAbove = i > 0 && rows[i - 1].message.role == "Assistant" && rows[i].dayHeading == nil
            let precedesAgent = i + 1 < rows.count && rows[i + 1].message.role == "Assistant"
            let hasTools = rows[i].toolCount > 0
            if hasTools {
                let calls = rows[i].toolMessages.flatMap(\.displayedToolCalls)
                rows[i].toolEntries = CodingToolEntry.entries(rows[i].toolMessages)
                rows[i].hasToolDetails = calls.contains(where: \.hasDetails)
                rows[i].toolSummary = CodingToolGroup.labels(calls, namesOnly: !rows[i].hasToolDetails).joined(separator: " · ")
                if !rows[i].hasToolDetails { rows[i].toolSummary += " · Names only" }
            }
            guard rows[i].message.role == "Assistant" else { continue }
            if connectsAbove || precedesAgent || hasTools {
                // A date heading breaks the line on screen, but doesn't turn an update into a reply.
                rows[i].thread = AssistantThread(connectsAbove: connectsAbove,
                                                connectsBelow: precedesAgent && rows[i + 1].dayHeading == nil,
                                                isReply: !precedesAgent && !hasTools)
            }
        }
        if provider == .codex { CodexQuestionReply.link(in: &rows) }
        return rows
    }

    func contains(_ messageID: String) -> Bool {
        id == messageID || toolMessages.contains { $0.id == messageID }
    }
}

private struct CodingConversationTimeline: Sendable {
    let conversation: [CodingConversationRow]
    let recorded: [CodingConversationRow]

    init(_ history: CodingHistory) {
        let provider = CodingProvider(rawValue: history.session.source)
        recorded = CodingConversationRow.group(history.messages, provider: provider)
        conversation = history.messages.elementsEqual(history.conversationIDs, by: { $0.id == $1 })
            ? recorded : CodingConversationRow.group(history.conversation, provider: provider)
    }
}

private struct CodingMessageBubble: View {
    let row: CodingConversationRow
    let thread: CodingConversationRow.AssistantThread?
    let providerName: String
    let maxWidth: CGFloat
    let matchedID: String?
    let matchedTool: CodingToolLocation?
    let jumpToQuestion: (String) -> Void
    @State private var toolsExpanded = false

    private var isUser: Bool { row.message.role == "User" }
    private var isAgent: Bool { row.message.role == "Assistant" }
    private var speaker: String { isUser ? "You" : isAgent ? providerName : row.message.role }
    private var alignment: HorizontalAlignment { isUser ? .trailing : .leading }
    private var edge: Alignment { isUser ? .trailing : .leading }
    private var bubble: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: isUser ? 15 : 5,
                               bottomTrailingRadius: isUser ? 5 : 15, topTrailingRadius: 15)
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            if thread?.connectsAbove != true {
                HStack(spacing: 6) {
                    Text(speaker).fontWeight(.semibold)
                    if let date = row.message.timestamp {
                        Text(date.formatted(date: .omitted, time: .shortened)).help(date.formatted())
                    }
                    if case .answers = row.questionReply {
                        OriginalMessageButton(original: row.message.text)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            VStack(alignment: alignment, spacing: 5) {
                if row.hasText {
                    if let thread, !thread.isReply {
                        content.foregroundStyle(.primary.opacity(0.8))
                    } else if isUser || isAgent {
                        content
                            .foregroundStyle(isUser ? Color.white : Color.primary)
                            .tint(isUser ? .white : .accentColor)
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(isUser ? Color(red: 0.12, green: 0.36, blue: 0.70) : Color.primary.opacity(0.08), in: bubble)
                    } else {
                        content.padding(.leading, 10)
                            .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 2) }
                    }
                }
                if row.toolCount > 0 { tools }
            }
            .padding(.horizontal, 4)
            .overlay(alignment: edge) {
                if matchedID != nil && matchedTool == nil {
                    Capsule().fill(Color.accentColor).frame(width: 2).accessibilityHidden(true)
                }
            }
            .padding(.leading, thread == nil ? 0 : 18)
            .padding(.bottom, thread?.connectsBelow == true ? 12 : 0)
            .background(alignment: .leading) {
                if let thread {
                    AssistantThreadConnector(thread: thread)
                        .stroke(.secondary.opacity(0.6), lineWidth: 1)
                        .frame(width: 22).accessibilityHidden(true).allowsHitTesting(false)
                }
            }
            .help(row.message.timestamp?.formatted() ?? "")
        }
        .padding(.top, thread?.connectsAbove == true ? 0 : 12)
        .frame(maxWidth: maxWidth, alignment: edge)
        .frame(maxWidth: .infinity, alignment: edge)
        .onChange(of: matchedTool, initial: true) { _, match in
            if match != nil { toolsExpanded = true }
        }
        .onChange(of: matchedID, initial: true) { _, id in
            if let id, row.toolMessages.contains(where: { $0.id == id && $0.text.allSatisfy(\.isWhitespace) }) {
                toolsExpanded = true
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch row.questionReply {
        case .answers(let answers):
            CodexQuestionAnswers(answers: answers, jumpToQuestion: jumpToQuestion)
        case .unrecognized:
            Text(verbatim: row.message.text).textSelection(.enabled)
        case nil:
            MarkdownContent(markdown: row.message.text, fillsWidth: false)
        }
    }

    private var tools: some View {
        CodingToolDisclosure(isExpanded: $toolsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(row.toolEntries) { entry in
                    let call = entry.call
                    let location = matchedTool.flatMap { entry.locations.contains($0) ? $0 : nil } ?? entry.id
                    Group {
                        if call.hasDetails {
                            CodingToolDetail(call: call, matched: matchedTool == location, foldsPreview: call.events?.isEmpty == false)
                        } else {
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: call.nameLabel(count: entry.locations.count))
                                if let time = entry.recordedTime { Text(verbatim: time).monospacedDigit() }
                                if row.hasToolDetails { Text("Name only") }
                            }
                            .font(.caption).foregroundStyle(matchedTool == location ? Color.accentColor : Color.secondary)
                        }
                    }
                    .help(entry.date?.formatted() ?? "")
                    .background { if location == matchedTool { CodingToolCitation().id(location) } }
                    if let events = call.events {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Reported during this script").font(.caption).foregroundStyle(.secondary)
                            ForEach(events.indices, id: \.self) { position in
                                let event = CodingToolLocation(messageID: entry.id.messageID, index: entry.id.index, event: position)
                                CodingToolDetail(call: events[position], matched: matchedTool == event)
                                    .background { if event == matchedTool { CodingToolCitation().id(event) } }
                            }
                        }
                        .padding(.leading, 10)
                    }
                }
                if !row.hasToolDetails {
                    Text("No arguments or results are available for these calls.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 5).padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(verbatim: row.toolSummary).lineLimit(2).help(row.toolSummary)
        }
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CodingToolDisclosure<Content: View, Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: content) {
            label()
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.toggle() }
        }
    }
}

/// The scroll proxy targets message rows in the lazy stack. Use the laid-out
/// bounds of the selected call to reveal its position inside the expanded row.
private struct CodingToolCitation: NSViewRepresentable {
    final class Marker: NSView {
        private var revealed = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            guard !revealed, !bounds.isEmpty, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.revealed, !self.bounds.isEmpty, self.enclosingScrollView != nil else { return }
                self.scrollToVisible(self.bounds)
                self.revealed = true
            }
        }
    }

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

private struct CodingToolDetail: View {
    let call: CodingToolCall
    let matched: Bool
    var foldsPreview = false
    @State private var showScript = false
    @State private var showPaths = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: call.action == .script ? "Codex script" : call.name).font(.caption.weight(.semibold)).help(call.name)
                if let outcome = call.testOutcome {
                    Label(outcome.capitalized, systemImage: outcome == "passed" ? "checkmark.circle" : "xmark.circle")
                        .font(.caption).foregroundStyle(outcome == "passed" ? Color.green : Color.red)
                }
                if let result = call.result, !(call.testOutcome == "failed" && result == "Tool reported an error") {
                    Text(verbatim: result).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let subject = call.subject {
                Text(verbatim: subject).font(.system(.callout, design: .monospaced))
            }
            if let paths = call.additionalPaths {
                CodingToolDisclosure(isExpanded: $showPaths) {
                    Text(verbatim: paths.joined(separator: "\n")).font(.system(.caption, design: .monospaced))
                } label: {
                    Text("\(paths.count) more file\(paths.count == 1 ? "" : "s")")
                }
                .font(.caption)
                .onChange(of: matched, initial: true) { _, value in if value { showPaths = true } }
            }
            if let preview = call.preview {
                let snippet = Text(verbatim: preview).font(.system(.caption, design: .monospaced))
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                if foldsPreview {
                    CodingToolDisclosure(isExpanded: $showScript) { snippet } label: {
                        if showScript { Text("Script") }
                        else {
                            Text(verbatim: preview).font(.system(.caption, design: .monospaced)).lineLimit(1)
                                .help("Show script")
                        }
                    }
                    .font(.caption)
                    .onChange(of: matched, initial: true) { _, value in if value { showScript = true } }
                } else { snippet }
            }
            if let diagnostic = call.diagnostic {
                Text(verbatim: diagnostic).font(.system(.caption, design: .monospaced))
            }
        }
        .textSelection(.enabled)
        .foregroundStyle(.primary)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(matched ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 2)
        }
    }
}

private struct AssistantThreadConnector: Shape {
    let thread: CodingConversationRow.AssistantThread

    func path(in rect: CGRect) -> Path {
        let x: CGFloat = 8
        var line = Path()
        if thread.isReply {
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: 10))
            line.addQuadCurve(to: CGPoint(x: x + 6, y: 16), control: CGPoint(x: x, y: 16))
            line.addLine(to: CGPoint(x: rect.maxX, y: 16))
        } else {
            let y: CGFloat = 8, radius: CGFloat = 2.5
            if thread.connectsAbove {
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: y - radius))
            }
            line.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
            if thread.connectsBelow {
                line.move(to: CGPoint(x: x, y: y + radius))
                line.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
        }
        return line
    }
}

/// Gives the library window a stable message identity and the row's actual layout bounds.
struct ConversationRowMarker: NSViewRepresentable {
    final class MarkerView: NSView {
        var messageID = ""
        var reveal: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    let messageID: String
    let reveal: () -> Void

    func makeNSView(context: Context) -> MarkerView { MarkerView() }

    func updateNSView(_ view: MarkerView, context: Context) {
        view.messageID = messageID
        view.reveal = reveal
    }
}

struct CodingSessionDetail: View {
    let session: CodingSession
    let directory: URL
    let hit: CodingHit?
    var citedHistory: CodingHistory? = nil
    var citedMessageID: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var positionedMessageID: String?
    @State private var showsJumpToTop = false
    @State private var timeline: CodingConversationTimeline?
    @State private var recorded = false
    @State private var issue: String?

    var body: some View {
        let rows = recorded ? timeline?.recorded : timeline?.conversation
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.title).font(.title2.bold()).textSelection(.enabled)
                Text([session.providerName, session.project, session.branch].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Picker("View", selection: $recorded) {
                    Text("Conversation").tag(false)
                    Text("Recorded history").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 4)
            }
            .padding(20)
            Divider()
            if let rows {
                if rows.isEmpty {
                    ContentUnavailableView("No saved messages", systemImage: "text.bubble")
                } else {
                    ScrollViewReader { proxy in
                        transcript(rows, proxy: proxy)
                    }
                }
            } else if let issue {
                Text(issue).foregroundStyle(.red).padding(20)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: session) {
            let id = session.id, directory = directory, history = citedHistory
            let load = Task.detached(priority: .userInitiated) {
                Result { CodingConversationTimeline(try history ?? CodingArchive.historyForDisplay(in: directory, id: id)) }
            }
            let result = await withTaskCancellationHandler { await load.value } onCancel: { load.cancel() }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let value):
                if let citedMessageID {
                    guard value.recorded.contains(where: { $0.contains(citedMessageID) }) else {
                        timeline = nil
                        issue = "The cited message is no longer in this session."
                        return
                    }
                    recorded = !value.conversation.contains { $0.contains(citedMessageID) }
                }
                timeline = value
                issue = nil
            case .failure(let error): timeline = nil; issue = error.localizedDescription
            }
        }
        .onChange(of: hit?.messageID, initial: true) { _, _ in
            if let hit { recorded = hit.archived }
        }
    }

    private var matchedTool: CodingToolLocation? {
        guard let id = hit?.messageID, let index = hit?.toolIndex else { return nil }
        return CodingToolLocation(messageID: id, index: index, event: hit?.eventIndex)
    }

    private func transcript(_ rows: [CodingConversationRow], proxy: ScrollViewProxy) -> some View {
        let anchor = (citedMessageID ?? hit?.messageID).flatMap { id in rows.first { $0.contains(id) }?.id }
        return GeometryReader { geometry in
            let margins = EdgeInsets(top: 16, leading: 16, bottom: 54, trailing: 16)
            let maxWidth = min(680, max(0, geometry.size.width - margins.leading - margins.trailing) * 0.87)
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 0).id(VerticalEdge.top)
                        ForEach(rows) { row in
                            messageRow(row, width: maxWidth, anchor: anchor, proxy: proxy)
                                .background {
                                    if #unavailable(macOS 15), row.id == rows.last?.id {
                                        GeometryReader { message in
                                            let frame = message.frame(in: .scrollView)
                                            let bottom = geometry.size.height - margins.bottom
                                            let visible = frame.height > 0 && frame.maxY > 0 && frame.maxY <= bottom + 1
                                            Color.clear.preference(key: ConversationEndVisible.self, value: visible)
                                        }
                                    }
                                }
                        }
                    }
                    .onGeometryChange(for: Bool.self) { stack in
                        stack.frame(in: .scrollView).minY < -24
                    } action: { scrolledDown in
                        showsJumpToTop = scrolledDown
                    }
                }
                .contentMargins(.all, margins, for: .scrollContent)
                .modifier(ConversationOpeningPosition(opensAtBottom: anchor == nil))
                .task(id: anchor) {
                    guard let anchor else { positionedMessageID = nil; return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(anchor, anchor: .top)
                    // A nested tool scroll must follow the scroll that materializes its lazy message row.
                    positionedMessageID = anchor
                }
                // Clearing a search or citation reopens the conversation at its default position.
                .id(anchor == nil)
                if showsJumpToTop {
                    jumpToTopButton(proxy: proxy)
                        .padding(.trailing, 20).padding(.bottom, 12)
                }
            }
        }
    }

    private func jumpToTopButton(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.65)) {
                proxy.scrollTo(VerticalEdge.top, anchor: .top)
            }
        } label: {
            Label("Jump to top", systemImage: "arrow.up.to.line")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.primary.opacity(0.14)) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session-jump-to-top")
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    private func messageRow(_ row: CodingConversationRow, width: CGFloat, anchor: String?, proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            if let day = row.dayHeading {
                Text(day.formatted(date: .long, time: .omitted))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            if let report = row.taskReport {
                CodingTaskNotificationView(report: report, message: row.message, recorded: recorded, matched: row.id == anchor)
                    .frame(maxWidth: width, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CodingMessageBubble(row: row, thread: recorded ? nil : row.thread, providerName: session.providerName,
                                    maxWidth: width, matchedID: row.id == anchor ? (citedMessageID ?? hit?.messageID) : nil,
                                    matchedTool: row.id == anchor && row.id == positionedMessageID && citedMessageID == nil ? matchedTool : nil) { questionID in
                    proxy.scrollTo(questionID, anchor: .top)
                }
            }
        }
        .background {
            ConversationRowMarker(messageID: row.id) { proxy.scrollTo(row.id, anchor: .top) }
        }
        .id(row.id)
    }
}

private struct ConversationEndVisible: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct ConversationOpeningPosition: ViewModifier {
    let opensAtBottom: Bool
    @State private var releaseBottomAnchor = false

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            // Stay at the bottom while the lazy stack measures the last page.
            // Once scrolling starts, size changes should preserve the reading position.
            content
                .defaultScrollAnchor(opensAtBottom ? .bottom : nil, for: .initialOffset)
                .defaultScrollAnchor(opensAtBottom && !releaseBottomAnchor ? .bottom : nil, for: .sizeChanges)
                .onScrollPhaseChange { _, phase in
                    if phase != .idle { releaseBottomAnchor = true }
                }
        } else {
            // macOS 14 uses one anchor for all roles. Release it when the measured
            // bottom edge of the final message reaches the viewport.
            content
                .defaultScrollAnchor(opensAtBottom && !releaseBottomAnchor ? .bottom : nil)
                .onPreferenceChange(ConversationEndVisible.self) { visible in
                    if visible { releaseBottomAnchor = true }
                }
        }
    }
}
