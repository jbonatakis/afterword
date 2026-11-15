import Foundation
import AVFoundation
import RecorderCore

func timed<T>(_ name: String, _ f: () throws -> T) rethrows -> T {
    let start = ProcessInfo.processInfo.systemUptime
    let result = try f()
    print("\(name): \(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - start) * 1000)) ms")
    fflush(stdout)
    return result
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("search-audit-" + UUID().uuidString).resolvingSymlinksInPath()
let root = temporary.appendingPathComponent("Calls"), state = temporary.appendingPathComponent("State")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let fixture = temporary.appendingPathComponent("Fixture.caf")
let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
do {
    let file = try AVAudioFile(forWriting: fixture, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
    buffer.frameLength = 1600; buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
    try file.write(from: buffer)
}
let service = AgentLibrary(directory: state)
let searchIndex = try LibrarySearchIndex(roots: [root], directory: temporary.appendingPathComponent("Search"))
try AgentAccessStore.save(.init(enabled: true, folders: [root.path]), directory: state)
let words = "The planning team reviewed database migration and confirmed delivery next Friday".components(separatedBy: " ")
let segments = (0..<1800).map { index in
    TranscriptSegment(source: .mixed, start: Double(index), end: Double(index) + 0.8, text: words[index % words.count], timing: "word")
}
let input = try TranscriptionInput.resolve(fixture)
let document = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "audit", language: "en", segments: segments)
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let json = try encoder.encode(document)
var previous = 0
for count in [10, 50, 100] {
    for index in previous..<count {
        let call = root.appendingPathComponent("Synthetic-\(index)")
        let run = call.appendingPathComponent("Transcripts/original")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: call.appendingPathComponent("Mixed.m4a"))
        try json.write(to: run.appendingPathComponent("Transcript.json"))
    }
    previous = count
    print("\n\(count) calls, one version and 1800 word segments per call (\(count * json.count) JSON bytes)")
    let scan = timed("library scan") { RecordingLibraryScanner.scan(roots: [root]) }
    guard scan.issues.isEmpty else { fatalError("Unexpected scan issue") }
    _ = try timed("library incremental index") { try searchIndex.synchronize() }
    _ = try timed("library unchanged refresh") { try searchIndex.synchronize() }
    _ = try timed("library indexed no-match") { try searchIndex.search("nonexistent needle") }
    _ = try timed("library indexed common-word") { try searchIndex.search("database") }
    _ = try timed("MCP first request after additions") { try service.call("list_calls", arguments: ["limit": 1]) }
    _ = try timed("MCP warm list_calls limit=1") { try service.call("list_calls", arguments: ["limit": 1]) }
    _ = try timed("MCP search no-match limit=1") { try service.call("search_transcripts", arguments: ["query": "nonexistent needle", "limit": 1]) }
    _ = try timed("MCP search common-word limit=1") { try service.call("search_transcripts", arguments: ["query": "database", "limit": 1]) }
}
