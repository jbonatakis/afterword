import Foundation
import FluidAudio
import Darwin

func analyze() async throws {
    let args = CommandLine.arguments
    guard args.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
    // FluidAudio's temporary decoded PCM should also be private.
    umask(0o077)
    ModelHub.offlineMode = true
    let root = URL(fileURLWithPath: args[1])
    let models = try await OfflineDiarizerModels.load(from: root)
    let manager = OfflineDiarizerManager()
    manager.initialize(models: models)
    let (audio, loadTime) = try AudioSourceFactory().makeDiskBackedSource(from: URL(fileURLWithPath: args[2]), targetSampleRate: 16000)
    defer { audio.cleanup() }
    let result = try await manager.process(audioSource: audio, audioLoadingSeconds: loadTime)
    let intervals = result.segments.map { SpeakerInterval(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
    let samples = SpeakerAnalysis.sampleIntervals(intervals)
    let vectors = samples.isEmpty ? [] : try await manager.embedSpans(audioSource: audio, spans: samples.map { $0.start..<$0.end })
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
