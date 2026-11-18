import AppKit
import RecorderCore
import Security
import SwiftUI

enum GitHubConnectionMethod: String, CaseIterable, Sendable {
    case personalToken = "Personal access token"
    case app = "GitHub App"
}

struct GitHubCredential: Codable, Sendable {
    enum Authorization: Sendable {
        case personalToken(String)
        case app(clientID: String, tokens: GitHubTokens)

        var access: String {
            switch self {
            case .personalToken(let token): return token
            case .app(_, let tokens): return tokens.access
            }
        }
    }
    let userID: String
    let authorization: Authorization
    var access: String { authorization.access }
    var method: GitHubConnectionMethod {
        switch authorization {
        case .personalToken: return .personalToken
        case .app: return .app
        }
    }

    // Existing installations have userID, clientID and tokens in the Keychain.
    private enum CodingKeys: CodingKey { case userID, personalToken, clientID, tokens }
    init(userID: String, authorization: Authorization) {
        self.userID = userID
        self.authorization = authorization
    }
    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        userID = try data.decode(String.self, forKey: .userID)
        if let token = try data.decodeIfPresent(String.self, forKey: .personalToken) {
            authorization = .personalToken(token)
        } else {
            authorization = try .app(
                clientID: data.decode(String.self, forKey: .clientID), tokens: data.decode(GitHubTokens.self, forKey: .tokens))
        }
    }
    func encode(to encoder: Encoder) throws {
        var data = encoder.container(keyedBy: CodingKeys.self)
        try data.encode(userID, forKey: .userID)
        switch authorization {
        case .personalToken(let token): try data.encode(token, forKey: .personalToken)
        case .app(let id, let tokens):
            try data.encode(id, forKey: .clientID)
            try data.encode(tokens, forKey: .tokens)
        }
    }
}

protocol GitHubCredentialStore: Sendable {
    func load() throws -> GitHubCredential?
    func save(_ value: GitHubCredential) throws
    func clear() throws
}

struct GitHubKeychain: GitHubCredentialStore {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.local.afterword.github",
            kSecAttrAccount as String: "github.com",
        ]
    }
    private func checked(_ code: OSStatus) throws {
        guard code == errSecSuccess else {
            throw RecorderError.message(
                "GitHub credentials: " + (SecCopyErrorMessageString(code, nil) as String? ?? "Keychain error \(code)"))
        }
    }
    func load() throws -> GitHubCredential? {
        var q = query
        var data: CFTypeRef?
        q[kSecReturnData as String] = true
        let status = SecItemCopyMatching(q as CFDictionary, &data)
        if status == errSecItemNotFound { return nil }
        try checked(status)
        guard let data = data as? Data else { throw RecorderError.message("GitHub credentials could not be read.") }
        return try JSONDecoder().decode(GitHubCredential.self, from: data)
    }
    func save(_ value: GitHubCredential) throws {
        let updates: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            try checked(SecItemAdd(query.merging(updates) { _, new in new } as CFDictionary, nil))
        } else {
            try checked(status)
        }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try checked(status) }
    }
}

struct GitHubSnapshot {
    var account: GitHubIdentity?
    var method: GitHubConnectionMethod?
    var revision = ""
    var locked = false
    var selections: [GitHubSelection] = []
    var available: [GitHubRepository] = []
}

