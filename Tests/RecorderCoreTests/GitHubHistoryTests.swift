import Foundation

@testable import RecorderCore

#if canImport(XCTest)
    import XCTest
#endif

final class GitHubHistoryTests: XCTestCase {
    var root: URL!
    var db: GitHubArchive!
    let repo = GitHubRepository(id: "R1", name: "sample/garden")
    let viewer = GitHubIdentity(id: "U1", login: "gardener")
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        db = try GitHubArchive(directory: root.appendingPathComponent("GitHub"))
        try db.connect(viewer)
        try db.select(repo)
        try AgentAccessStore.save(.init(enabled: true), directory: root)
    }
    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: root)
    }
    func item(_ id: String = "PR1", repo: String = "R1", title: String = "Preserve the old callback") -> GitHubItem {
        .init(
            id: id, repositoryID: repo, type: "pr", title: title, author: "teammate", state: "MERGED",
            url: "https://github.com/sample/garden/pull/12", number: 12)
    }
    func passage(_ id: String, _ text: String, kind: GitHubActionKind = .comment, actor: String = "U1", daysAgo: Int = 0)
        -> GitHubPassage
    {
        .init(
            id: id, actorID: actor, text: text, url: "https://github.com/sample/garden/pull/12#" + id, kind: kind,
            date: date.addingTimeInterval(Double(-daysAgo) * 86400), edited: nil, verdict: kind == .review ? "APPROVED" : nil,
            path: kind == .inline ? "lib/retry.swift" : nil, line: kind == .inline ? 42 : nil)
    }
    func commit(_ entries: [(GitHubItem, GitHubPassage)], missing: [String] = [], id: String = "R1") throws {
        let selected = try XCTUnwrap(db.selections().first { $0.id == id })
        try db.begin(selected, now: date)
        var page = GitHubPage()
        page.entries = entries
        page.missing = missing
        try db.commit(page, work: XCTUnwrap(db.next(selected)), repo: selected)
    }
    func testBatchImportAndSharingPreserveExistingChoices() throws {
        let new = GitHubRepository(id: "R2", name: "sample/kitchen")
        let local = GitHubRepository(id: "R3", name: "sample/shop")
        try db.select([repo, new], shared: true)
        try db.select([new, local], shared: false)
        var rows = try db.selections()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.filter(\.shared).map(\.id), [new.id])
        let epochs = rows.map(\.epoch)
        try db.share([new.id, local.id], enabled: true)
        rows = try db.selections()
        XCTAssertEqual(Set(rows.filter(\.shared).map(\.id)), [new.id, local.id])
        try db.share([repo.id, new.id], enabled: false)
        rows = try db.selections()
        XCTAssertEqual(rows.filter(\.shared).map(\.id), [local.id])
        XCTAssertEqual(rows.map(\.epoch), epochs)
        try db.lock()
        XCTAssertThrowsError(try db.select([new], shared: true))
        try db.share([repo.id, local.id], enabled: true)
        XCTAssertTrue(try db.selections().allSatisfy { !$0.shared })
    }

    func testGitHubOnlySourceAndLiveSourceChanges() throws {
        try commit([(item(), passage("inline", "Fixture comment", kind: .inline))])
        try db.share(repo.id, enabled: true)
        let service = AgentLibrary(directory: root)
        try ActivitySourceStore.save([.github], directory: root)
        XCTAssertEqual(try service.call("search_activity", arguments: ["source": "github"])["total"] as? Int, 1)
        try ActivitySourceStore.save([.coding], directory: root)
        XCTAssertThrowsError(try service.call("get_github_item", arguments: ["item_id": "PR1"]))
        XCTAssertEqual(try service.call("search_activity", arguments: [:])["total"] as? Int, 0)
        try ActivitySourceStore.save([.github], directory: root)
        XCTAssertEqual(try service.call("search_activity", arguments: ["source": "github"])["total"] as? Int, 1)
    }

    func testScopeChecksCoverSearchDirectReadsPaginationAndEmbeddings() throws {
        try commit([
            (item(), passage("review", "", kind: .review)),
            (item(), passage("inline", "Installed clients retry the old callback", kind: .inline)),
            (item(), passage("foreign", "forbidden-reply-marker", actor: "OTHER")),
            (item("mention"), passage("mention", "forbidden-mention", actor: "OTHER")),
        ])
        XCTAssertEqual(try db.timeline("PR1", shared: false).count, 2)
        XCTAssertTrue(try db.search("forbidden", shared: false).isEmpty)
        XCTAssertTrue(try db.embeddingChunks(shared: false).allSatisfy { !$0.text.contains("forbidden") })
        XCTAssertTrue(try db.embeddingChunks(shared: true).isEmpty)
        let agent = AgentLibrary(directory: root)
        XCTAssertEqual(try agent.call("search_activity", arguments: ["source": "github"])["total"] as? Int, 0)
        XCTAssertThrowsError(try agent.call("get_github_item", arguments: ["item_id": "PR1"]))
        try db.share(repo.id, enabled: true)
        let result = try agent.call("search_activity", arguments: ["source": "github", "query": "callback", "mode": "keyword"])
        XCTAssertEqual(result["total"] as? Int, 1)
        let hit = try XCTUnwrap((result["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(hit["item_id"] as? String, "PR1")
        let citation = try XCTUnwrap((hit["citations"] as? [[String: Any]])?.first)
        XCTAssertEqual(citation["passage_id"] as? String, "inline")
        let read = try agent.call("get_github_item", arguments: ["item_id": "PR1", "passage_id": "inline", "limit": 1])
        XCTAssertEqual((read["items"] as? [[String: Any]])?.first?["original_line"] as? Int, 42)
        try db.share(repo.id, enabled: false)
        XCTAssertThrowsError(try agent.call("get_github_item", arguments: ["item_id": "PR1", "expected_revision": read["revision"]!]))
        XCTAssertThrowsError(
            try agent.call(
                "search_activity",
                arguments: ["source": "github", "query": "callback", "expected_revision": result["library_revision"]!]))
        try db.share(repo.id, enabled: true)
        try db.lock()
        XCTAssertTrue(try db.search(shared: false).isEmpty)
        XCTAssertThrowsError(try db.connect(.init(id: "another", login: "gardener")))
        try db.connect(viewer, verified: [repo])
        XCTAssertFalse(try db.selections()[0].shared)
        XCTAssertEqual(try db.search(shared: false).count, 1)
    }
    func testStableIDsEditsDatesReconciliationAndLatePages() throws {
        let h = item()
        try commit([
            (h, passage("A", "ancient comment", daysAgo: 120)), (h, passage("B", "", kind: .review)),
            (h, passage("C", "recent line", kind: .inline)),
        ])
        XCTAssertEqual(
            try db.search("approved", shared: false, action: "review", from: date, to: date.addingTimeInterval(1)).first?.id, h.id)
        XCTAssertTrue(try db.search("ancient", shared: false, from: date.addingTimeInterval(-60)).isEmpty)
        XCTAssertEqual(try db.search("retry", shared: false).first?.citations.first?.id, "C")
        XCTAssertTrue(try db.search("#12", shared: false).isEmpty)
        XCTAssertEqual(try db.search("#12", shared: false, repository: repo.name).first?.id, h.id)
        let renamed = GitHubRepository(id: repo.id, name: "sample/renamed")
        try db.verifyAccess([renamed], identity: viewer, now: date)
        XCTAssertEqual(try db.search("https://github.com/sample/renamed/pull/12#discussion", shared: false).first?.id, h.id)
        XCTAssertTrue(try db.search("sample/garden#12", shared: false).isEmpty)
        try commit([(h, passage("A", "corrected content"))], missing: ["C", "B"])
        XCTAssertTrue(try db.search("ancient", shared: false).isEmpty)
        XCTAssertEqual(try db.search("correct", shared: false).first?.citations.first?.id, "A")
        try commit([], missing: ["A"])
        XCTAssertTrue(try db.search(shared: false).isEmpty)
        let old = try db.selections()[0]
        try db.begin(old, now: date)
        let late = try XCTUnwrap(db.next(old))
        try db.share(repo.id, enabled: true)
        try db.pause(repo.id, enabled: true)
        XCTAssertThrowsError(try db.commit(GitHubPage(), work: late, repo: old))
        try db.remove(repo.id)
        try db.select(renamed)
        XCTAssertThrowsError(try db.commit(GitHubPage(), work: late, repo: old))
        XCTAssertFalse(try db.selections()[0].shared)
        try commit([(h, passage("persist", "paused snapshot"))])
        try db.pause(repo.id, enabled: true)
        XCTAssertEqual(try db.search("paused", shared: false).count, 1)
        try db.verifyAccess([], identity: viewer, now: date)
        XCTAssertTrue(try db.selections().isEmpty)
        XCTAssertTrue(try db.timeline(h.id, shared: false).isEmpty)
        XCTAssertTrue(try db.db.rows("SELECT id FROM github_text").isEmpty)
    }
    func testHybridCitationUsesMatchingPartOfLongCommentAndDropsStaleText() throws {
        let body =
            String(repeating: "The initial investigation continued. ", count: 110) + "Late correction about callback registration."
        let header = item()
        try commit([(header, passage("long", body))])
        let chunks = try db.embeddingChunks(shared: false)
        let match = try XCTUnwrap(chunks.last)
        func semantic() throws -> [GitHubHit] {
            try db.merge(
                "decision", keywords: [], chunks: [(match, 0.9)], shared: false,
                repository: repo.name, type: "pr", action: "comment", from: nil, to: nil)
        }
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(try semantic().first?.citations.first?.text.contains("Late correction") == true)
        try commit([(header, passage("long", "Updated wording."))])
        XCTAssertTrue(try semantic().isEmpty)
        try db.deferRequests(until: date.addingTimeInterval(3600))
        db = try GitHubArchive(directory: root.appendingPathComponent("GitHub"))
        XCTAssertEqual(try db.retryAfter, date.addingTimeInterval(3600))
        try db.disconnect()
        XCTAssertNil(try db.retryAfter)
    }

    func testResumesQueueAndPartialSearchCannotAdvanceCoverage() throws {
        let selected = try db.selections()[0]
        try db.begin(selected, now: date)
        let work = try XCTUnwrap(db.next(selected))
        db = try GitHubArchive(directory: root.appendingPathComponent("GitHub"))
        XCTAssertEqual(try db.next(selected)?.job, work.job)
        var partial = GitHubPage()
        partial.partial = true
        try db.commit(partial, work: work, repo: selected)
        XCTAssertThrowsError(try db.commit(partial, work: work, repo: selected))
        while let job = try db.next(selected) { try db.commit(.init(), work: job, repo: selected) }
        XCTAssertNil(try db.selections()[0].lastSuccess)
        XCTAssertTrue(try db.selections()[0].status.contains("Partial"))
        try db.begin(selected, now: date)
        while let job = try db.next(selected) { try db.commit(.init(), work: job, repo: selected) }
        XCTAssertEqual(try db.selections()[0].lastSuccess, date)
    }
}
