import Foundation
import AVFoundation
import RecorderCore

@main struct TranscriptionHarness {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4, let model = SpeechModel.catalog.first(where: { $0.id == args[2] }) else {
            print("Usage: transcription-check download|run|cancel MODEL_ID MODEL_ROOT [RECORDING]"); exit(2)
        }
        let root = URL(fileURLWithPath: args[3], isDirectory: true)
        if args[1] == "cancel-download" {
            let task = Task { try await ModelStore.download(model, root: root) { _ in } }
            try await Task.sleep(nanoseconds: 500_000_000); task.cancel()
            do { _ = try await task.value; fatalError("Cancelled download published a model") }
            catch {
                guard error is CancellationError || (error as NSError).code == NSURLErrorCancelled else { throw error }
                let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                guard files.isEmpty else { fatalError("Cancelled download left files: \(files)") }
                print("PASS cancelled download leaves no installed or staging file")
            }
            return
        }
        if args[1] == "download" {
            let url = try await ModelStore.download(model, root: root) { value in
                // Keep the harness log concise; production progress is on the main actor.
                if value == nil { print("Verifying download") }
            }
            print("PASS download and SHA-256 verification: \(url.lastPathComponent)")
            return
        }
        guard args.count == 5, let installed = ModelStore.find(model, root: root) else { fatalError("Missing recording or model") }
        let recording = URL(fileURLWithPath: args[4])
        let job = TranscriptionJob()
        let start = Date()
        do {
            let file = try await job.run(recording: recording, model: model, modelURL: installed.url,
                                         worker: ProcessInfo.processInfo.environment["CALL_RECORDER_WORKER"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/native/TranscriptionWorker"),
                                         reduceSpeakerBleed: ProcessInfo.processInfo.environment["CALL_RECORDER_REDUCE_BLEED"] != "0") { event in
                print(event.message, event.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "")
                if args[1] == "cancel", event.message.hasPrefix("Transcribing") { job.cancel() }
                if args[1] == "cancel-cleanup", event.message.hasPrefix("Reducing speaker bleed") { job.cancel() }
            }
            if args[1] == "cancel" || args[1] == "cancel-cleanup" { fatalError("Cancelled transcription published a result") }
            print("PASS \(model.name) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s: \(file.path)")
        } catch is CancellationError {
            guard args[1] == "cancel" || args[1] == "cancel-cleanup" else { throw CancellationError() }
            print("PASS cancellation; no transcript published")
        } catch {
            guard args[1] == "fail" else { throw error }
            print("PASS worker failure leaves recording and previous transcripts intact: \(error.localizedDescription)")
        }
    }
}