actor GitHubWorker {
    let directory: URL
    let client: GitHubClient
    private let store: any GitHubCredentialStore
    private var method: GitHubConnectionMethod?
    private var pending: (credential: GitHubCredential, removals: [GitHubRepository])?
    private var available: [GitHubRepository] = []
    private var generation = UUID()
    private var rotation: (id: UUID, task: Task<GitHubCredential, Error>)?
    init(directory: URL, client: GitHubClient = GitHubClient(), store: any GitHubCredentialStore = GitHubKeychain()) {
        self.directory = directory
        self.client = client
        self.store = store
    }
    func snapshot() throws -> GitHubSnapshot {
        guard GitHubArchive.exists(in: directory) else { return .init() }
        let db = try GitHubArchive(directory: directory)
        return try .init(
            account: db.account, method: method, revision: db.revision(shared: false), locked: db.locked, selections: db.selections(),
            available: available)
    }
    private func check(_ current: UUID) throws {
        try Task.checkCancellation()
        if generation != current { throw CancellationError() }
    }
    func connect(clientID: String, show: @MainActor @Sendable (GitHubDeviceCode) async -> Void) async throws -> [GitHubRepository] {
        pending = nil
        let code = try await client.deviceCode(clientID: clientID)
        try Task.checkCancellation()
        await show(code)
        let tokens = try await client.authorize(clientID: clientID, code: code)
        return try await connect(.app(clientID: clientID, tokens: tokens))
    }
    func connect(token: String) async throws -> [GitHubRepository] {
        pending = nil
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("github_pat_"), !token.contains(where: { $0.isWhitespace }) else {
            throw RecorderError.message("Paste a fine-grained personal access token from GitHub.")
        }
        do { return try await connect(.personalToken(token)) } catch GitHubServiceError.credentials {
            throw RecorderError.message("GitHub rejected this token. Check that it is current and paste it again.")
        }
    }
    private func repositories(for credential: GitHubCredential, viewer: GitHubIdentity) async throws -> [GitHubRepository] {
        switch credential.authorization {
        case .app: return try await client.repositories(token: credential.access)
        case .personalToken: return try await client.personalRepositories(token: credential.access, viewer: viewer)
        }
    }
    private func connect(_ authorization: GitHubCredential.Authorization, approvedRemovals: Set<String> = []) async throws
        -> [GitHubRepository]
    {
        let current = generation
        let viewer = try await client.viewer(token: authorization.access)
        let credential = GitHubCredential(userID: viewer.id, authorization: authorization)
        let db = try GitHubArchive(directory: directory)
        if let prior = try db.account, prior.id != viewer.id {
            throw RecorderError.message("This history belongs to another account. Reconnect that account or remove its history first.")
        }
        let repos = try await repositories(for: credential, viewer: viewer)
        try check(current)
        let accessible = Set(repos.map(\.id))
        let removed = try db.selections().map(\.repo).filter { !accessible.contains($0.id) }
        if !removed.allSatisfy({ approvedRemovals.contains($0.id) }) {
            pending = (credential, removed)
            return removed
        }
        try db.connect(viewer, verified: repos) { try store.save(credential) }
        generation = UUID()
        rotation = nil
        pending = nil
        available = repos
        method = credential.method
        return []
    }
    func confirmReplacement() async throws -> [GitHubRepository] {
        guard let proposal = pending else { throw CancellationError() }
        pending = nil
        return try await connect(proposal.credential.authorization, approvedRemovals: Set(proposal.removals.map(\.id)))
    }
    func discardReplacement() { pending = nil }
    func disconnect() throws {
        try GitHubArchive(directory: directory).disconnect { try store.clear() }
        generation = UUID()
        available = []
        rotation = nil
        pending = nil
        method = nil
    }
    func change(_ change: GitHubCoordinator.Change) throws {
        let db = try GitHubArchive(directory: directory)
        switch change {
        case .select(let repo):
            guard available.contains(repo) else {
                throw RecorderError.message("Refresh GitHub access before adding this repository.")
            }
            try db.select(repo)
        case .remove(let id): try db.remove(id)
        case .share(let id, let on): try db.share(id, enabled: on)
        case .pause(let id, let on): try db.pause(id, enabled: on)
        case .depth(let id, let all): try db.setDepth(id, all: all)
        }
    }
    private func credential(_ saved: GitHubCredential, force: Bool, current: UUID) async throws -> GitHubCredential {
        guard case .app(let clientID, let oldTokens) = saved.authorization else {
            if force { throw GitHubServiceError.credentials }
            return saved
        }
        if !force && oldTokens.expires.timeIntervalSinceNow > 180 { return saved }
        if let rotation { return try await rotation.task.value }
        let id = UUID()
        // Rotation invalidates the old refresh token at GitHub. Finish saving its
        // replacement even when a settings change cancels the requesting sync.
        let task = Task<GitHubCredential, Error> {
            let tokens = try await client.renew(clientID: clientID, refresh: oldTokens.refresh)
            guard generation == current else { throw CancellationError() }
            let updated = GitHubCredential(userID: saved.userID, authorization: .app(clientID: clientID, tokens: tokens))
            try store.save(updated)
            return updated
        }
        rotation = (id, task)
        defer { if rotation?.id == id { rotation = nil } }
        return try await task.value
    }
    private func withAccess<T>(
        _ auth: inout GitHubCredential, current: UUID, request: (GitHubCredential) async throws -> T
    ) async throws -> T {
        try check(current)
        auth = try await credential(auth, force: false, current: current)
        do { return try await request(auth) } catch GitHubServiceError.credentials {
            try check(current)
            auth = try await credential(auth, force: true, current: current)
            return try await request(auth)
        }
    }

    func sync(update: @Sendable () async -> Void) async throws {
        guard GitHubArchive.exists(in: directory) else { return }
        let db = try GitHubArchive(directory: directory)
        guard let viewer = try db.account else { return }
        let saved = try store.load()
        method = saved?.method
        guard try !db.locked else { return }
        if let until = try db.retryAfter, until > Date() { throw GitHubServiceError.retry(until) }
        let current = generation
        do {
            guard var auth = saved, auth.userID == viewer.id else { throw GitHubServiceError.credentials }
            let identity = try await withAccess(&auth, current: current) { try await client.viewer(token: $0.access) }
            guard identity.id == viewer.id else { throw GitHubServiceError.credentials }
            var lastVerification = Date.distantPast
            func verifyRepositories() async throws {
                let repos = try await withAccess(&auth, current: current) { try await repositories(for: $0, viewer: identity) }
                try check(current)
                try db.verifyAccess(repos, identity: identity, now: Date())
                available = repos
                lastVerification = Date()
                await update()
            }
            try await verifyRepositories()
            var pending = try db.selections().filter { !$0.paused }
            for repo in pending { try db.begin(repo, now: Date()) }
            var lastUpdate = Date.distantPast
            // Give every selected repository one page per pass, including during a large backfill.
            while !pending.isEmpty {
                var remaining: [GitHubSelection] = []
                for repo in pending {
                    try check(current)
                    if Date().timeIntervalSince(lastVerification) >= 900 { try await verifyRepositories() }
                    guard let work = try db.next(repo) else { continue }
                    do {
                        let page = try await withAccess(&auth, current: current) {
                            try await client.importPage(work.job, repo: repo.repo, viewer: identity, token: $0.access)
                        }
                        try check(current)
                        if !page.missing.isEmpty { try await verifyRepositories() }
                        try db.commit(page, work: work, repo: repo)
                        remaining.append(repo)
                        if Date().timeIntervalSince(lastUpdate) >= 2 {
                            await update()
                            lastUpdate = Date()
                        }
                    } catch {
                        try check(current)
                        guard try db.selections().contains(where: { $0.id == repo.id && $0.epoch == repo.epoch }) else { continue }
                        try db.status(error.localizedDescription, for: repo)
                        switch error {
                        case GitHubServiceError.retry, GitHubServiceError.credentials, is URLError: throw error
                        default: continue
                        }
                    }
                }
                pending = remaining
            }
        } catch GitHubServiceError.credentials {
            try check(current)
            try db.lock()
            available = []
            if method == .personalToken {
                throw RecorderError.message("GitHub rejected the saved token. Connect a current token for the same GitHub account.")
            }
            throw GitHubServiceError.credentials
        } catch GitHubServiceError.retry(let date) {
            try check(current)
            try db.deferRequests(until: date)
            throw GitHubServiceError.retry(date)
        }
    }

}

