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

    func testPersonalCallRequiresScopeFolderAndSeparateReadAndWriteGrants() throws {
        try fixture(text: "Design review")
        let other = try fixture("Call-2026-11-14_12-00-00", text: "Gardenias bloom")
        let personal = try XCTUnwrap(RecordingLibraryScanner.scan(roots: [other]).recordings.first)
        let personalID = try AgentJSON.identity(other)
        let baseline = try service.call("get_changes", arguments: [:])
        let page = try service.call("get_changes", arguments: ["limit": 1])
        try CallDetailsStore.setScope(.personal, for: personal)
        let delta = try service.call("get_changes", arguments: ["cursor": baseline["cursor"]!])
        XCTAssertEqual((delta["changes"] as? [[String: Any]])?.first?["change"] as? String, "removed")
        XCTAssertThrowsError(try service.call("get_changes", arguments: ["page_token": page["next_page_token"]!]))
        XCTAssertEqual(try items(service.call("list_calls", arguments: [:])).count, 1)
        XCTAssertThrowsError(try service.call("list_calls", arguments: ["scope": "personal"]))
        var grants = try AgentAccessStore.load(directory: state)
        XCTAssertFalse(grants.allowPersonalCalls)
        grants.allowPersonalCalls = true
        try AgentAccessStore.save(grants, directory: state)
        for tool in ["list_calls", "search_transcripts", "search_activity"] {
            let query = ["query": "gardenias", "mode": "keyword"]
            XCTAssertTrue(try items(service.call(tool, arguments: query)).isEmpty)
            XCTAssertEqual(try items(service.call(tool, arguments: query.merging(["scope": "personal"]) { _, b in b })).count, 1)
        }
        XCTAssertEqual(try items(service.call("search_activity", arguments: [:])).count, 1)
        let request = ["call_id": personalID, "scope": "personal"]
        XCTAssertThrowsError(try service.call("get_call", arguments: ["call_id": personalID]))
        XCTAssertThrowsError(try service.call("get_transcript", arguments: ["call_id": personalID]))
        _ = try service.call("get_transcript", arguments: request)
        let info = try service.call("get_call", arguments: request)
        XCTAssertEqual(info["scope"] as? String, "personal")
        let source = try XCTUnwrap((info["versions"] as? [[String: Any]])?.first?["version_id"] as? String)
        let write: [String: Any] = ["call_id": personalID, "scope": "personal", "source_version_id": source,
                                    "expected_revision": info["revision"]!, "markdown": "Buy potting soil."]
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: write))
        grants.allowSummaryWrites = true
        try AgentAccessStore.save(grants, directory: state)
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: write.filter { $0.key != "scope" }))
        _ = try service.call("save_call_summary", arguments: write)
        XCTAssertTrue(try items(service.call("list_calls", arguments: ["query": "potting"])).isEmpty)
        let changes = try service.call("get_changes", arguments: ["scope": "personal"])
        XCTAssertEqual((changes["changes"] as? [[String: Any]])?.first?["call_id"] as? String, personalID)
        XCTAssertThrowsError(try service.call("get_changes", arguments: ["cursor": changes["cursor"]!]))
        grants.allowPersonalCalls = false
        try AgentAccessStore.save(grants, directory: state)
        XCTAssertThrowsError(try service.call("get_call", arguments: request))
        grants.allowPersonalCalls = true; grants.folders = []
        try AgentAccessStore.save(grants, directory: state)
        XCTAssertThrowsError(try service.call("get_call", arguments: request))
        grants.folders = [root.path]; try AgentAccessStore.save(grants, directory: state)
        try ActivitySourceStore.save([.coding], directory: state)
        XCTAssertThrowsError(try service.call("get_call", arguments: request))
        try ActivitySourceStore.save([.recordings], directory: state)
        try CallDetailsStore.setScope(.work, for: personal)
        XCTAssertThrowsError(try service.call("get_call", arguments: request))
        XCTAssertEqual(try items(service.call("list_calls", arguments: ["query": "potting"])).count, 1)
    }

    func testUnreadablePersonalTranscriptDoesNotBlockWorkBrowse() throws {
        try fixture()
        let folder = try fixture("Call-2026-11-14_12-00-00")
        try CallDetailsStore.writeInitial(.init(scope: .personal), to: folder.appendingPathComponent("CallDetails.json"))
        let run = folder.appendingPathComponent("Transcripts/first")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: run.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: run.path) }
        XCTAssertEqual(try items(service.call("list_calls", arguments: [:])).count, 1)
    }

    func testPersonalScopePreservesLegacyGrantsWhileRetiringUnscopedHelpers() throws {
        let url = state.appendingPathComponent("Access.json")
        try PrivateFiles.atomicWrite(AgentJSON.data(["version": 1, "folders": [root.path], "enabled": true, "allowSummaryWrites": true]), to: url)
        try AgentAccessStore.prepareForPersonalCalls(directory: state)
        let grants = try AgentAccessStore.load(directory: state)
        XCTAssertEqual(grants.version, 2)
        XCTAssertTrue(grants.enabled && grants.allowSummaryWrites)
        XCTAssertEqual(grants.folders, [root.path])
        XCTAssertFalse(grants.allowPersonalCalls)
    }

    func testAccessDefaultsOffAndRevokesAlreadyRunningHelper() throws {
        try fixture()
        XCTAssertEqual(try AgentAccessStore.load(directory: temporary.appendingPathComponent("Missing")).enabled, false)
        XCTAssertEqual(try items(service.call("list_calls", arguments: [:])).count, 1)
        try AgentAccessStore.save(.init(enabled: false, folders: [root.path]), directory: state)
        XCTAssertThrowsError(try service.call("list_calls", arguments: [:]))
        try AgentAccessStore.save(.init(enabled: true), directory: state)
        XCTAssertTrue(try items(service.call("list_calls", arguments: [:])).isEmpty)
    }
    func testRecordingSourceSwitchPreservesGrantsAndRestrictsRunningHelper() throws {
        try fixture()
        let callID = try id()
        let original = try AgentAccessStore.load(directory: state)
        try ActivitySourceStore.save([.github], directory: state)
        XCTAssertEqual(try items(service.call("list_calls", arguments: [:])).count, 0)
        XCTAssertThrowsError(try service.call("get_transcript", arguments: ["call_id": callID]))
        try ActivitySourceStore.save([.recordings], directory: state)
        XCTAssertEqual(try id(), callID)
        XCTAssertEqual(try AgentAccessStore.load(directory: state), original)
        try Data("invalid".utf8).write(to: state.appendingPathComponent("Sources.json"))
        XCTAssertThrowsError(try service.call("list_calls", arguments: [:]))
    }

    func testSavedNamesVersionsSearchAndReferencesWithoutChangingSources() throws {
        let call = try fixture()
        try CallDetailsStore.writeInitial(.init(title: "Planning", participants: ["Corinne"], tags: ["Roadmap"]), to: call.appendingPathComponent("CallDetails.json"))
        let before = try Data(contentsOf: call.appendingPathComponent("Transcripts/first/Transcript.json"))
        let original = try first(), callID = try id()
        XCTAssertEqual(original["title"] as? String, "Planning")
        let transcript = try service.call("get_transcript", arguments: ["call_id": callID])
        XCTAssertEqual(items(transcript).map { $0["speaker"] as? String }, ["You", "Corinne", "You"])
        XCTAssertTrue(try XCTUnwrap(items(transcript)[1]["reference"] as? String).contains("00:00:02"))
        XCTAssertEqual(try items(service.call("search_transcripts", arguments: ["query": "CAFE", "participant": "cor", "tag": "roadmap"])).count, 1)
        XCTAssertEqual(try items(service.call("search_transcripts", arguments: ["query": "You"])).count, 1)
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
        XCTAssertEqual(Set((tools?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }),
                       Set(["list_calls", "get_call", "get_transcript", "search_transcripts", "save_call_summary", "get_changes", "search_activity", "get_coding_session", "get_github_item"]))
        XCTAssertTrue(try request("tools/call", params: ["name": "delete_call"])["error"] != nil)
        try AgentAccessStore.save(.init(), directory: state)
        let failure = try request("tools/call", params: ["name": "list_calls"])["result"] as? [String: Any]
        XCTAssertEqual(failure?["isError"] as? Bool, true)
        XCTAssertNil(server.handle(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{}}".utf8)))
        let invalid = try XCTUnwrap(server.handle(Data("garbage".utf8)))
        XCTAssertTrue(String(decoding: invalid, as: UTF8.self).contains("-32700"))
    }
    func testRPCDiscoveryCanRepeatInitializationOnSharedTransport() throws {
        let server = AgentRPCServer(directory: state)
        func request(_ method: String, id: Any = 0, params: [String: Any] = [:]) throws -> [String: Any] {
            let response = try XCTUnwrap(server.handle(AgentJSON.data(["jsonrpc": "2.0", "id": id, "method": method, "params": params])))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        }
        func initialized() throws {
            XCTAssertNil(try server.handle(AgentJSON.data(["jsonrpc": "2.0", "method": "notifications/initialized"])))
        }
        let params: [String: Any] = ["protocolVersion": "2025-11-25", "capabilities": [:],
                                    "clientInfo": ["name": "openai-mcp", "version": "1.0.0"]]

        // A tunnel discovery probe precedes two valid handshakes on the same child.
        let probe = try request("server/discover", id: "openai-mcp-discover")
        XCTAssertEqual((probe["error"] as? [String: Any])?["code"] as? Int, -32601)
        for id in [1, 0] {
            let response = try request("initialize", id: id, params: params)
            XCTAssertNil(response["error"])
            XCTAssertEqual((response["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
            let premature = try request("tools/list")
            XCTAssertEqual((premature["error"] as? [String: Any])?["code"] as? Int, -32002)
            try initialized()
        }
        let tools = try request("tools/list")["result"] as? [String: Any]
        XCTAssertEqual(Set((tools?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }),
                       Set(["list_calls", "get_call", "get_transcript", "search_transcripts", "save_call_summary", "get_changes", "search_activity", "get_coding_session", "get_github_item"]))

        // Invalid retries must not destroy a working connection or bypass validation.
        let invalid = try request("initialize", params: ["protocolVersion": "2025-11-25"])
        XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertTrue(try request("tools/list")["result"] != nil)

        // A later client can renegotiate the supported older protocol on this child.
        var older = params
        older["protocolVersion"] = "2025-06-18"
        older["clientInfo"] = ["name": "another-client", "version": "2"]
        let renegotiated = try request("initialize", params: older)
        XCTAssertEqual((renegotiated["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertTrue(try request("tools/list")["error"] != nil)
        try initialized()
        XCTAssertTrue(try request("tools/list")["result"] != nil)
    }
    private func enableSummaryWrites(_ enabled: Bool = true) throws {
        try AgentAccessStore.save(.init(enabled: true, folders: [root.path], allowSummaryWrites: enabled), directory: state)
    }
    private func summaryArguments(_ text: String = "## Decision\nShip the cobalt initiative.") throws -> [String: Any] {
        let call = try service.call("get_call", arguments: ["call_id": id()])
        return ["call_id": call["call_id"]!, "expected_revision": call["revision"]!,
                "source_version_id": (call["versions"] as! [[String: Any]])[0]["version_id"]!, "markdown": text]
    }
    func testSummaryAccessDefaultsOffAndWriteAnnotations() throws {
        try fixture()
        let arguments = try summaryArguments()
        XCTAssertFalse(try AgentAccessStore.load(directory: state).allowSummaryWrites)
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: arguments))
        let oldSettings = Data("{\"version\":1,\"enabled\":true,\"folders\":[]}".utf8)
        XCTAssertFalse(try JSONDecoder().decode(AgentAccessConfiguration.self, from: oldSettings).allowSummaryWrites)
        let definition = AgentTools.definitions.first { $0["name"] as? String == "save_call_summary" }!
        XCTAssertEqual((definition["annotations"] as? [String: Bool])?["readOnlyHint"], false)
        XCTAssertTrue(AgentTools.definitions.filter { $0["name"] as? String != "save_call_summary" }.allSatisfy { ($0["annotations"] as? [String: Bool])?["readOnlyHint"] == true })
        try enableSummaryWrites()
        _ = try service.call("save_call_summary", arguments: arguments)
        let next = try summaryArguments("Updated")
        try enableSummaryWrites(false)
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: next))
        try AgentAccessStore.save(.init(enabled: true, folders: [], allowSummaryWrites: true), directory: state)
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: next))
    }
    func testSummaryRoundTripHistorySearchChangesAndSourcePreservation() throws {
        let folder = try fixture()
        let audio = try Data(contentsOf: folder.appendingPathComponent("Mixed.m4a"))
        let transcript = try Data(contentsOf: folder.appendingPathComponent("Transcripts/first/Transcript.json"))
        try enableSummaryWrites()
        let baseline = try service.call("get_changes", arguments: [:])
        let originalArgs = try summaryArguments()
        let saved = try service.call("save_call_summary", arguments: originalArgs)
        let summary = saved["summary"] as! [String: Any]
        XCTAssertEqual(summary["markdown"] as? String, originalArgs["markdown"] as? String)
        XCTAssertEqual(summary["source_changed"] as? Bool, false)
        let search = try service.call("list_calls", arguments: ["query": "cobal", "mode": "keyword"])
        XCTAssertEqual(items(search).count, 1)
        XCTAssertEqual(items(search)[0]["match_source"] as? String, "summary")
        XCTAssertTrue(try items(service.call("search_transcripts", arguments: ["query": "cobalt", "mode": "keyword"])).isEmpty)
        XCTAssertTrue(try items(service.call("list_calls", arguments: ["query": "cobalt", "speaker": "You", "mode": "keyword"])).isEmpty)
        let changed = try service.call("get_changes", arguments: ["cursor": baseline["cursor"]!])
        XCTAssertEqual((changed["changes"] as? [[String: Any]])?.first?["change"] as? String, "updated")
        _ = try service.call("save_call_summary", arguments: summaryArguments("Updated summary"))
        let callID = try id()
        service = AgentLibrary(directory: state)
        let info = try service.call("get_call", arguments: ["call_id": callID])
        XCTAssertEqual((info["summary_versions"] as? [[String: Any]])?.count, 2)
        let historyPage = try service.call("get_call", arguments: ["call_id": callID, "summary_limit": 1])
        XCTAssertEqual(historyPage["summary_version_count"] as? Int, 2)
        XCTAssertEqual(historyPage["next_summary_offset"] as? Int, 1)
        let nextPage = try service.call("get_call", arguments: ["call_id": callID, "summary_offset": 1, "summary_limit": 1, "expected_revision": historyPage["revision"]!])
        XCTAssertEqual((nextPage["summary_versions"] as? [[String: Any]])?.first?["revision_id"] as? String, summary["revision_id"] as? String)
        let old = try service.call("get_call", arguments: ["call_id": callID, "summary_revision_id": summary["revision_id"]!])
        XCTAssertEqual((old["summary"] as? [String: Any])?["markdown"] as? String, originalArgs["markdown"] as? String)
        XCTAssertTrue(try items(service.call("list_calls", arguments: ["query": "cobalt", "all_versions": true, "mode": "keyword"])).isEmpty)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Mixed.m4a")), audio)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Transcripts/first/Transcript.json")), transcript)
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("Summary.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testSummaryGitHubLinksFollowRepositoryGrantsOnEveryRead() throws {
        let folder = try fixture()
        let recording = try XCTUnwrap(RecordingLibraryScanner.scan(roots: [folder]).recordings.first)
        _ = try CallSummaryStore.save("See samples/fern#5 and https://github.com/samples/fern/pull/5. Also #12.",
                                      for: recording, source: recording.latestTranscript)
        let archive = try GitHubArchive(directory: state.appendingPathComponent("GitHub"))
        let repo = GitHubRepository(id: "repo", name: "samples/fern")
        try archive.connect(.init(id: "user", login: "fixture"))
        try archive.select(repo)
        let selected = try archive.selections()[0]
        let now = Date()
        try archive.begin(selected, now: now)
        let url = "https://github.com/samples/fern/pull/5"
        let header = GitHubItem(id: "pr", repositoryID: repo.id, type: "pr", title: "Garden plan", author: "fixture",
                                state: "OPEN", url: url, number: 5)
        var page = GitHubPage()
        page.entries = [(header, .init(id: "pr", actorID: "user", text: "My plan", url: url, kind: .opened, date: now,
                                       edited: nil, verdict: nil, path: nil, line: nil))]
        try archive.commit(page, work: XCTUnwrap(archive.next(selected)), repo: selected)
        let callID = try XCTUnwrap(items(service.call("list_calls", arguments: [:])).first?["call_id"] as? String)
        func links() throws -> [String] {
            let result = try service.call("get_call", arguments: ["call_id": callID])
            let summary = try XCTUnwrap(result["summary"] as? [String: Any])
            return (summary["related_github_items"] as? [[String: Any]] ?? []).compactMap { $0["item_id"] as? String }
        }
        XCTAssertEqual(try links(), [])
        try archive.share(repo.id, enabled: true)
        XCTAssertEqual(try links(), ["pr"])
        try archive.share(repo.id, enabled: false)
        XCTAssertEqual(try links(), [])
    }

    func testSummaryRejectsStaleAgentAndNativeEdits() throws {
        let folder = try fixture(); try enableSummaryWrites()
        let agentDraft = try summaryArguments()
        let nativeDraft = try XCTUnwrap(RecordingLibraryScanner.scan(roots: [root]).recordings.first)
        _ = try CallSummaryStore.save("Native draft wins", for: nativeDraft, source: nativeDraft.latestTranscript)
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: agentDraft))
        XCTAssertThrowsError(try CallSummaryStore.save("Stale native edit", for: nativeDraft, source: nativeDraft.latestTranscript))
        XCTAssertEqual(try CallSummaryStore.load(for: folder, isDirectory: true)?.current?.markdown, "Native draft wins")
        let beforeSourceChange = try summaryArguments()
        try fixture(text: "Changed transcript text")
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: beforeSourceChange))
        XCTAssertEqual(try CallSummaryStore.load(for: folder, isDirectory: true)?.versions.count, 1)
    }
    func testSummaryTracksSourceAndResolvedSpeakerChanges() throws {
        let folder = try fixture(); try enableSummaryWrites()
        try CallDetailsStore.writeInitial(.init(participants: ["Avery"]), to: folder.appendingPathComponent("CallDetails.json"))
        _ = try service.call("save_call_summary", arguments: summaryArguments())
        let document = try Transcript.read(from: folder.appendingPathComponent("Transcripts/first/Transcript.json"))
        let previousFingerprint = AgentJSON.hash(try AgentJSON.data([
            "transcript": AgentJSON.object(document), "speakers": ["Recorder", "Avery", "Recorder"]
        ]))
        XCTAssertEqual(try CallSummaryStore.load(for: folder, isDirectory: true)?.current?.sourceFingerprint, previousFingerprint)
        func stale() throws -> Bool { (try service.call("get_call", arguments: ["call_id": id()])["summary"] as! [String: Any])["source_changed"] as! Bool }
        try CallDetailsStore.writeInitial(.init(title: "Renamed", participants: ["Avery"]), to: folder.appendingPathComponent("CallDetails.json"))
        XCTAssertFalse(try stale())
        try CallDetailsStore.writeInitial(.init(participants: ["Bellamy"]), to: folder.appendingPathComponent("CallDetails.json"))
        XCTAssertTrue(try stale())
        let recording = try XCTUnwrap(RecordingLibraryScanner.scan(roots: [root]).recordings.first)
        _ = try CallSummaryStore.save("A manual correction", for: recording, source: nil)
        XCTAssertTrue(try stale())
        _ = try service.call("save_call_summary", arguments: summaryArguments("Regenerated with Bellamy"))
        XCTAssertFalse(try stale())
        try fixture(run: "new", created: "2026-11-14T00:00:00Z")
        XCTAssertTrue(try stale())
    }
    func testSummaryRefusesCorruptFilesLinksAndInvalidArguments() throws {
        let folder = try fixture(); try enableSummaryWrites()
        var arguments = try summaryArguments()
        for text in ["  ", "bad\0text", String(repeating: "x", count: 65_537)] {
            arguments["markdown"] = text
            XCTAssertThrowsError(try service.call("save_call_summary", arguments: arguments))
        }
        arguments = try summaryArguments()
        arguments["source_version_id"] = "unknown"
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: arguments))
        arguments = try summaryArguments(); arguments.removeValue(forKey: "expected_revision")
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: arguments))
        let file = folder.appendingPathComponent("Summary.json"), outside = temporary.appendingPathComponent("outside.txt")
        try Data("do not change".utf8).write(to: outside)
        arguments = try summaryArguments()
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: arguments))
        XCTAssertEqual(try String(contentsOf: outside), "do not change")
        try FileManager.default.removeItem(at: file)
        try Data("broken JSON".utf8).write(to: file)
        arguments = try summaryArguments()
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: arguments))
        XCTAssertEqual(try String(contentsOf: file), "broken JSON")
        try FileManager.default.removeItem(at: file)
        let lock = CallSummaryStore.lockURL(for: folder, isDirectory: true)
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outside)
        arguments = try summaryArguments()
        XCTAssertThrowsError(try service.call("save_call_summary", arguments: arguments))
        XCTAssertEqual(try String(contentsOf: outside), "do not change")
    }
    func testSummaryConcurrentWritersCannotOverwriteEachOther() throws {
        let folder = try fixture()
        let recording = try XCTUnwrap(RecordingLibraryScanner.scan(roots: [root]).recordings.first)
        let lock = NSLock()
        var successes = 0
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                _ = try CallSummaryStore.save("Writer \(index)", for: recording, source: recording.latestTranscript)
                lock.lock(); successes += 1; lock.unlock()
            } catch { }
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(try CallSummaryStore.load(for: folder, isDirectory: true)?.versions.count, 1)
        let updated = try XCTUnwrap(RecordingLibraryScanner.scan(roots: [root]).recordings.first)
        XCTAssertEqual(try CallFileOperations.trashPlan(for: updated).urls.map(\.path), [folder.path])
    }
    func testSummaryRechecksAuthorizationBeforePublishing() throws {
        let folder = try fixture()
        let recording = try XCTUnwrap(RecordingLibraryScanner.scan(roots: [root]).recordings.first)
        var checks = 0
        XCTAssertThrowsError(try CallSummaryStore.save("Must not be published", for: recording, source: recording.latestTranscript) {
            checks += 1
            if checks == 2 { throw RecorderError.message("Access revoked while preparing the write") }
        })
        XCTAssertEqual(checks, 2)
        XCTAssertNil(try CallSummaryStore.load(for: folder, isDirectory: true))
    }

}
