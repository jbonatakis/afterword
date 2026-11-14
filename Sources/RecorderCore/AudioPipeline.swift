import Foundation
import AVFoundation
import CaptureBridge

enum PCMFormats {
    static func make(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
        }
        // These are independent source channels, not a surround speaker layout.
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
    }
}

public enum FixedMix {
    static func safe(_ value: Float) -> Float { value.isFinite ? max(-1, min(1, value)) : 0 }
    public static func sample(microphone: Float, left: Float, right: Float, microphoneEnabled: Bool = true) -> (Float, Float) {
        let mic = microphoneEnabled ? safe(microphone) * 0.5 : 0
        return (mic + safe(left) * 0.5, mic + safe(right) * 0.5)
    }
}

public final class PCMResampler {
    private let converter: AVAudioConverter?
    private let output: AVAudioPCMBuffer
    public let inputFormat: AVAudioFormat
    public private(set) var inputFrames: Int64 = 0
    public private(set) var outputFrames: Int64 = 0
    public init(sampleRate: Double, channels: AVAudioChannelCount = 2) throws {
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 192_000, (1...3).contains(channels),
              let input = PCMFormats.make(sampleRate: sampleRate, channels: channels),
              let target = PCMFormats.make(sampleRate: 48_000, channels: channels) else { throw RecorderError.message("Invalid PCM rate or channel count.") }
        inputFormat = input
        output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 32_768)!
        if sampleRate == 48_000 { converter = nil }
        else {
            guard let c = AVAudioConverter(from: input, to: target) else { throw RecorderError.message("Sample-rate conversion is unavailable.") }
            c.channelMap = (0..<channels).map { NSNumber(value: $0) }
            c.primeMethod = .none
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = c
        }
    }
    public func append(_ input: AVAudioPCMBuffer, output write: (AVAudioPCMBuffer) throws -> Void) throws {
        guard input.format == inputFormat else { throw RecorderError.message("Unexpected resampler input.") }
        inputFrames += Int64(input.frameLength)
        guard let converter else { try write(input); outputFrames += Int64(input.frameLength); return }
        var supplied = false
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if status == .error { throw error ?? RecorderError.message("Sample-rate conversion failed.") as NSError }
            if output.frameLength > 0 { try write(output); outputFrames += Int64(output.frameLength) }
            if status != .haveData { break }
        }
    }
    public func finish(output write: (AVAudioPCMBuffer) throws -> Void) throws {
        guard let converter else { return }
        let expected = Int64((Double(inputFrames) * 48_000 / inputFormat.sampleRate).rounded())
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            if status == .error { throw error ?? RecorderError.message("Could not flush sample-rate converter.") as NSError }
            output.frameLength = AVAudioFrameCount(min(Int64(output.frameLength), max(0, expected - outputFrames)))
            if output.frameLength > 0 { try write(output); outputFrames += Int64(output.frameLength) }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        guard abs(outputFrames - expected) <= 1 else { throw RecorderError.message("Sample-rate converter produced \(outputFrames) frames; expected \(expected). PCM retained for recovery.") }
    }
}