@MainActor final class GitHubCoordinator: ObservableObject {
    enum Change {
        case select(GitHubRepository)
        case remove(String)
        case share(String, Bool)
        case pause(String, Bool)
        case depth(String, Bool)
    }
    let directory: URL
    private let worker: GitHubWorker
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var timer: Timer?
    @Published private(set) var snapshot = GitHubSnapshot()
    @Published private(set) var busy = false
    @Published private(set) var connecting = false
    @Published private(set) var replacementRemovals: [GitHubRepository] = []
    @Published private(set) var connectionVersion = 0
    @Published private(set) var deviceCode: String?
    @Published private(set) var message: String?
    var changed: (() -> Void)?
    init(directory: URL) {
        self.directory = directory
        worker = GitHubWorker(directory: directory)
    }
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func stop() {
        timer?.invalidate()
        cancel()
    }
    func cancel() {
        task?.cancel()
        generation = UUID()
        task = nil
        busy = false
        connecting = false
        deviceCode = nil
    }
    private func publish() async {
        let current = generation
        do {
            let next = try await worker.snapshot()
            guard current == generation else { return }
            let historyChanged = snapshot.revision != next.revision || snapshot.locked != next.locked
            snapshot = next
            if historyChanged { changed?() }
        } catch {
            snapshot = .init()
            message = error.localizedDescription
            changed?()
        }
    }
    private func run(_ action: @escaping () async throws -> Void) {
        cancel()
        let current = generation
        busy = true
        message = nil
        task = Task {
            do { try await action() } catch { if !Task.isCancelled { message = error.localizedDescription } }
            guard current == generation else { return }
            await publish()
            busy = false
            connecting = false
            deviceCode = nil
            task = nil
        }
    }
    private func sync() async throws {
        try await worker.sync { [weak self] in await self?.publish() }
    }
    func refresh() {
        guard task == nil else { return }
        run {
            await self.publish()
            try await self.sync()
        }
    }
    private func connect(_ validate: @escaping () async throws -> [GitHubRepository]) {
        run {
            let removals = try await validate()
            try Task.checkCancellation()
            self.deviceCode = nil
            self.connecting = false
            self.replacementRemovals = removals
            guard removals.isEmpty else { return }
            self.connectionVersion += 1
            await self.publish()
            try await self.sync()
        }
        connecting = true
    }
    func connect(clientID: String) {
        connect {
            try await self.worker.connect(clientID: clientID) { [weak self] code in self?.deviceCode = code.user_code }
        }
    }
    func connect(token: String) { connect { try await self.worker.connect(token: token) } }
    func confirmReplacement() {
        replacementRemovals = []
        connect { try await self.worker.confirmReplacement() }
    }
    func discardReplacement() {
        replacementRemovals = []
        Task { await worker.discardReplacement() }
    }
    func change(_ change: Change) {
        switch change {
        case .share, .remove, .pause(_, true):
            Task {
                do {
                    try await worker.change(change)
                    await publish()
                } catch { message = error.localizedDescription }
            }
            return
        default: break
        }
        run {
            try await self.worker.change(change)
            await self.publish()
            try await self.sync()
        }
    }
    func disconnect() {
        replacementRemovals = []
        run { try await self.worker.disconnect() }
    }
}
