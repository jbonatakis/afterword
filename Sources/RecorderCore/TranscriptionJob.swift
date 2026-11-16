import Foundation

public struct TranscriptionProgress: Sendable {
    public let message: String
    public let fraction: Double?
    public init(_ message: String, fraction: Double? = nil) { self.message = message; self.fraction = fraction }
}

/// A single owned helper process. Cancellation never targets the recording engine.
public final class TranscriptionJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() {
        lock.lock(); cancelled = true
        let child = process
        if let child, child.isRunning { child.terminate() }
        lock.unlock()
        if let child {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                if self.process === child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
    private func checkCancellation() throws { if isCancelled { throw CancellationError() } }

    public func run(recording: URL, model: SpeechModel, modelURL: URL, worker: URL,
                    language: String = "auto", reduceSpeakerBleed: Bool = true,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try self.execute(recording: recording, model: model, modelURL: modelURL, worker: worker, language: language, reduceSpeakerBleed: reduceSpeakerBleed, progress: progress)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    private func execute(recording: URL, model: SpeechModel, modelURL: URL, worker: URL, language: String, reduceSpeakerBleed: Bool,
                         progress: @escaping @Sendable (TranscriptionProgress) -> Void) throws -> URL {
        try checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: worker.path) else { throw RecorderError.message("The transcription worker is missing. Rebuild or reinstall Afterword.") }
        let input = try TranscriptionInput.resolve(recording)
        let bleedReduction = SpeakerBleedReduction.resolve(enabled: reduceSpeakerBleed, input: input)
        progress(.init("Checking \(model.name)…"))
        try ModelStore.verify(modelURL, model: model, cancelled: { self.isCancelled })
        try checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Afterword-ASR-" + UUID().uuidString)
        try PrivateFiles.directory(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        struct Request: Encodable { let model: String; let language: String; let tracks: [TranscriptionTrack]; let reduceSpeakerBleed: Bool }
        let request = temporary.appendingPathComponent("request.json")
        try PrivateFiles.atomicWrite(JSONEncoder().encode(Request(model: modelURL.path, language: language, tracks: input.tracks, reduceSpeakerBleed: bleedReduction == .enabled)), to: request)
        let errorURL = temporary.appendingPathComponent("worker.log")
        try PrivateFiles.create(errorURL)
        let errors = try FileHandle(forWritingTo: errorURL); defer { try? errors.close() }
        let output = Pipe(), child = Process()
        child.executableURL = worker; child.arguments = [request.path]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = errors
        child.qualityOfService = .utility
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run(); lock.unlock() } catch { process = nil; lock.unlock(); throw error }
        // The parent must not retain a writer or it would never see EOF after a crash.
        try? output.fileHandleForWriting.close()
        defer {
            try? output.fileHandleForReading.close()
            if child.isRunning { cancel(); child.waitUntilExit() }
            lock.lock(); process = nil; lock.unlock()
        }
        var buffer = Data(), segments: [TranscriptSegment] = []
        var completion: TranscriptionCompletion?
        var durations: [TranscriptSource: Double] = [:]
        let allowed = Set(input.tracks.map(\.source))
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            try checkCancellation(); buffer.append(data)
            guard buffer.count < 2_097_152 else { throw RecorderError.message("The transcription worker returned an oversized response.") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.subdata(in: buffer.startIndex..<newline); buffer.removeSubrange(...newline)
                guard let event = try JSONSerialization.jsonObject(with: line) as? [String: Any], let type = event["type"] as? String, completion == nil else {
                    throw RecorderError.message("The transcription worker returned an invalid response.")
                }
                switch type {
                case "loading": progress(.init("Loading \(model.name)…"))
                case "cleanup":
                    guard bleedReduction == .enabled, event["source"] as? String == "microphone", durations[.microphone] != nil else {
                        throw RecorderError.message("Unexpected speaker bleed reduction from the transcription worker.")
                    }
                    progress(.init("Reducing speaker bleed…"))
                case "track":
                    guard let name = event["source"] as? String, let source = TranscriptSource(rawValue: name), allowed.contains(source),
                          durations[source] == nil, let duration = event["duration"] as? Double, duration.isFinite, duration > 0 else { throw RecorderError.message("Invalid track returned by the transcription worker.") }
                    durations[source] = duration
                    progress(.init("Transcribing \(source.label)…"))
                case "progress":
                    guard let name = event["source"] as? String, let source = TranscriptSource(rawValue: name), durations[source] != nil,
                          let value = event["progress"] as? Double, value.isFinite, (0...1).contains(value) else { throw RecorderError.message("Invalid transcription progress.") }
                    progress(.init("Transcribing \(source.label)…", fraction: value))
                case "segment":
                    let row = try JSONDecoder().decode(TranscriptSegment.self, from: line)
                    guard let duration = durations[row.source], row.end <= duration + 0.1 else { throw RecorderError.message("Transcript timestamps exceed the recording duration.") }
                    segments.append(row)
                case "error": throw RecorderError.message(event["message"] as? String ?? "Local transcription failed.")
                case "done":
                    guard let result = try? JSONDecoder().decode(TranscriptionCompletion.self, from: line) else {
                        throw RecorderError.message("The transcription worker could not confirm the cleanup setting. Rebuild or reinstall Afterword.")
                    }
                    try result.validate(expected: bleedReduction)
                    completion = result
                default: throw RecorderError.message("Unknown response from the transcription worker.")
                }
            }
        }
        child.waitUntilExit(); try checkCancellation()
        guard child.terminationStatus == 0, let completion, buffer.isEmpty, durations.count == input.tracks.count else {
            throw RecorderError.message("The local transcription worker stopped before completing. Try again or choose another model. Your recording is saved.")
        }
        let transcript = try Transcript(input: input, model: model, engine: "transcribe.cpp " + completion.engine, language: language,
                                        segments: segments, speakerBleedReduction: bleedReduction, echoCancellation: completion.echoCancellation)
        progress(.init("Saving transcript…", fraction: 1))
        // Serialize publication with cancellation: a cancelled job cannot publish later.
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        return try transcript.save(beside: input)
    }
}
