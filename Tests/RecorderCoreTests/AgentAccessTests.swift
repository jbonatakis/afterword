#if canImport(XCTest)
import XCTest
#endif
import AVFoundation
@testable import RecorderCore

final class AgentAccessTests: XCTestCase {
    var temporary: URL!
    var root: URL!
    var state: URL!
    var service: AgentLibrary!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        root = temporary.appendingPathComponent("Recordings"); state = temporary.appendingPathComponent("State")
        try PrivateFiles.directory(root)
        try AgentAccessStore.save(.init(enabled: true, folders: [root.path]), directory: state)
        service = AgentLibrary(directory: state)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }
    @discardableResult func fixture(_ name: String = "Call-2026-11-13_12-00-00", text: String = "Ship the café project.", run: String = "first", created: String = "2026-11-13T15:00:00Z") throws -> URL {
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
        let document = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "test", language: "auto", segments: [
            .init(source: .microphone, start: 0, end: 1, text: "Can we decide?", timing: "word"),
            .init(source: .system, start: 2, end: 3, text: text, timing: "word"),
            .init(source: .microphone, start: 4, end: 5, text: "Agreed.", timing: "word")])
        let folder = call.appendingPathComponent("Transcripts/" + run)
        try PrivateFiles.directory(folder)
        var object = try AgentJSON.object(document) as! [String: Any]; object["createdAt"] = created
        let url = folder.appendingPathComponent("Transcript.json")
        try PrivateFiles.atomicWrite(AgentJSON.data(object), to: url)
        return call
    }
    func items(_ result: [String: Any]) -> [[String: Any]] { result["items"] as? [[String: Any]] ?? [] }
    func first() throws -> [String: Any] { try XCTUnwrap(items(service.call("list_calls", arguments: [:])).first) }
    func id() throws -> String { try XCTUnwrap(first()["call_id"] as? String) }

    func testAccessDefaultsOffAndRevokesAlreadyRunningHelper() throws {
        try fixture()
        XCTAssertEqual(try AgentAccessStore.load(directory: temporary.appendingPathComponent("Missing")).enabled, false)
        XCTAssertEqual(try items(service.call("list_calls", arguments: [:])).count, 1)
        try AgentAccessStore.save(.init(enabled: false, folders: [root.path]), directory: state)
        XCTAssertThrowsError(try service.call("list_calls", arguments: [:]))
        try AgentAccessStore.save(.init(enabled: true), directory: state)
        XCTAssertTrue(try items(service.call("list_calls", arguments: [:])).isEmpty)
    }
    func testSavedNamesVersionsSearchAndReferencesWithoutChangingSources() throws {
        let call = try fixture()
        try CallDetailsStore.writeInitial(.init(title: "Planning", participants: ["Corinne"], tags: ["Roadmap"]), to: call.appendingPathComponent("CallDetails.json"))
        let before = try Data(contentsOf: call.appendingPathComponent("Transcripts/first/Transcript.json"))
        let original = try first(), callID = try id()
        XCTAssertEqual(original["title"] as? String, "Planning")
        let transcript = try service.call("get_transcript", arguments: ["call_id": callID])
        XCTAssertEqual(items(transcript).map { $0["speaker"] as? String }, ["Recorder", "Corinne", "Recorder"])
        XCTAssertTrue(try XCTUnwrap(items(transcript)[1]["reference"] as? String).contains("00:00:02"))
        XCTAssertEqual(try items(service.call("search_transcripts", arguments: ["query": "CAFE", "participant": "cor", "tag": "roadmap"])).count, 1)
        XCTAssertEqual(try items(service.call("search_transcripts", arguments: ["query": "Recorder"])).count, 2)
        let details = try service.call("get_call", arguments: ["call_id": callID])
        let versionID = try XCTUnwrap((details["versions"] as? [[String: Any]])?.first?["version_id"] as? String)
        try fixture(text: "A revised plan.", run: "second", created: "2026-11-14T15:00:00Z")
        XCTAssertTrue(try items(service.call("search_transcripts", arguments: ["query": "café"])).isEmpty)
        XCTAssertEqual(try items(service.call("search_transcripts", arguments: ["query": "café", "all_versions": true])).count, 1)
        XCTAssertEqual(try items(service.call("get_transcript", arguments: ["call_id": callID, "version_id": versionID]))[1]["text"] as? String, "Ship the café project.")
        XCTAssertEqual(try Data(contentsOf: call.appendingPathComponent("Transcripts/first/Transcript.json")), before)
    }
    func testParticipantChangesInvalidateRevisionsAndUseCurrentNames() throws {
        let call = try fixture()
        let details = call.appendingPathComponent("CallDetails.json")
        try CallDetailsStore.writeInitial(.init(participants: ["Avery"]), to: details)
        let callID = try id(), original = try XCTUnwrap(first()["revision"] as? String)
        try CallDetailsStore.writeInitial(.init(participants: ["Corinne"]), to: details)
        XCTAssertThrowsError(try service.call("get_transcript", arguments: ["call_id": callID, "expected_revision": original]))
        XCTAssertEqual(try items(service.call("get_transcript", arguments: ["call_id": callID]))[1]["speaker"] as? String, "Corinne")
        try CallDetailsStore.writeInitial(.init(), to: details)
        XCTAssertEqual(try items(service.call("get_transcript", arguments: ["call_id": callID]))[1]["speaker"] as? String, "Other participants")
    }
    func testStableIdentityAcrossRestartTitleAndDirectoryRename() throws {
        let call = try fixture(), original = try id()
        try CallDetailsStore.writeInitial(.init(title: "New title"), to: call.appendingPathComponent("CallDetails.json"))
        service = AgentLibrary(directory: state)
        XCTAssertEqual(try id(), original)
        try FileManager.default.moveItem(at: call, to: root.appendingPathComponent("Renamed"))
        XCTAssertEqual(try id(), original)
    }
    func testPaginationRangesAndRevisionGuard() throws {
        try fixture()
        let callID = try id()
        let page = try service.call("get_transcript", arguments: ["call_id": callID, "limit": 1])
        XCTAssertEqual(page["total"] as? Int, 3); XCTAssertEqual(page["next_offset"] as? Int, 1)
        let next = try service.call("get_transcript", arguments: ["call_id": callID, "offset": 1, "limit": 1])
        XCTAssertEqual(items(next)[0]["start_seconds"] as? Double, 2)
        XCTAssertEqual(try items(service.call("get_transcript", arguments: ["call_id": callID, "start_seconds": 1.5, "end_seconds": 3.5])).count, 1)
        XCTAssertThrowsError(try service.call("get_transcript", arguments: ["call_id": callID, "start_seconds": 10, "end_seconds": 2]))
        let listed = try service.call("list_calls", arguments: [:])
        try fixture("Call-2026-11-14_10-00-00")
        XCTAssertThrowsError(try service.call("list_calls", arguments: ["offset": 1, "expected_revision": listed["library_revision"]!]))
        XCTAssertEqual(try items(service.call("list_calls", arguments: ["from": "2026-11-14T00:00:00-05:00", "to": "2026-11-15T00:00:00-05:00"])).count, 1)
    }
    func testIndependentDurableChangeCheckpointsAndRemoval() throws {
        let call = try fixture()
        let baseline = try service.call("get_changes", arguments: [:])
        let cursor = try XCTUnwrap(baseline["cursor"] as? String)
        let firstID = try id()
        try CallDetailsStore.writeInitial(.init(title: "Changed"), to: call.appendingPathComponent("CallDetails.json"))
        service = AgentLibrary(directory: state)
        let one = try service.call("get_changes", arguments: ["cursor": cursor])
        let two = try service.call("get_changes", arguments: ["cursor": cursor])
        XCTAssertEqual(try AgentJSON.data(one), try AgentJSON.data(two))
        XCTAssertEqual((one["changes"] as? [[String: Any]])?.first?["change"] as? String, "updated")
        let updated = try XCTUnwrap(one["cursor"] as? String)
        try FileManager.default.removeItem(at: call)
        let removed = try service.call("get_changes", arguments: ["cursor": updated])
        XCTAssertEqual((removed["changes"] as? [[String: Any]])?.first?["call_id"] as? String, firstID)
        XCTAssertEqual((removed["changes"] as? [[String: Any]])?.first?["change"] as? String, "removed")
        XCTAssertThrowsError(try service.call("get_changes", arguments: ["cursor": String(repeating: "0", count: 64)]))
        XCTAssertThrowsError(try service.call("get_changes", arguments: ["cursor": "../../Access"]))
    }
    func testChangePaginationFreezesSnapshotUntilCheckpoint() throws {
        try fixture(); try fixture("Call-2026-11-14_10-00-00")
        let first = try service.call("get_changes", arguments: ["limit": 1])
        XCTAssertNil(first["cursor"])
        let token = try XCTUnwrap(first["next_page_token"] as? String)
        try fixture("Call-2026-11-15_10-00-00")
        let last = try service.call("get_changes", arguments: ["page_token": token, "limit": 1])
        XCTAssertEqual(last["total"] as? Int, 2)
        let changes = try service.call("get_changes", arguments: ["cursor": try XCTUnwrap(last["cursor"] as? String)])
        XCTAssertEqual((changes["changes"] as? [[String: Any]])?.count, 1)
    }
    func testUnavailableFolderDoesNotTurnEveryCallIntoDeletion() throws {
        try fixture()
        let baseline = try service.call("get_changes", arguments: [:])
        try FileManager.default.moveItem(at: root, to: temporary.appendingPathComponent("Offline"))
        XCTAssertThrowsError(try service.call("get_changes", arguments: ["cursor": baseline["cursor"]!]))
    }
    func testConfinesSymlinkedCallsAndTranscriptDirectories() throws {
        let call = try fixture()
        let outside = temporary.appendingPathComponent("Outside")
        try FileManager.default.moveItem(at: call, to: outside)
        try FileManager.default.createSymbolicLink(at: call, withDestinationURL: outside)
        XCTAssertTrue(try items(service.call("list_calls", arguments: [:])).isEmpty)
        try FileManager.default.removeItem(at: call)
        let inside = try fixture()
        try FileManager.default.removeItem(at: inside.appendingPathComponent("Transcripts"))
        try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("Transcripts"), withDestinationURL: outside.appendingPathComponent("Transcripts"))
        XCTAssertFalse(try XCTUnwrap(first()["has_transcript"] as? Bool))
        XCTAssertThrowsError(try service.call("get_transcript", arguments: ["call_id": try id()]))
    }
    func testUnreadableCallOrTranscriptRunDoesNotReportRemoval() throws {
        let call = try fixture()
        let baseline = try service.call("get_changes", arguments: [:])
        let args: [String: Any] = ["cursor": baseline["cursor"]!]
        for directory in [call, call.appendingPathComponent("Transcripts/first")] {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            XCTAssertThrowsError(try service.call("get_changes", arguments: args))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let unchanged = try service.call("get_changes", arguments: args)
        XCTAssertEqual((unchanged["changes"] as? [[String: Any]])?.count, 0)
    }
    func testCorruptLatestVersionIsExplicitAndDoesNotFallBack() throws {
        let call = try fixture()
        let folder = call.appendingPathComponent("Transcripts/broken")
        try PrivateFiles.directory(folder)
        try Data("broken".utf8).write(to: folder.appendingPathComponent("Transcript.json"))
        let callID = try id()
        XCTAssertThrowsError(try service.call("get_transcript", arguments: ["call_id": callID]))
        let search = try service.call("search_transcripts", arguments: ["query": "café"])
        XCTAssertEqual(search["unreadable_call_ids"] as? [String], [callID])
        XCTAssertEqual(try items(service.call("search_transcripts", arguments: ["query": "café", "all_versions": true])).count, 1)
    }
    func testValidationRejectsWrongTypesHugeLimitsAndUnknownPaths() throws {
        for args: [String: Any] in [["limit": 0], ["limit": 101], ["limit": true], ["offset": 0.5], ["offset": -1], ["limit": "10"], ["path": root.path], ["query": String(repeating: "x", count: 8193)], ["from": "yesterday"]] {
            XCTAssertThrowsError(try service.call("list_calls", arguments: args))
        }
        XCTAssertThrowsError(try service.call("search_transcripts", arguments: [:]))
        XCTAssertThrowsError(try service.call("search_transcripts", arguments: ["query": " "]))
        XCTAssertThrowsError(try service.call("get_transcript", arguments: ["call_id": "../../secret"]))
    }
    func testRPCNegotiationDiscoveryAndReadOnlyErrors() throws {
        let server = AgentRPCServer(directory: state)
        func request(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
            let response = try XCTUnwrap(server.handle(AgentJSON.data(["jsonrpc": "2.0", "id": "request", "method": method, "params": params])))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        }
        XCTAssertTrue(try request("tools/list")["error"] != nil)
        let response = try request("initialize", params: ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        XCTAssertEqual((response["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        XCTAssertNil(try server.handle(AgentJSON.data(["jsonrpc": "2.0", "method": "notifications/initialized"])))
        let tools = try request("tools/list")["result"] as? [String: Any]
        XCTAssertEqual((tools?["tools"] as? [[String: Any]])?.count, 5)
        XCTAssertTrue(try request("tools/call", params: ["name": "delete_call"])["error"] != nil)
        try AgentAccessStore.save(.init(), directory: state)
        let failure = try request("tools/call", params: ["name": "list_calls"])["result"] as? [String: Any]
        XCTAssertEqual(failure?["isError"] as? Bool, true)
        XCTAssertNil(server.handle(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{}}".utf8)))
        let invalid = try XCTUnwrap(server.handle(Data("garbage".utf8)))
        XCTAssertTrue(String(decoding: invalid, as: UTF8.self).contains("-32700"))
    }
}
