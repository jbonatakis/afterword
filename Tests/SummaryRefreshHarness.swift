import AppKit
import AVFoundation
import Combine
import RecorderCore

/// Exercises real filesystem events, including writes from a separate process.
/// No activation notifications or explicit refresh calls drive the assertions.
@main struct SummaryRefreshHarness {
    @MainActor static func main() {
        setbuf(stdout, nil)
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--save-summary" {
            do {
                let url = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
                let scan = RecordingLibraryScanner.scan(roots: [url.deletingLastPathComponent()])
                guard let call = scan.recordings.first(where: { $0.url == url }) else { throw RecorderError.message("Missing fixture") }
                try CallSummaryStore.save(CommandLine.arguments[3], for: call, source: call.latestTranscript, author: "agent")
                exit(0)
            } catch { fputs("FAIL writer: \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw RecorderError.message(message) }
        }
        func eventually(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition() {
                try require(Date() < deadline, message)
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        func saveExternally(_ text: String, to url: URL) async throws {
            try await Task.detached {
                let process = Process()
                process.executableURL = Bundle.main.executableURL!
                process.arguments = ["--save-summary", url.path, text]
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw RecorderError.message("External writer failed") }
            }.value
        }
        func audio(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            do {
                let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
                buffer.frameLength = 1600; buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
                try file.write(from: buffer)
            }
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("summary-refresh-" + UUID().uuidString).resolvingSymlinksInPath()
        let root = temporary.appendingPathComponent("First"), otherRoot = temporary.appendingPathComponent("Second")
        let callURL = root.appendingPathComponent("Call-fixture"), legacyURL = otherRoot.appendingPathComponent("Legacy.m4a")
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { try? FileManager.default.removeItem(at: temporary); UserDefaults.standard.removePersistentDomain(forName: domain) }
        try audio(callURL.appendingPathComponent("Mixed.m4a")); try audio(legacyURL)
        UserDefaults.standard.set(root.path, forKey: "destination")
        UserDefaults.standard.set(false, forKey: "KeyboardShortcuts_toggleCallRecording")
        let recorder = RecordingCoordinator(peopleURL: temporary.appendingPathComponent("People.json")); recorder.shortcut.shutdown()
        defer { recorder.transcription.shutdown() }
        let library = RecordingLibraryModel(recorder: recorder, embeddingDirectory: temporary.appendingPathComponent("Embeddings"))
        defer { library.shutdown() }
        try await eventually("Initial scan failed") { !library.refreshing && library.recordings.count == 1 }
        let id = library.recordings[0].id
        library.search = "cobalt"
        try await eventually("Initial search failed") { !library.searching }
        try require(library.visibleRecordings.isEmpty, "Fixture unexpectedly matched")
        try await saveExternally("A cobalt decision", to: callURL)
        try await eventually("First summary did not appear in search automatically") {
            library.selectedRecording?.summary?.current?.markdown == "A cobalt decision" && library.searchHits[id]?.summaryMatch == true
        }
        print("PASS separate-process first summary creation and live search results")

        library.beginSummaryEditing(library.selectedRecording!)
        let draft = library.summaryDrafts[id]!
        draft.markdown = "An unsaved local edit"
        for number in 1...3 { try await saveExternally("A cobalt revision \(number)", to: callURL) }
        try await eventually("Atomic replacements did not update the summary") {
            library.selectedRecording?.summary?.current?.markdown == "A cobalt revision 3" && !library.refreshing
        }
        try require(library.summaryDrafts[id] === draft && draft.markdown == "An unsaved local edit", "Refresh discarded the draft")
        try require(library.selectedRecording?.summary?.versions.count == 4, "Refresh missed summary history")
        library.cancelSummaryEditing(library.selectedRecording!)
        try FileManager.default.removeItem(at: CallSummaryStore.url(for: callURL, isDirectory: true))
        try await eventually("Summary deletion did not clear the saved snapshot and search match") {
            library.recordings.first(where: { $0.id == id })?.summary == nil && library.visibleRecordings.isEmpty && !library.refreshing && !library.searching
        }
        print("PASS atomic replacements, history, draft preservation, and summary deletion")

        library.search = ""
        recorder.destination = otherRoot
        try await eventually("New destination was not scanned") { !library.refreshing && library.recordings.count == 2 }
        try await saveExternally("Legacy summary", to: legacyURL)
        try await eventually("Legacy summary in the new root did not refresh") {
            library.recordings.contains { $0.url == legacyURL && $0.summary?.current?.markdown == "Legacy summary" }
        }
        // The folder UI passes the canonical URL stored by the library.
        library.removeFolder(library.roots.first { $0.path == root.path }!)
        try await eventually("Removed folder remained in library") { !library.refreshing && library.recordings.count == 1 }
        try await Task.sleep(for: .seconds(1))
        var refreshes = 0
        let subscription = library.$refreshing.dropFirst().sink { if $0 { refreshes += 1 } }
        defer { subscription.cancel() }
        try await saveExternally("Unwatched summary", to: callURL)
        try Data("unrelated".utf8).write(to: otherRoot.appendingPathComponent(".summary-test.tmp"))
        try await Task.sleep(for: .seconds(1))
        try require(refreshes == 0, "Removed roots or unrelated files triggered a scan")
        library.shutdown()
        try await saveExternally("After shutdown", to: legacyURL)
        try await Task.sleep(for: .seconds(1))
        try require(refreshes == 0 && library.recordings[0].summary?.current?.markdown == "Legacy summary", "Shutdown did not stop refreshes")
        print("PASS legacy files, changed roots, ignored unrelated files, and watcher shutdown")
    }
}
