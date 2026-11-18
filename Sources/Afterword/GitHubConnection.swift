import AppKit
import RecorderCore
import Security
import SwiftUI

private struct GitHubCredential: Codable {
    let clientID, userID: String
    let tokens: GitHubTokens
}

private enum GitHubKeychain {
    static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.local.afterword.github",
            kSecAttrAccount as String: "github.com",
        ]
    }
    static func checked(_ code: OSStatus) throws {
        guard code == errSecSuccess else {
            throw RecorderError.message(
                "GitHub credentials: " + (SecCopyErrorMessageString(code, nil) as String? ?? "Keychain error \(code)"))
        }
    }
    static func load() throws -> GitHubCredential? {
        var q = query
        var data: CFTypeRef?
        q[kSecReturnData as String] = true
        let status = SecItemCopyMatching(q as CFDictionary, &data)
        if status == errSecItemNotFound { return nil }
        try checked(status)
        guard let data = data as? Data else { throw RecorderError.message("GitHub credentials could not be read.") }
        return try JSONDecoder().decode(GitHubCredential.self, from: data)
    }
    static func save(_ value: GitHubCredential) throws {
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
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try checked(status) }
    }
}

struct GitHubSnapshot {
    var account: GitHubIdentity?
    var revision = ""
    var locked = false
    var selections: [GitHubSelection] = []
    var available: [GitHubRepository] = []
}

private actor GitHubWorker {
    let directory: URL
    let client = GitHubClient()
    private var available: [GitHubRepository] = []
    private var generation = UUID()
    private var rotation: (id: UUID, task: Task<GitHubCredential, Error>)?
    init(directory: URL) { self.directory = directory }
    func snapshot() throws -> GitHubSnapshot {
        guard GitHubArchive.exists(in: directory) else { return .init() }
        let db = try GitHubArchive(directory: directory)
        return try .init(
            account: db.account, revision: db.revision(shared: false), locked: db.locked, selections: db.selections(),
            available: available)
    }
    private func check(_ current: UUID) throws {
        try Task.checkCancellation()
        if generation != current { throw CancellationError() }
    }
    func connect(clientID: String, show: @MainActor @Sendable (GitHubDeviceCode) async -> Void) async throws {
        generation = UUID()
        let current = generation
        let code = try await client.deviceCode(clientID: clientID)
        try check(current)
        await show(code)
        let tokens = try await client.authorize(clientID: clientID, code: code)
        let viewer = try await client.viewer(token: tokens.access)
        let repos = try await client.repositories(token: tokens.access)
        try check(current)
        let db = try GitHubArchive(directory: directory)
        if let prior = try db.account, prior.id != viewer.id {
            throw RecorderError.message("This history belongs to another account. Reconnect that account or remove its history first.")
        }
        try GitHubKeychain.save(.init(clientID: clientID, userID: viewer.id, tokens: tokens))
        try db.connect(viewer, verified: repos, now: Date())
        available = repos
    }
    func disconnect() throws {
        generation = UUID()
        available = []
        rotation = nil
        try GitHubArchive(directory: directory).disconnect()
        try GitHubKeychain.clear()
    }
    func change(_ change: GitHubCoordinator.Change) throws {
        let db = try GitHubArchive(directory: directory)
        switch change {
        case .select(let repo):
            guard available.contains(repo) else {
                throw RecorderError.message("Refresh installation access before adding this repository.")
            }
            try db.select(repo)
        case .remove(let id): try db.remove(id)
        case .share(let id, let on): try db.share(id, enabled: on)
        case .pause(let id, let on): try db.pause(id, enabled: on)
        case .depth(let id, let all): try db.setDepth(id, all: all)
        }
    }
    private func credential(for viewer: GitHubIdentity, force: Bool, current: UUID) async throws -> GitHubCredential {
        guard let saved = try GitHubKeychain.load(), saved.userID == viewer.id else { throw GitHubServiceError.credentials }
        if !force && saved.tokens.expires.timeIntervalSinceNow > 180 { return saved }
        if let rotation { return try await rotation.task.value }
        let id = UUID()
        // Rotation invalidates the old refresh token at GitHub. Finish saving its
        // replacement even when a settings change cancels the requesting sync.
        let task = Task<GitHubCredential, Error> {
            let tokens = try await client.renew(clientID: saved.clientID, refresh: saved.tokens.refresh)
            guard generation == current else { throw CancellationError() }
            let updated = GitHubCredential(clientID: saved.clientID, userID: viewer.id, tokens: tokens)
            try GitHubKeychain.save(updated)
            return updated
        }
        rotation = (id, task)
        defer { if rotation?.id == id { rotation = nil } }
        return try await task.value
    }
    private func withAccess<T>(
        _ auth: inout GitHubCredential, viewer: GitHubIdentity, current: UUID, request: (String) async throws -> T
    ) async throws -> T {
        try check(current)
        if auth.tokens.expires.timeIntervalSinceNow < 180 {
            auth = try await credential(for: viewer, force: false, current: current)
        }
        do { return try await request(auth.tokens.access) } catch GitHubServiceError.credentials {
            try check(current)
            auth = try await credential(for: viewer, force: true, current: current)
            return try await request(auth.tokens.access)
        }
    }

    func sync(update: @Sendable () async -> Void) async throws {
        guard GitHubArchive.exists(in: directory) else { return }
        let db = try GitHubArchive(directory: directory)
        guard let viewer = try db.account, try !db.locked else { return }
        if let until = try db.retryAfter, until > Date() { throw GitHubServiceError.retry(until) }
        let current = generation
        do {
            var auth = try await credential(for: viewer, force: false, current: current)
            let identity = try await withAccess(&auth, viewer: viewer, current: current) { try await client.viewer(token: $0) }
            guard identity.id == viewer.id else { throw GitHubServiceError.credentials }
            var lastVerification = Date.distantPast
            func verifyInstallations() async throws {
                let repos = try await withAccess(&auth, viewer: viewer, current: current) { try await client.repositories(token: $0) }
                try check(current)
                try db.verifyAccess(repos, identity: identity, now: Date())
                available = repos
                lastVerification = Date()
                await update()
            }
            try await verifyInstallations()
            var pending = try db.selections().filter { !$0.paused }
            for repo in pending { try db.begin(repo, now: Date()) }
            var lastUpdate = Date.distantPast
            // Give every selected repository one page per pass, including during a large backfill.
            while !pending.isEmpty {
                var remaining: [GitHubSelection] = []
                for repo in pending {
                    try check(current)
                    if Date().timeIntervalSince(lastVerification) >= 900 { try await verifyInstallations() }
                    guard let work = try db.next(repo) else { continue }
                    do {
                        let page = try await withAccess(&auth, viewer: viewer, current: current) {
                            try await client.importPage(work.job, repo: repo.repo, viewer: identity, token: $0)
                        }
                        try check(current)
                        if !page.missing.isEmpty { try await verifyInstallations() }
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
    func connect(clientID: String) {
        run {
            try await self.worker.connect(clientID: clientID) { [weak self] code in
                self?.deviceCode = code.user_code
            }
            self.deviceCode = nil
            await self.publish()
            try await self.sync()
        }
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
    func disconnect() { run { try await self.worker.disconnect() } }
}