public final class AudioPipeline {
    public private(set) var snapshot = PipelineSnapshot()
    private let rate: Double
    private let resampler: PCMResampler
    private let inputPCM: AVAudioPCMBuffer
    private let separateTracks: Bool
    private let mic = UnsafeMutablePointer<Float>.allocate(capacity: Int(CoreAudioCapture.maxFrames))
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: Int(CoreAudioCapture.maxFrames))
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: Int(CoreAudioCapture.maxFrames))
    private let store: SessionStore?
    private var firstSample: Double?
    private var expectedSample: Double?
    private var pendingMicrophoneEvents: [MicrophoneEvent] = []
    private var lastMicrophoneEnabled: Bool?
    private var outputMicrophoneEnabled = true
    public init(sampleRate: Double, store: SessionStore?) throws {
        self.rate = sampleRate; self.store = store
        separateTracks = store?.manifest.hasSeparateTracks ?? true
        resampler = try PCMResampler(sampleRate: sampleRate, channels: separateTracks ? 3 : 2)
        inputPCM = AVAudioPCMBuffer(pcmFormat: resampler.inputFormat, frameCapacity: CoreAudioCapture.maxFrames)!
    }
    public func drain(_ ring: OpaquePointer) throws {
        var info = CRBlockInfo()
        var peakMic: Float = 0; var peakSystem: Float = 0
        var readAny = false
        while CRRingRead(ring, mic, left, right, &info) {
            readAny = true
            if let expectedSample, abs(info.sampleTime - expectedSample) > 0.5 {
                let delta = info.sampleTime - expectedSample
                throw RecorderError.message("Capture timestamp discontinuity at sample \(info.sampleTime): \(delta) source frames. The uninterrupted portion was preserved.")
            }
            guard info.sampleTime.isFinite else { throw RecorderError.message("Invalid capture timestamp.") }
            if firstSample == nil { firstSample = info.sampleTime; try store?.setTimeline(sampleTime: info.sampleTime, hostTime: info.hostTime) }
            expectedSample = info.sampleTime + Double(info.frames)
            let frame = Int64(((info.sampleTime - firstSample!) * 48_000 / rate).rounded())
            try store?.microphone(enabled: info.microphoneEnabled, frame: frame)
            if separateTracks, lastMicrophoneEnabled != info.microphoneEnabled {
                pendingMicrophoneEvents.append(MicrophoneEvent(frame: frame, enabled: info.microphoneEnabled))
                lastMicrophoneEnabled = info.microphoneEnabled
            }
            inputPCM.frameLength = info.frames
            for f in 0..<Int(info.frames) {
                let sources = (mic[f], left[f], right[f])
                account(sources.0); account(sources.1); account(sources.2)
                peakMic = max(peakMic, sources.0.isFinite ? min(1, abs(sources.0)) : 0)
                peakSystem = max(peakSystem, sources.1.isFinite ? min(1, abs(sources.1)) : 0, sources.2.isFinite ? min(1, abs(sources.2)) : 0)
                if separateTracks {
                    inputPCM.floatChannelData![0][f] = FixedMix.safe(sources.0)
                    inputPCM.floatChannelData![1][f] = FixedMix.safe(sources.1)
                    inputPCM.floatChannelData![2][f] = FixedMix.safe(sources.2)
                } else {
                    let pair = FixedMix.sample(microphone: sources.0, left: sources.1, right: sources.2)
                    inputPCM.floatChannelData![0][f] = pair.0; inputPCM.floatChannelData![1][f] = pair.1
                }
            }
            try resampler.append(inputPCM, output: persist)
            snapshot.frames = resampler.outputFrames
        }
        if readAny { snapshot.microphonePeak = peakMic; snapshot.systemPeak = peakSystem }
        let stats = CRRingGetStats(ring)
        snapshot.callbacks = stats.callbacks; snapshot.droppedFrames = stats.droppedFrames
        if stats.failed {
            throw RecorderError.message("Capture stopped at source sample \(stats.firstDroppedSampleTime): \(stats.droppedFrames) dropped frames, \(stats.invalidBuffers) invalid buffers. The bounded queue or source layout failed.")
        }
    }
    public func finish() throws {
        try resampler.finish(output: persist)
        snapshot.frames = resampler.outputFrames
        try store?.finish(snapshot: snapshot)
    }
    private func persist(_ buffer: AVAudioPCMBuffer) throws {
        if separateTracks {
            // One converter keeps all three sources sample-aligned. Enforce mute
            // again on the output timeline so its filter tail cannot enter an off interval.
            var consumed = 0
            for frame in 0..<Int(buffer.frameLength) {
                let position = resampler.outputFrames + Int64(frame)
                while consumed < pendingMicrophoneEvents.count, pendingMicrophoneEvents[consumed].frame <= position {
                    outputMicrophoneEnabled = pendingMicrophoneEvents[consumed].enabled; consumed += 1
                }
                if !outputMicrophoneEnabled { buffer.floatChannelData![0][frame] = 0 }
            }
            if consumed > 0 { pendingMicrophoneEvents.removeFirst(consumed) }
        }
        try store?.append(buffer)
    }
    @inline(__always) private func account(_ sample: Float) {
        if !sample.isFinite { snapshot.invalidSamples += 1 }
        else if abs(sample) > 1 { snapshot.clippedSamples += 1 }
    }
    deinit { mic.deallocate(); left.deallocate(); right.deallocate() }
}
