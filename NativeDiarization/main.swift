import AVFoundation
import Foundation
import FluidAudio
import Darwin

/// Seek before converting to 16 kHz so saving a passage only decodes that part of the call.
private func copyPassage(_ range: Range<Double>, from source: URL, to destination: URL) throws {
    let input = try AVAudioFile(forReading: source)
    let format = input.processingFormat
    guard range.upperBound <= Double(input.length) / format.sampleRate else {
        throw OfflineDiarizationError.invalidSpan("The selected passage extends beyond the system audio.")
    }
    input.framePosition = AVAudioFramePosition((range.lowerBound * format.sampleRate).rounded())
    let lastFrame = AVAudioFramePosition((range.upperBound * format.sampleRate).rounded())
    let output = try AVAudioFile(forWriting: destination, settings: format.settings)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { throw CocoaError(.fileReadUnknown) }
    while input.framePosition < lastFrame {
        let count = min(AVAudioFramePosition(buffer.frameCapacity), lastFrame - input.framePosition)
        try input.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try output.write(from: buffer)
    }
}

func analyze() async throws {
    let args = CommandLine.arguments
    guard args.count == 4 || args.count == 6 else { throw CocoaError(.fileReadInvalidFileName) }
    // FluidAudio's temporary decoded PCM should also be private.
    umask(0o077)
    ModelHub.offlineMode = true
    let root = URL(fileURLWithPath: args[1])
    let models = try await OfflineDiarizerModels.load(from: root)
    let manager = OfflineDiarizerManager()
    manager.initialize(models: models)
    let source = URL(fileURLWithPath: args[2])
    let intervals: [SpeakerInterval]
    let samples: [SpeakerInterval]
    let vectors: [[Float]]
    if args.count == 6 {
        guard let start = Double(args[4]), let end = Double(args[5]), start.isFinite, end.isFinite,
              start >= 0, end - start >= VoiceClip.minimumDuration else {
            throw OfflineDiarizationError.invalidSpan("The selected passage is outside the available audio or too short.")
        }
        let excerpt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: excerpt) }
        try copyPassage(start..<end, from: source, to: excerpt)
        let (audio, _) = try AudioSourceFactory().makeDiskBackedSource(from: excerpt, targetSampleRate: 16000)
        defer { audio.cleanup() }
        intervals = []
        samples = [.init(speaker: "passage", start: start, end: end)]
        vectors = try await manager.embedSpans(audioSource: audio, spans: [0..<(Double(audio.sampleCount) / 16_000)])
    } else {
        let (audio, loadTime) = try AudioSourceFactory().makeDiskBackedSource(from: source, targetSampleRate: 16000)
        defer { audio.cleanup() }
        let result = try await manager.process(audioSource: audio, audioLoadingSeconds: loadTime)
        intervals = result.segments.map { SpeakerInterval(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        samples = SpeakerAnalysis.sampleIntervals(intervals)
        vectors = samples.isEmpty ? [] : try await manager.embedSpans(audioSource: audio, spans: samples.map { $0.start..<$0.end })
    }
    guard vectors.count == samples.count else { throw CocoaError(.fileReadCorruptFile) }
    let clips = zip(samples, vectors).compactMap { interval, vector -> VoiceClip? in
        guard vector.count == 256, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else { return nil }
        return VoiceClip(interval: interval, vector: vector)
    }
    let analysis = SpeakerAnalysis(model: SpeakerAnalysis.modelID, intervals: intervals, clips: clips)
    try JSONEncoder().encode(analysis).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
}

do { try await analyze() }
catch {
    FileHandle.standardError.write(Data(("Speaker analysis failed. " + error.localizedDescription + "\n").utf8))
    exit(1)
}
