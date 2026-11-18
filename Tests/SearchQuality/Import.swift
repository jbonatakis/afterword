// Seed the synthetic sessions through the same Lookback reader and indexer as the app.
import Foundation
import Lookback

@testable import RecorderCore

let reader = ClaudeCodeReader(projectsDirectory: URL(fileURLWithPath: CommandLine.arguments[1]))
let archive = try CodingArchive(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
try archive.addProject("/fixture")
try archive.setEnabled(true)
try archive.synchronize(reader: reader)

// GitHub samples use the same selection, page commit and grant checks as the importer.
struct ReviewExample: Decodable {
    let repository, item, title, reference, text, date: String
    let number: Int
}
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let github = try GitHubArchive(directory: output.appendingPathComponent("GitHub"))
let viewer = GitHubIdentity(id: "fixture-viewer", login: "sample")
try github.connect(viewer)
let examples = try JSONDecoder().decode(
    [ReviewExample].self, from: Data(contentsOf: URL(fileURLWithPath: "Tests/SearchQuality/github.json")))
for (name, group) in Dictionary(grouping: examples, by: \.repository).sorted(by: { $0.key < $1.key }) {
    let repo = GitHubRepository(id: name, name: name)
    try github.select(repo)
    try github.share(repo.id, enabled: true)
    let selected = try github.selections().first { $0.id == name }!
    let now = ISO8601DateFormatter().date(from: "2026-01-15T10:00:00Z")!
    try github.verifyAccess(try github.selections().map(\.repo), identity: viewer, now: now)
    try github.begin(selected, now: now)
    var page = GitHubPage()
    for entry in group {
        let url = "https://github.com/\(name)/pull/\(entry.number)"
        let item = GitHubItem(
            id: entry.item, repositoryID: name, type: "pr", title: entry.title, author: "fixture-teammate", state: "MERGED", url: url,
            number: entry.number)
        let passage = GitHubPassage(
            id: entry.reference, actorID: viewer.id, text: entry.text, url: url + "#pullrequestreview-123", kind: .review,
            date: ISO8601DateFormatter().date(from: entry.date)!, edited: nil, verdict: "COMMENTED", path: nil, line: nil)
        page.entries.append((item, passage))
    }
    while let work = try github.next(selected) {
        try github.commit(page, work: work, repo: selected)
        page = .init()
    }
}
