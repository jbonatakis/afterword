import SwiftUI
import RecorderCore

private struct CodingSnapshot {
    let settings: CodingImportSettings?
    let available: [String]
    let sessions: [CodingSession]
    let issue: String?
}

private actor CodingImportWorker {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func refresh(change: CodingCoordinator.Change?, discover: Bool) throws -> CodingSnapshot {
        if change == nil && !CodingArchive.exists(in: directory) {
            return .init(settings: nil, available: [], sessions: [], issue: nil)
        }
        let archive = try CodingArchive(directory: directory)
        switch change {
        case .enabled(let provider, let value): try archive.setEnabled(value, for: provider)
        case .scope(let scope): try archive.setCodexScope(scope)
        case .add(let path): try archive.addProject(path)
        case .remove(let path): try archive.removeProject(path)
        case nil: break
        }
        let result = try archive.refresh(discoverProjects: discover)
        return try .init(settings: archive.settings(), available: result.projects, sessions: archive.sessions(),
                         issue: result.issues.isEmpty ? nil : result.issues.joined(separator: "\n"))
    }
}

@MainActor final class CodingCoordinator: ObservableObject {
    enum Change: Equatable { case enabled(CodingProvider, Bool), scope(CodexScope), add(String), remove(String) }
    let directory: URL
    private let worker: CodingImportWorker
    @Published private(set) var providers: Set<CodingProvider> = []
    @Published private(set) var codexScope = CodexScope()
    var enabled: Bool { !providers.isEmpty }
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
                let nextProjects = next.settings?.projects ?? []
                let updated = sessions != next.sessions || projects != nextProjects || providers != nextProviders
                providers = nextProviders; projects = nextProjects; sessions = next.sessions; issue = next.issue
                codexScope = next.settings?.codexScope ?? CodexScope()
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
    @State private var accountID = ""
    @State private var userID = ""
    private var scope: CodexScope { .init(accountID: accountID, userID: userID) }
    var body: some View {
        Form {
            Section {
                ForEach(CodingProvider.allCases, id: \.self) { provider in
                    Toggle("Import \(provider.name) sessions", isOn: Binding(get: { coding.providers.contains(provider) },
                        set: { coding.refresh(.enabled(provider, $0), discover: true) }))
                }
                if coding.providers.contains(.codex) {
                    DisclosureGroup("Account-scoped Codex sessions") {
                        Text("To include threads marked for your Codex account, enter the creator account ID and, if present, the creator user ID from your rollout header. Clearing these fields pauses future imports of those threads.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Creator account ID", text: $accountID)
                        TextField("Creator user ID", text: $userID)
                        Button("Apply account scope") { coding.refresh(.scope(scope), discover: true) }
                            .disabled(scope == coding.codexScope || (scope.accountID.isEmpty && !scope.userID.isEmpty))
                    }
                }
                Text("Selected projects apply to every enabled source. Afterword saves prompts, replies, and tool names locally. Pausing a source keeps its saved sessions available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Projects") {
                ForEach(Array(Set(coding.available + coding.projects)).sorted(), id: \.self) { path in
                    Toggle(isOn: Binding(get: { coding.projects.contains(path) }, set: { selected in
                        if selected { coding.refresh(.add(path)) } else { removing = path }
                    })) {
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.disabled(!coding.enabled && !coding.projects.contains(path))
                }
                if coding.enabled {
                    Button("Refresh projects") { coding.refresh(discover: true) }
                    if coding.available.isEmpty && coding.projects.isEmpty && !coding.busy {
                        Text("No local sessions with a project directory were found.").foregroundStyle(.secondary)
                    }
                }
            }
            if coding.busy { ProgressView("Checking coding sessions…").controlSize(.small) }
            if let issue = coding.issue { Text(issue).foregroundStyle(.red) }
        }
        .formStyle(.grouped).disabled(coding.busy)
        .onAppear { coding.refresh(discover: true) }
        .onChange(of: coding.codexScope, initial: true) { _, scope in
            accountID = scope.accountID
            userID = scope.userID
        }
        .confirmationDialog("Remove imported sessions for this project?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { path in
            Button("Remove project history", role: .destructive) { coding.refresh(.remove(path)) }
            Button("Cancel", role: .cancel) {}
        } message: { path in Text("Afterword will delete its saved sessions from all sources for \(path) and stop importing this project.") }
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
