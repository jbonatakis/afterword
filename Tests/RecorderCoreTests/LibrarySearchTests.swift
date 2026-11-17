#if canImport(XCTest)
import XCTest
#endif
import AVFoundation
@testable import RecorderCore

final class LibrarySearchTests: XCTestCase {
    var temporary: URL!
    var root: URL!
    var cache: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("search-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        root = temporary.appendingPathComponent("Recordings"); cache = temporary.appendingPathComponent("Cache")
        try PrivateFiles.directory(root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }
    @discardableResult private func fixture(_ name: String = "Call-2026-11-13_12-00-00", text: [String] = ["Discuss the café", "project tomorrow"], run: String = "first", date: String = "2026-11-13T15:00:00Z") throws -> URL {
        let call = root.appendingPathComponent(name)
        try PrivateFiles.directory(call)
        let audio = call.appendingPathComponent("Mixed.m4a")
        if !FileManager.default.fileExists(atPath: audio.path) {
            let caf = call.appendingPathComponent("fixture.caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            do {
                let file = try AVAudioFile(forWriting: caf, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
                buffer.frameLength = 1600; buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
                try file.write(from: buffer)
            }
            try FileManager.default.moveItem(at: caf, to: audio)
        }
        let input = TranscriptionInput(tracks: [.init(source: .microphone, url: audio), .init(source: .system, url: audio)], outputDirectory: call, name: name)
        let document = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "test", language: "auto", segments: text.enumerated().map {
            .init(source: $0.offset.isMultiple(of: 2) ? .microphone : .system,
                  start: Double($0.offset * 10), end: Double($0.offset * 10 + 3), text: $0.element, timing: "word")
        })
        let folder = call.appendingPathComponent("Transcripts/" + run)
        try PrivateFiles.directory(folder)
        var object = try AgentJSON.object(document) as! [String: Any]; object["createdAt"] = date
        try PrivateFiles.atomicWrite(AgentJSON.data(object), to: folder.appendingPathComponent("Transcript.json"))
        return call
    }
    private func index() throws -> LibrarySearchIndex { try LibrarySearchIndex(roots: [root], confined: true, directory: cache) }
    private func service() throws -> AgentLibrary {
        let state = temporary.appendingPathComponent("MCP")
        try AgentAccessStore.save(.init(enabled: true, folders: [root.path]), directory: state)
        return AgentLibrary(directory: state)
    }
    func testDirectoryRenameRefreshesExistingTranscriptSearchAndAgentRevision() throws {
        let raw = "invite@example.test"
        let folder = try fixture(text: ["Hello", "Discuss the budget"])
        try fixture("Unrelated")
        let stored = folder.appendingPathComponent("Transcripts/first/Transcript.json")
        let bytes = try Data(contentsOf: stored)
        let attendee = CallAttendee(id: "guest", name: raw, email: raw)
        try CallDetailsStore.writeInitial(.init(participants: [raw], attendees: [attendee]), to: CallDetailsStore.url(for: folder, isDirectory: true))
        let peopleURL = temporary.appendingPathComponent("People.json")
        let index = try LibrarySearchIndex(roots: [root], confined: true, directory: cache, peopleURL: peopleURL)
        try index.synchronize()
        let service = try service(), id = try AgentJSON.identity(folder)
        func remoteTranscript() throws -> [String: Any] { try service.call("get_transcript", arguments: ["call_id": id]) }
        let before = try remoteTranscript()
        XCTAssertEqual((before["items"] as? [[String: Any]])?.last?["speaker"] as? String, raw)
        var people = PeopleDirectory()
        try people.update(.init(id: "guest", name: "Pat Morgan", emails: ["pat@example.test", raw]))
        try people.save(to: peopleURL)
        let calls = try index.synchronize()
        XCTAssertEqual(index.lastLoadedCount, 1)
        let renamed = try XCTUnwrap(calls.first { $0.id == folder.path })
        XCTAssertTrue(renamed.readableText(for: renamed.transcripts[0])?.contains("Pat Morgan · ") == true)
        XCTAssertEqual(renamed.details.participants, [raw])
        XCTAssertEqual(try index.search("Morgan").count, 1)
        let after = try remoteTranscript()
        XCTAssertEqual((after["items"] as? [[String: Any]])?.last?["speaker"] as? String, "Pat Morgan")
        XCTAssertNotEqual((before["call"] as? [String: Any])?["revision"] as? String, (after["call"] as? [String: Any])?["revision"] as? String)
        let search = try service.call("search_transcripts", arguments: ["query": "budget", "speaker": "Pat Morgan"])
        XCTAssertEqual(search["total"] as? Int, 1)
        let reopened = try LibrarySearchIndex(roots: [root], confined: true, directory: cache, peopleURL: peopleURL)
        try reopened.synchronize()
        XCTAssertEqual(reopened.lastLoadedCount, 0)
        XCTAssertEqual(try reopened.search("Morgan").count, 1)
        XCTAssertEqual(try Data(contentsOf: stored), bytes)
    }
    func testHybridRetrievalPreservesQuotesSpeakerScopeAndHistory() throws {
        try fixture("CallA", text: ["The database migration requires postponing the rollout.", "Lunch is sandwiches."], run: "new", date: "2026-11-14T15:00:00Z")
        try fixture("CallA", text: ["The ancient lighthouse needs repairs."], run: "old")
        try fixture("CallB", text: ["The museum closes early.", "The lobby is quiet."])
        let embeddingRoot = cache.appendingPathComponent("Embeddings")
        var settings = EmbeddingSettings(); settings.enabled = true; settings.modelID = EmbeddingModel.catalog[0].id
        try settings.save(directory: embeddingRoot)
        try PrivateFiles.directory(EmbeddingSettings.modelRoot(embeddingRoot))
        try Data().write(to: ModelStore.ownedURL(settings.model.asset, root: EmbeddingSettings.modelRoot(embeddingRoot)))
        let index = try index()
        index.semantic = SemanticSearchEngine(directory: embeddingRoot) { texts, model, _, _ in
            texts.map { text in
                let axis = text.contains("lighthouse") || text.contains("coastal tower") ? 2 : text.contains("database") || text.contains("deployment delay") ? 0 : 1
                var vector = Array(repeating: Float(0), count: model.dimensions); vector[axis] = 1; return vector
            }
        }
        try index.synchronize()
        let deadline = Date().addingTimeInterval(3)
        while index.semanticStatus(allVersions: true).state == "indexing", Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(index.semanticStatus().state, "ready")
        XCTAssertTrue(try index.search("deployment delay").isEmpty)
        let hybrid = try index.hybridSearch("deployment delay")
        XCTAssertEqual(hybrid.status.mode, "hybrid"); XCTAssertEqual(hybrid.hits.count, 1)
        XCTAssertTrue(hybrid.hits[0].recordingID.hasSuffix("CallA"))
        XCTAssertTrue(try index.hybridSearch("deployment delay \"nonexistent phrase\"").hits.isEmpty)
        XCTAssertEqual(try index.hybridSearch("deployment delay \"database migration\"").hits.count, 1)
        XCTAssertEqual(try index.hybridSearch("deployment delay \"CallA\"").hits.count, 1)
        XCTAssertEqual(try index.hybridSearch("deployment delay \"Recorder\"").hits.count, 1)
        XCTAssertTrue(try index.hybridSearch("deployment delay", speaker: "Other participants").hits.isEmpty)
        XCTAssertEqual(try index.hybridSearch("deployment delay", speaker: "Recorder").hits.count, 1)
        let otherID = index.calls.first { $0.recording.sourceName == "CallB" }!.id
        XCTAssertTrue(try index.hybridPassages("deployment delay", allVersions: true, allowed: [otherID]).passages.isEmpty)
        XCTAssertTrue(try index.hybridSearch("coastal tower").hits.isEmpty)
        XCTAssertEqual(try index.hybridSearch("coastal tower", allVersions: true).hits.count, 1)
        XCTAssertTrue(try index.hybridSearch("deployment delay", keywordOnly: true).hits.isEmpty)
        XCTAssertEqual(try index.hybridSearch("deployment delay").revision, hybrid.revision)
    }
    func testSpeakerFilterMatchesSpeechAndKeepsContextSeparate() throws {
        try fixture(text: ["Approve the launch", "Send the budget", "Launch tomorrow"])
        let service = try service()
        let own = try service.call("search_transcripts", arguments: ["query": "launch", "speaker": "Recorder"])
        let items = own["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 1)
        let matches = items[0]["matches"] as! [[String: Any]]
        XCTAssertTrue(matches.allSatisfy { $0["speaker"] as? String == "Recorder" })
        let other = try service.call("search_transcripts", arguments: ["query": "launch", "speaker": "Other participants"])
        XCTAssertEqual(other["total"] as? Int, 0)
        let combined = try service.call("search_transcripts", arguments: ["query": "launch budget", "speaker": "Recorder"])
        XCTAssertEqual(combined["total"] as? Int, 0)
        let status = own["search_status"] as! [String: Any]
        XCTAssertEqual(status["mode"] as? String, "keyword")
        XCTAssertThrowsError(try service.call("search_transcripts", arguments: ["query": "launch", "mode": "invalid"]))
    }
    func testQueryWordsPhrasesPrefixesAccentsAndSafeSyntax() throws {
        XCTAssertTrue(LibrarySearchQuery("  PROJECT cafe  ").matches("Café is a project"))
        XCTAssertFalse(LibrarySearchQuery("\"cafe project\"").matches("Café is a project"))
        XCTAssertTrue(LibrarySearchQuery("\"cafe project\"").matches("The café project"))
        XCTAssertTrue(LibrarySearchQuery("proj*").matches("project"))
        XCTAssertTrue(LibrarySearchQuery("proj").matches("project"))
        XCTAssertFalse(LibrarySearchQuery("\"proj\"").matches("project"))
        XCTAssertTrue(LibrarySearchQuery("\"unclosed phrase").matches("unclosed phrase"))
        XCTAssertFalse(LibrarySearchQuery("OR").matches("project"))
        XCTAssertNil(LibrarySearchQuery("***").expression)
        let text = "☕️ CAFE\u{301} and projects"
        let ranges = LibrarySearchQuery("caf proj").highlightRanges(in: text)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["CAFE\u{301}", "projects"])
    }
    func testSharedSearchDefaultsToLatestAndFindsPhrasesAcrossParagraphs() throws {
        try fixture()
        let index = try index(); try index.synchronize()
        XCTAssertEqual(try index.search("  PROJECT cafe  ").count, 1)
        let phrase = try XCTUnwrap(index.search("\"cafe project\"").first)
        XCTAssertEqual(phrase.paragraphIDs, [0, 1])
        XCTAssertEqual(try index.search("proj*").count, 1)
        XCTAssertEqual(try index.search("proj").count, 1)
        XCTAssertTrue(try index.search("\"proj\"").isEmpty)
        XCTAssertTrue(try index.search("title:unknown OR *").isEmpty)
        let service = try service()
        for query in ["  PROJECT cafe  ", "\"cafe project\"", "proj*", "proj", "rec"] {
            XCTAssertEqual(try service.call("list_calls", arguments: ["query": query])["total"] as? Int, 1)
            XCTAssertEqual(try service.call("search_transcripts", arguments: ["query": query])["total"] as? Int, 1)
        }
        try fixture(text: ["Entirely revised wording"], run: "second", date: "2026-11-14T15:00:00Z")
        try index.synchronize()
        XCTAssertTrue(try index.search("cafe").isEmpty)
        XCTAssertEqual(try index.search("cafe", allVersions: true).count, 1)
        XCTAssertEqual(try service.call("list_calls", arguments: ["query": "cafe"])["total"] as? Int, 0)
        XCTAssertEqual(try service.call("list_calls", arguments: ["query": "cafe", "all_versions": true])["total"] as? Int, 1)
    }
    func testTypingPrefixesFindsNamesAndTextWithMatchingPassagesInLibraryAndMCP() throws {
        let named = try fixture()
        try CallDetailsStore.writeInitial(.init(participants: ["Bellamy"]), to: named.appendingPathComponent("CallDetails.json"))
        let spoken = try fixture("Call-2026-11-14_10-00-00", text: ["Bellamy approved the plan."])
        let index = try index(); try index.synchronize()
        let service = try service()
        for query in ["bellam", "bellamy", "  BELLAM  ", "bellam*"] {
            let hits = try index.search(query)
            XCTAssertEqual(Set(hits.map(\.recordingID)), Set([named.path, spoken.path]))
            XCTAssertEqual(hits.first { $0.recordingID == named.path }?.paragraphIDs, [1])
            XCTAssertTrue(hits.first { $0.recordingID == spoken.path }?.snippet?.contains("Bellamy") == true)
            XCTAssertEqual(try service.call("list_calls", arguments: ["query": query])["total"] as? Int, 2)
            XCTAssertEqual(try service.call("search_transcripts", arguments: ["query": query])["total"] as? Int, 2)
        }
        XCTAssertEqual(try index.search("bellam proj").map(\.recordingID), [named.path])
        XCTAssertEqual(try service.call("search_transcripts", arguments: ["query": "bellam proj"])["total"] as? Int, 1)
        for query in ["\"bellam\"", "ellam"] {
            XCTAssertTrue(try index.search(query).isEmpty)
            XCTAssertEqual(try service.call("search_transcripts", arguments: ["query": query])["total"] as? Int, 0)
        }
        let text = "Bellamy approved the plan."
        XCTAssertEqual(LibrarySearchQuery("bellam").highlightRanges(in: text).map { (text as NSString).substring(with: $0) }, ["Bellamy"])
        try index.synchronize(); XCTAssertEqual(index.lastLoadedCount, 0)
    }
    func testIncrementalRefreshRestartRenameAndDeletionWithoutSourceWrites() throws {
        let call = try fixture()
        try fixture("Call-2026-11-14_10-00-00", text: ["Separate call"])
        let source = call.appendingPathComponent("Transcripts/first/Transcript.json"), before = try Data(contentsOf: source)
        let index = try index(); try index.synchronize(); XCTAssertEqual(index.lastLoadedCount, 2)
        let revision = try XCTUnwrap(index.calls.first { $0.recording.url.path == call.path }).revision
        try index.synchronize(); XCTAssertEqual(index.lastLoadedCount, 0)
        let restarted = try self.index(); try restarted.synchronize(); XCTAssertEqual(restarted.lastLoadedCount, 0)
        try CallDetailsStore.writeInitial(.init(title: "Launch", participants: ["Avery"]), to: call.appendingPathComponent("CallDetails.json"))
        try index.synchronize(); XCTAssertEqual(index.lastLoadedCount, 1)
        XCTAssertEqual(try index.search("Avery").count, 1)
        XCTAssertNotEqual(try XCTUnwrap(index.calls.first { $0.recording.url.path == call.path }).revision, revision)
        // A second reader must not mix a stale snapshot with another writer's index.
        XCTAssertThrowsError(try restarted.search("Avery"))
        try restarted.synchronize(); XCTAssertEqual(restarted.lastLoadedCount, 0)
        let moved = root.appendingPathComponent("Renamed")
        try FileManager.default.moveItem(at: call, to: moved)
        try index.synchronize(); XCTAssertEqual(index.lastLoadedCount, 1)
        XCTAssertEqual(try index.search("Launch").first?.recordingID, moved.path)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("Transcripts/first/Transcript.json")), before)
        try FileManager.default.removeItem(at: moved)
        try index.synchronize()
        XCTAssertTrue(try index.search("Launch").isEmpty)
        XCTAssertEqual(index.calls.count, 1)
    }
    func testInPlaceSameSizeEditPreservingMtimeIsDetected() throws {
        let call = try fixture(text: ["alpha"])
        let index = try index(); try index.synchronize()
        let file = call.appendingPathComponent("Transcripts/first/Transcript.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let original = try String(contentsOf: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(original.replacingOccurrences(of: "alpha", with: "bravo").utf8)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
        try index.synchronize(); XCTAssertEqual(index.lastLoadedCount, 1)
        XCTAssertTrue(try index.search("alpha").isEmpty)
        XCTAssertEqual(try index.search("bravo").count, 1)
    }
    func testMergedBoundedPassagesAndPaginationHaveNoDuplicateContext() throws {
        try fixture(text: (0..<20).map { "Project decision number \($0)" })
        let service = try service()
        var offset = 0, paragraphIDs: [Int] = [], revision: String?
        repeat {
            var args: [String: Any] = ["query": "project", "limit": 1, "offset": offset]
            args["expected_revision"] = revision
            let result = try service.call("search_transcripts", arguments: args)
            XCTAssertEqual(result["total"] as? Int, 3)
            revision = result["library_revision"] as? String
            let item = try XCTUnwrap((result["items"] as? [[String: Any]])?.first)
            let context = try XCTUnwrap(item["context"] as? [[String: Any]])
            XCTAssertTrue(context.count <= 8)
            let matches = try XCTUnwrap(item["matches"] as? [[String: Any]])
            XCTAssertEqual(matches.count, context.count)
            paragraphIDs += context.compactMap { $0["paragraph_id"] as? Int }
            offset = result["next_offset"] as? Int ?? -1
        } while offset >= 0
        XCTAssertEqual(paragraphIDs, Array(0..<20))
    }
    func testMetadataRankingAndUntranscribedCalls() throws {
        let titleCall = try fixture(text: ["A plan for tomorrow"])
        let bodyCall = try fixture("Call-2026-11-14_10-00-00", text: ["A launch for tomorrow"])
        try CallDetailsStore.writeInitial(.init(title: "Launch"), to: titleCall.appendingPathComponent("CallDetails.json"))
        let index = try index(); try index.synchronize()
        XCTAssertEqual(try index.search("launch").map(\.recordingID), [titleCall.path, bodyCall.path])
        try FileManager.default.removeItem(at: titleCall.appendingPathComponent("Transcripts"))
        try index.synchronize()
        XCTAssertEqual(try index.search("launch").count, 2)
        XCTAssertEqual(try service().call("search_transcripts", arguments: ["query": "launch"])["total"] as? Int, 1)
    }
    func testCacheIsRebuildableAndFolderScopesStaySeparate() throws {
        try fixture()
        do { let index = try index(); try index.synchronize() }
        let database = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first { $0.pathExtension == "sqlite" })
        try Data("not a sqlite database".utf8).write(to: database)
        let rebuilt = try index(); try rebuilt.synchronize()
        XCTAssertEqual(rebuilt.lastLoadedCount, 1)
        XCTAssertEqual(try rebuilt.search("cafe").count, 1)
        let empty = try LibrarySearchIndex(roots: [], confined: true, directory: cache)
        try empty.synchronize(); XCTAssertTrue(try empty.search("cafe").isEmpty)
    }
}
