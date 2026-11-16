import Foundation
@testable import RecorderCore

// Explicit opt-in harness. Writes local evaluation input only to the requested
// private build artifact; never submits transcript text to a service.
@main struct EmbeddingBenchmark {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: EmbeddingBenchmark recordings-folder output.json") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let calls = RecordingLibraryScanner.scan(roots: [root], confined: true).recordings
        var corpus: [[String: Any]] = []
        for recording in calls {
            let call = try AgentCall(recording: recording, id: AgentJSON.identity(recording.url))
            for chunk in SemanticChunker.chunks(call).filter(\.latest) {
                corpus.append(["title": recording.name, "paragraphs": chunk.paragraphs, "text": chunk.text])
            }
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try PrivateFiles.atomicWrite(AgentJSON.data(corpus), to: output)
        print("Exported \(corpus.count) current-version chunks from \(calls.count) saved calls for local evaluation.")
    }
}
