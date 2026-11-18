import RecorderCore
import SwiftUI

struct GitHubRepositoryPickerButton: View {
    @ObservedObject var github: GitHubCoordinator
    var scope: GitHubRepositoryPicker.Scope = .available
    @State private var presented = false

    var body: some View {
        if let account = github.snapshot.account, !github.snapshot.locked {
            Button(scope == .available ? "Choose repositories…" : "Manage repository sharing…") { presented = true }
                .disabled(github.connecting || !github.replacementRemovals.isEmpty)
                .sheet(isPresented: $presented) {
                    GitHubRepositoryPicker(
                        scope: scope, available: github.snapshot.available, imported: github.snapshot.selections.map(\.repo),
                        shared: Set(github.snapshot.selections.filter(\.shared).map(\.id)), loading: github.busy
                    ) { ids, action in
                        try await github.applyRepositories(ids, action: action, accountID: account.id)
                    }.id(account.id)
                }
        }
    }
}

struct GitHubRepositoryPicker: View {
    enum Scope { case available, imported }
    private struct Filter: Equatable {
        let scope: Scope
        let owner, query: String
    }
    @State var scope: Scope
    let available: [GitHubRepository]
    let imported: [GitHubRepository]
    let shared: Set<String>
    let loading: Bool
    let apply: (Set<String>, GitHubRepositoryAction) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var owner = ""
    @State private var checked: [Scope: Set<String>] = [:]
    @State private var shareImports = false
    @State private var saving = false
    @State private var error: String?

    static func matches(_ repos: [GitHubRepository], owner: String, query: String) -> [GitHubRepository] {
        var search = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if search.hasPrefix("https://github.com/") {
            search = String(search.dropFirst("https://github.com/".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if search.hasSuffix(".git") { search.removeLast(4) }
        }
        let terms = search.split(whereSeparator: \.isWhitespace)
        var exact: [GitHubRepository] = []
        var prefixes: [GitHubRepository] = []
        var others: [GitHubRepository] = []
        for repo in repos where owner.isEmpty || repo.name.hasPrefix(owner + "/") {
            let name = repo.name.lowercased()
            guard terms.allSatisfy({ name.contains($0) }) else { continue }
            let shortName = name.split(separator: "/").last ?? ""
            if name == search || shortName == search {
                exact.append(repo)
            } else if !search.isEmpty && shortName.hasPrefix(search) {
                prefixes.append(repo)
            } else {
                others.append(repo)
            }
        }
        return exact + prefixes + others
    }

    var body: some View {
        let importedIDs = Set(imported.map(\.id))
        let repos = scope == .imported ? imported : available.filter { !importedIDs.contains($0.id) }
        let owners = Set((available + imported).compactMap { $0.name.split(separator: "/").first.map(String.init) }).sorted()
        let visible = Self.matches(repos, owner: owner, query: query)
        let selection = checked[scope, default: []].intersection(repos.map(\.id))
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub repositories").font(.title2.bold())
            Picker("Repositories", selection: $scope) {
                Text("Available to import").tag(Scope.available)
                Text("Imported").tag(Scope.imported)
            }.pickerStyle(.segmented).labelsHidden()
            HStack {
                TextField("Search repositories", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
                Picker("Owner", selection: $owner) {
                    Text("All owners").tag("")
                    ForEach(owners, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().fixedSize()
            }
            HStack {
                Text("\(visible.count) matching").foregroundStyle(.secondary)
                Spacer()
                Button("Select matches") { checked[scope, default: []].formUnion(visible.map(\.id)) }
                    .disabled(visible.isEmpty || visible.allSatisfy { selection.contains($0.id) })
                Button("Clear selection") { checked[scope] = [] }.disabled(selection.isEmpty)
            }.controlSize(.small)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { repo in
                            repositoryRow(repo, selected: selection.contains(repo.id))
                                .padding(.horizontal, 10).frame(minHeight: 29)
                                .overlay(alignment: .bottom) { Divider() }
                        }
                    }
                }
                .onChange(of: Filter(scope: scope, owner: owner, query: query)) { _, _ in
                    if let first = visible.first { scroll.scrollTo(first.id, anchor: .top) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary).allowsHitTesting(false) }
            .overlay {
                if visible.isEmpty {
                    if scope == .available && loading && available.isEmpty {
                        ProgressView("Loading repositories…")
                    } else {
                        Text(
                            query.isEmpty && owner.isEmpty && scope == .imported
                                ? "No imported repositories." : "No matching repositories."
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                Text("\(selection.count) selected").monospacedDigit().foregroundStyle(.secondary)
                if scope == .available {
                    Toggle("Share through MCP", isOn: $shareImports).toggleStyle(.checkbox)
                        .help("Let connected agents read the selected repositories when Agent Access is enabled.")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if scope == .available {
                    Button("Import") { save(selection, .add(shared: shareImports)) }
                        .buttonStyle(.borderedProminent).disabled(selection.isEmpty)
                } else {
                    Button("Stop sharing") { save(selection, .setSharing(false)) }.disabled(selection.isDisjoint(with: shared))
                    Button("Share via MCP") { save(selection, .setSharing(true)) }
                        .buttonStyle(.borderedProminent).disabled(selection.isSubset(of: shared))
                }
            }
        }
        .padding(20).frame(width: 620, height: 510)
        .disabled(saving).interactiveDismissDisabled(saving)
        .defaultFocus($searchFocused, true)
        .onChange(of: owners) { _, next in if !owner.isEmpty && !next.contains(owner) { owner = "" } }
    }

    private func repositoryRow(_ repo: GitHubRepository, selected: Bool) -> some View {
        let parts = repo.name.split(separator: "/", maxSplits: 1)
        return Toggle(
            isOn: Binding(
                get: { selected },
                set: { on in
                    if on { checked[scope, default: []].insert(repo.id) } else { checked[scope, default: []].remove(repo.id) }
                })
        ) {
            HStack {
                Text(String(parts.last ?? "")).lineLimit(1)
                if let owner = parts.first { Text(String(owner)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if scope == .imported && shared.contains(repo.id) {
                    Text("Shared via MCP").font(.caption).foregroundStyle(.secondary)
                }
            }.contentShape(Rectangle())
        }.toggleStyle(.checkbox).accessibilityLabel(repo.name)
    }

    private func save(_ ids: Set<String>, _ action: GitHubRepositoryAction) {
        guard !saving, !ids.isEmpty else { return }
        saving = true
        error = nil
        Task { @MainActor in
            do {
                try await apply(ids, action)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
