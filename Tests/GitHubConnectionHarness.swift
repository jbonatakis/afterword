// Run with ./Scripts/check-library.sh Tests/GitHubConnectionHarness.swift
import Foundation
import RecorderCore

private enum FixtureError: Error { case keychain, unexpectedEndpoint }

private final class MemoryKeychain: GitHubCredentialStore, @unchecked Sendable {
    var data: Data?
    var rejectWrite = false
    func load() throws -> GitHubCredential? {
        try data.map { try JSONDecoder().decode(GitHubCredential.self, from: $0) }
    }
    func save(_ value: GitHubCredential) throws {
        if rejectWrite { throw FixtureError.keychain }
        data = try JSONEncoder().encode(value)
    }
    func clear() throws {
        if rejectWrite { throw FixtureError.keychain }
        data = nil
    }
}

private final class FixtureGitHub: URLProtocol {
    static var ids = ["A", "B"]
    static var revoked = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let url = request.url!
        let json: Any
        var status = 200
        switch (url.path, authorization) {
        case ("/user", "Bearer github_pat_wrong"):
            json = ["node_id": "other", "login": "other"]
        case ("/user", "Bearer github_pat_rejected"):
            status = 401
            json = [:]
        case ("/user", "Bearer github_pat_fixture") where Self.revoked:
            status = 401
            json = [:]
        case ("/user", "Bearer github_pat_fixture"), ("/user", "Bearer old-app"):
            json = ["node_id": "U", "login": "fixture"]
        case ("/user/installations", "Bearer old-app"):
            json = ["total_count": 1, "installations": [["id": 1, "permissions": ["issues": "read", "pull_requests": "read"]]]]
        case ("/user/installations/1/repositories", "Bearer old-app"):
            json = ["total_count": 2, "repositories": ["A", "B"].map { ["node_id": $0, "full_name": "fixture/" + $0] }]
        case ("/user/repos", "Bearer github_pat_fixture"):
            json = Self.ids.map { ["node_id": $0] }
        case ("/graphql", "Bearer github_pat_fixture"):
            let body = requestBody()
            guard let ids = (body?["variables"] as? [String: Any])?["ids"] as? [String] else {
                client?.urlProtocol(self, didFailWithError: FixtureError.unexpectedEndpoint)
                return
            }
            let nodes: [Any] = ids.map { id in
                guard Self.ids.contains(id) else { return NSNull() }
                return ["id": id, "nameWithOwner": "fixture/" + id, "issues": ["totalCount": 0], "pullRequests": ["totalCount": 0]]
            }
            json = ["data": ["viewer": ["id": "U"], "nodes": nodes]]
        default:
            client?.urlProtocol(self, didFailWithError: FixtureError.unexpectedEndpoint)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    private func requestBody() -> [String: Any]? {
        if let data = request.httpBody { return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        return (try? JSONSerialization.jsonObject(with: stream)) as? [String: Any]
    }
    override func stopLoading() {}
}

@main struct GitHubConnectionHarness {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureGitHub.self]
        let client = GitHubClient(session: URLSession(configuration: config))
        let store = MemoryKeychain()
        // Simulate the on-disk Keychain representation from a build predating token support.
        store.data = Data(
            #"{"userID":"U","clientID":"app","tokens":{"access":"old-app","refresh":"old-refresh","expires":4000000000}}"#.utf8)
        let legacy = store.data
        let worker = GitHubWorker(directory: directory, client: client, store: store)
        let db = try GitHubArchive(directory: directory)
        try db.connect(.init(id: "U", login: "fixture"))
        try await worker.sync {}
        let original = try await worker.snapshot()
        precondition(original.method == .app && original.available.count == 2)
        for repo in original.available {
            try await worker.change(.select(repo))
            try await worker.change(.share(repo.id, true))
            try await worker.change(.pause(repo.id, true))
        }
        let oldEpochs = try db.selections().map(\.epoch)
        for token in ["ghp_classic", "github_pat_wrong", "github_pat_rejected"] {
            do {
                _ = try await worker.connect(token: token)
                preconditionFailure("Invalid replacement was accepted")
            } catch RecorderError.message {}
        }
        precondition(store.data == legacy)
        FixtureGitHub.ids = ["A"]
        let narrower = try await worker.connect(token: "github_pat_fixture")
        precondition(narrower.map(\.id) == ["B"])
        await worker.discardReplacement()
        let unchanged = try db.selections()
        precondition(unchanged.map(\.epoch) == oldEpochs && unchanged.allSatisfy(\.shared) && store.data == legacy)
        _ = try await worker.connect(token: "github_pat_fixture")
        // Scope changed again between displaying the warning and confirming it.
        FixtureGitHub.ids = []
        let revised = try await worker.confirmReplacement()
        precondition(revised.map(\.id) == ["A", "B"] && store.data == legacy)
        store.rejectWrite = true
        do {
            _ = try await worker.confirmReplacement()
            preconditionFailure("A failed credential save committed the archive change")
        } catch FixtureError.keychain {}
        let afterFailedSave = try db.selections()
        precondition(afterFailedSave.map(\.epoch) == oldEpochs && afterFailedSave.allSatisfy(\.shared))
        store.rejectWrite = false
        FixtureGitHub.ids = ["A"]
        _ = try await worker.connect(token: " github_pat_fixture\n")
        let complete = try await worker.confirmReplacement()
        let retained = try db.selections()
        let saved = try store.load()
        precondition(complete.isEmpty && saved?.method == .personalToken)
        precondition(retained.count == 1 && retained[0].id == "A" && retained[0].epoch == oldEpochs[0] && retained[0].shared)

        let reopened = GitHubWorker(directory: directory, client: client, store: store)
        try await reopened.sync {}
        let snapshot = try await reopened.snapshot()
        precondition(snapshot.method == .personalToken && snapshot.available.map(\.id) == ["A"])
        FixtureGitHub.revoked = true
        do {
            try await reopened.sync {}
            preconditionFailure("A revoked token kept the archive unlocked")
        } catch RecorderError.message(let message) {
            precondition(message.contains("saved token"))
        }
        let locked = try await reopened.snapshot()
        precondition(locked.locked && locked.selections.count == 1 && !locked.selections[0].shared)
        FixtureGitHub.revoked = false
        _ = try await reopened.connect(token: "github_pat_fixture")
        let restored = try await reopened.snapshot()
        precondition(!restored.locked && restored.selections.count == 1 && !restored.selections[0].shared)
        store.rejectWrite = true
        do {
            try await reopened.disconnect()
            preconditionFailure("A failed Keychain deletion removed the archive")
        } catch FixtureError.keychain {}
        let afterFailedDisconnect = try await reopened.snapshot()
        precondition(afterFailedDisconnect.account != nil && afterFailedDisconnect.selections.count == 1 && store.data != nil)
        store.rejectWrite = false
        FixtureGitHub.ids = []
        try await reopened.sync {}
        let revokedRepo = try db.selections()
        precondition(revokedRepo.isEmpty)
        try await reopened.disconnect()
        let account = try db.account
        precondition(account == nil && store.data == nil)
        print("PASS GitHub App migration, token validation, replacement, rollback, access changes and disconnect")
    }
}
