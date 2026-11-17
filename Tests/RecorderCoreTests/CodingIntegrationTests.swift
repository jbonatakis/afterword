#if canImport(XCTest)
import XCTest
#endif
import Foundation
import Lookback
@testable import RecorderCore

final class CodingIntegrationTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let project = "/projects/example"
    private var source: URL { root.appendingPathComponent("source") }
    private var file: URL { source.appendingPathComponent("example/00000000-0000-4000-a000-000000000001.jsonl") }
    private var archived: URL { root.appendingPathComponent("CodingSessions") }
    private var reader: ClaudeCodeReader { ClaudeCodeReader(projectsDirectory: source) }
    private let transcript = #"""
    {"type":"user","uuid":"old","cwd":"/projects/example","timestamp":"2026-11-01T09:00:00Z","message":{"content":"Earlier migration notes"}}
    {"type":"system","uuid":"boundary","logicalParentUuid":"old"}
    {"type":"user","uuid":"summary","parentUuid":"boundary","isCompactSummary":true,"message":{"content":"Earlier context"}}
    {"type":"user","uuid":"request","parentUuid":"summary","timestamp":"2026-11-05T09:00:00Z","message":{"content":"Delay device restarts during meetings"}}
    {"type":"assistant","uuid":"tool","parentUuid":"request","message":{"id":"response","content":[{"type":"tool_use","id":"run","name":"Read","input":{"private":"SecretInputToken"}}]}}
    {"type":"user","uuid":"result","parentUuid":"tool","message":{"content":[{"type":"tool_result","tool_use_id":"run","content":"SecretOutputToken"}]}}
    {"type":"assistant","uuid":"reply","parentUuid":"result","timestamp":"2026-11-05T09:03:00Z","gitBranch":"device-guard","message":{"content":"Shipped the restart guard."}}
    {"type":"custom-title","customTitle":"Device reliability"}
    """#

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(transcript.utf8).write(to: file)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func imported() throws -> CodingArchive {
        let archive = try CodingArchive(directory: archived)
        try archive.setEnabled(true)
        try archive.addProject(project)
        try archive.synchronize(reader: reader)
        return archive
    }

    func testOptInArchiveViewsAndCleanup() throws {
        let store = try CodingArchive(directory: archived)
        try store.synchronize(reader: reader)
        XCTAssertTrue(try store.sessions().isEmpty)
        try store.setEnabled(true)
        try store.synchronize(reader: reader)
        XCTAssertTrue(try store.sessions().isEmpty)
        XCTAssertEqual(try CodingArchive.availableProjects(reader: reader), [project])
        try store.addProject(project)
        try store.synchronize(reader: reader)
        let session = try XCTUnwrap(store.sessions().first)
        let history = try store.history(id: session.id)
        XCTAssertEqual(history.messages.map(\.id), ["old", "summary", "request", "tool", "reply"])
        XCTAssertEqual(history.conversation.map(\.id), ["summary", "request", "tool", "reply"])
        XCTAssertEqual(history.conversation[2].tools, ["Read"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(history), as: UTF8.self).contains("Secret"))
        let revision = try store.revision
        try store.synchronize(reader: reader)
        XCTAssertEqual(try store.revision, revision)
        try FileManager.default.removeItem(at: file)
        try store.synchronize(reader: reader)
        XCTAssertEqual(try store.history(id: session.id).conversationIDs, history.conversationIDs)
        try store.removeProject(project)
        XCTAssertThrowsError(try store.history(id: session.id))
        XCTAssertTrue(try store.embeddingChunks().isEmpty)
    }

    func testRotatedSourceRetainsEarlierEvidenceAndChangesCurrentView() throws {
        let archive = try imported()
        let id = try XCTUnwrap(archive.sessions().first).id
        let row = #"{"type":"user","uuid":"next","cwd":"/projects/example","timestamp":"2026-11-07T09:01:00Z","message":{"content":"Move to the next issue"}}"#
        try Data(row.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(100)], ofItemAtPath: file.path)
        try archive.synchronize(reader: reader)
        let history = try archive.history(id: id)
        XCTAssertEqual(history.conversationIDs, ["next"])
        XCTAssertTrue(history.messages.contains { $0.id == "reply" })
        let old = try archive.matches(query: "migration", semantic: [], from: nil, to: nil, project: project, branch: nil)
        XCTAssertEqual(old.first?.messageID, "old")
        XCTAssertEqual(old.first?.archived, true)
    }

    func testAgentAccessRevocationCitationsAndDateFilters() throws {
        let archive = try imported()
        let id = try XCTUnwrap(archive.sessions().first).id
        // Simulate the settings that shipped before coding integration.
        try Data(#"{"version":1,"enabled":true,"folders":[]}"#.utf8).write(to: root.appendingPathComponent("Access.json"))
        let service = AgentLibrary(directory: root)
        func search(_ fields: [String: Any]) throws -> [[String: Any]] {
            try XCTUnwrap(service.call("search_activity", arguments: fields)["items"] as? [[String: Any]])
        }
        XCTAssertTrue(try search(["query": "restart"]).isEmpty)
        XCTAssertThrowsError(try service.call("get_coding_session", arguments: ["session_id": id]))
        try AgentAccessStore.save(.init(enabled: true, allowCodingSessions: true), directory: root)
        XCTAssertEqual(try search(["query": "migration", "from": "2026-11-01T00:00:00Z", "to": "2026-11-02T00:00:00Z"]).first?["message_id"] as? String, "old")
        XCTAssertTrue(try search(["query": "migration", "from": "2026-11-02T00:00:00Z"]).isEmpty)
        XCTAssertEqual(try search(["source": "coding", "from": "2026-11-01T00:00:00Z", "to": "2026-11-02T00:00:00Z"]).first?["message_id"] as? String, "old")
        XCTAssertEqual(try search([:]).first?["session_id"] as? String, id)
        XCTAssertTrue(try search(["query": "restart", "branch": "another"]).isEmpty)
        XCTAssertTrue(try search(["query": "SecretOutputToken"]).isEmpty)
        XCTAssertTrue(try search(["query": "SecretInputToken"]).isEmpty)
        let result = try service.call("get_coding_session", arguments: ["session_id": id, "message_id": "old", "view": "recorded", "limit": 1])
        XCTAssertEqual((result["items"] as? [[String: Any]])?.first?["text"] as? String, "Earlier migration notes")
        XCTAssertEqual(result["next_offset"] as? Int, 1)
        try AgentAccessStore.save(.init(enabled: true), directory: root)
        XCTAssertThrowsError(try service.call("get_coding_session", arguments: ["session_id": id]))
        XCTAssertTrue(try search(["query": "restart"]).isEmpty)
    }

    func testSemanticOnlyCodingHitUsesModelAndRespectsQuotes() throws {
        let archive = try imported()
        let model = EmbeddingModel.catalog[0]
        let settingsDirectory = root.appendingPathComponent("embeddings")
        var settings = EmbeddingSettings()
        settings.enabled = true; settings.modelID = model.id
        try settings.save(directory: settingsDirectory)
        try PrivateFiles.directory(EmbeddingSettings.modelRoot(settingsDirectory))
        try Data().write(to: ModelStore.ownedURL(model.asset, root: EmbeddingSettings.modelRoot(settingsDirectory)))
        let index = try LibrarySearchIndex(roots: [], directory: root.appendingPathComponent("search"), embeddingDirectory: settingsDirectory)
        index.semantic = SemanticSearchEngine(directory: settingsDirectory) { texts, model, _, _ in
            texts.map { _ in [1] + Array(repeating: 0, count: model.dimensions - 1) }
        }
        try index.useCodingArchive(in: archived)
        let deadline = Date().addingTimeInterval(5)
        while index.semanticStatus().state == "indexing" && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(try index.codingSearch("rebooting", keywordOnly: true).hits.isEmpty)
        let semantic = try index.codingSearch("rebooting")
        XCTAssertEqual(semantic.status.mode, "hybrid")
        XCTAssertTrue(semantic.hits.contains { $0.messageID == "reply" })
        XCTAssertTrue(try index.codingSearch(#""an unrelated exact phrase""#).hits.isEmpty)
        try archive.removeProject(project)
        index.refreshSemanticSearch()
        XCTAssertTrue(try index.codingSearch("rebooting").hits.isEmpty)
        index.stopSemanticSearch()
    }
}
