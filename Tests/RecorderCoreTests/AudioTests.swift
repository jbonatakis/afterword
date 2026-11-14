#if canImport(XCTest)
import XCTest
#endif
import AVFoundation
import CaptureBridge
@testable import RecorderCore

final class AudioTests: XCTestCase {
    func testFixedMixCentersMonoAndSafelyHandlesInvalidSamples() {
        let mono = FixedMix.sample(microphone: 0.8, left: 0, right: 0)
        XCTAssertEqual(mono.0, 0.4); XCTAssertEqual(mono.1, 0.4)
        let pair = FixedMix.sample(microphone: 0.4, left: 0.8, right: -0.2)
        XCTAssertEqual(pair.0, 0.6, accuracy: 0.00001); XCTAssertEqual(pair.1, 0.1, accuracy: 0.00001)
        let muted = FixedMix.sample(microphone: 1, left: 0.4, right: -0.4, microphoneEnabled: false)
        XCTAssertEqual(muted.0, 0.2); XCTAssertEqual(muted.1, -0.2)
        let invalid = FixedMix.sample(microphone: .nan, left: .infinity, right: 3)
        XCTAssertEqual(invalid.0, 0); XCTAssertEqual(invalid.1, 0.5)
    }
    func testDynamicChannelReferencesAcrossBuffers() throws {
        let ref = try CaptureLayout.reference(channel: 7, buffers: [2, 3, 1, 2])
        XCTAssertEqual(ref.buffer, 3); XCTAssertEqual(ref.channel, 1)
        XCTAssertThrowsError(try CaptureLayout.reference(channel: 8, buffers: [2,3,1,2]))
    }
    func testMixedRateAggregateAcceptsNativeStreamMetadataAndRejectsUnsafeFormats() throws {
        var format = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        try CaptureLayout.validate(format: format, startingChannel: 0, totalChannels: 4)
        format.mSampleRate = 48_000
        try CaptureLayout.validate(format: format, startingChannel: 2, totalChannels: 4)
        XCTAssertThrowsError(try CaptureLayout.validate(format: format, startingChannel: 3, totalChannels: 4))
        for rate in [Double.nan, .infinity, 0, 384_000] {
            var invalid = format; invalid.mSampleRate = rate
            XCTAssertThrowsError(try CaptureLayout.validate(format: invalid, startingChannel: 2, totalChannels: 4))
        }
        for flags in [kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                      kAudioFormatFlagIsFloat, format.mFormatFlags | kAudioFormatFlagIsBigEndian] {
            var invalid = format; invalid.mFormatFlags = flags
            XCTAssertThrowsError(try CaptureLayout.validate(format: invalid, startingChannel: 2, totalChannels: 4))
        }
        format.mBitsPerChannel = 64
        XCTAssertThrowsError(try CaptureLayout.validate(format: format, startingChannel: 2, totalChannels: 4))
    }
    func withRing(buffers: [UInt32], mic: Int, left: Int, right: Int, slots: UInt32 = 4, body: (OpaquePointer) throws -> Void) throws {
        let m = try CaptureLayout.reference(channel: mic, buffers: buffers)
        let l = try CaptureLayout.reference(channel: left, buffers: buffers)
        let r = try CaptureLayout.reference(channel: right, buffers: buffers)
        let ring = buffers.withUnsafeBufferPointer { CRRingCreate(slots, 64, $0.baseAddress!, UInt32(buffers.count), m,l,r) }!
        defer { CRRingDestroy(ring) }; try body(ring)
    }
    func push(_ ring: OpaquePointer, channels: [UInt32], samples: [[Float]], sampleTime: Double = 0) {
        let abl = AudioBufferList.allocate(maximumBuffers: channels.count)
        var memory: [UnsafeMutablePointer<Float>] = []
        defer { memory.forEach { $0.deallocate() }; abl.unsafeMutablePointer.deallocate() }
        for i in channels.indices {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples[i].count)
            pointer.initialize(from: samples[i], count: samples[i].count); memory.append(pointer)
            abl[i] = AudioBuffer(mNumberChannels: channels[i], mDataByteSize: UInt32(samples[i].count * 4), mData: pointer)
        }
        var time = AudioTimeStamp(); time.mFlags = [.sampleTimeValid, .hostTimeValid]; time.mSampleTime = sampleTime; time.mHostTime = 100
        CRRingPush(ring, abl.unsafePointer, &time)
    }
    func read(_ ring: OpaquePointer) -> ([Float],[Float],[Float],CRBlockInfo)? {
        var mic = [Float](repeating: 0, count: 64), left = mic, right = mic
        var info = CRBlockInfo()
        guard CRRingRead(ring, &mic, &left, &right, &info) else { return nil }
        return (Array(mic.prefix(Int(info.frames))), Array(left.prefix(Int(info.frames))), Array(right.prefix(Int(info.frames))), info)
    }
    func testInterleavedSelectionExcludesUnselectedChannelsAndMuteIsBeforeQueue() throws {
        try withRing(buffers: [4,2], mic: 2, left: 4, right: 5) { ring in
            push(ring, channels: [4,2], samples: [[91,92,0.2,93, 91,92,0.3,93], [0.4,0.5,0.6,0.7]])
            let first = try XCTUnwrap(read(ring))
            XCTAssertEqual(first.0, [0.2,0.3]); XCTAssertEqual(first.1, [0.4,0.6]); XCTAssertEqual(first.2, [0.5,0.7])
            CRRingSetMicrophoneEnabled(ring, false)
            push(ring, channels: [4,2], samples: [[91,92,0.9,93], [0.4,0.5]], sampleTime: 2)
            let muted = try XCTUnwrap(read(ring)); XCTAssertEqual(muted.0, [0]); XCTAssertFalse(muted.3.microphoneEnabled)
            XCTAssertEqual(muted.1, [0.4])
        }
    }
    func testNoninterleavedSilenceAndExactOverflowCounters() throws {
        try withRing(buffers: [1,1,1], mic: 0, left: 1, right: 2, slots: 2) { ring in
            for time in 0..<4 { push(ring, channels: [1,1,1], samples: [[0,0],[0,0],[0,0]], sampleTime: Double(time * 2)) }
            let stats = CRRingGetStats(ring)
            XCTAssertTrue(stats.failed); XCTAssertEqual(stats.droppedFrames, 4); XCTAssertEqual(stats.acceptedFrames, 4)
            XCTAssertEqual(stats.firstDroppedSampleTime, 4); XCTAssertEqual(stats.invalidBuffers, 0)
            XCTAssertEqual(read(ring)?.0, [0,0]); XCTAssertEqual(read(ring)?.0, [0,0]); XCTAssertNil(read(ring))
        }
    }
    func testInvalidLayoutFailsWithoutReadingWrongMemory() throws {
        try withRing(buffers: [1,2], mic: 0, left: 1, right: 2) { ring in
            push(ring, channels: [1,1], samples: [[0],[0]])
            XCTAssertEqual(CRRingGetStats(ring).invalidBuffers, 1); XCTAssertNil(read(ring))
        }
    }
    func testUnequalSourceBufferDurationsAreRejected() throws {
        try withRing(buffers: [2,2], mic: 0, left: 2, right: 3) { ring in
            push(ring, channels: [2,2], samples: [[0,0], [0,0,0,0,0,0]])
            XCTAssertTrue(CRRingGetStats(ring).failed)
            XCTAssertEqual(CRRingGetStats(ring).invalidBuffers, 1)
            XCTAssertNil(read(ring))
        }
    }
    func test44100To48000KeepsTimelineAndStereo() throws {
        let converter = try PCMResampler(sampleRate: 44_100)
        var samples: [Float] = []
        var inputOffset = 0
        while inputOffset < 44_100 {
            let count = min(1_024, 44_100 - inputOffset)
            let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: UInt32(count))!
            input.frameLength = UInt32(count)
            for f in 0..<count {
                let value = Float(sin(Double(inputOffset + f) * 2 * .pi * 440 / 44_100)) * 0.25
                input.floatChannelData![0][f] = value; input.floatChannelData![1][f] = -value
            }
            try converter.append(input) { buffer in
                for f in 0..<Int(buffer.frameLength) {
                    XCTAssertEqual(buffer.floatChannelData![0][f], -buffer.floatChannelData![1][f], accuracy: 0.0001)
                    samples.append(buffer.floatChannelData![0][f])
                }
            }
            inputOffset += count
        }
        try converter.finish { buffer in samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))) }
        XCTAssertEqual(Double(samples.count), 48_000, accuracy: 1)
        XCTAssertEqual(converter.inputFrames, 44_100)
        XCTAssertGreaterThan(samples.map { abs($0) }.max()!, 0.24)
    }
    func testTimestampGapIsNotSilentlyShortened() throws {
        try withRing(buffers: [1,2], mic: 0, left: 1, right: 2) { ring in
            let pipeline = try AudioPipeline(sampleRate: 48_000, store: nil)
            push(ring, channels: [1,2], samples: [[0,0],[0,0,0,0]], sampleTime: 0)
            try pipeline.drain(ring); XCTAssertEqual(pipeline.snapshot.frames, 2)
            push(ring, channels: [1,2], samples: [[0,0],[0,0,0,0]], sampleTime: 4)
            XCTAssertThrowsError(try pipeline.drain(ring))
        }
    }
    func testOtherSupportedSampleRatesPreserveSilentDuration() throws {
        for rate in [8_000.0, 16_000, 32_000, 48_000, 96_000, 192_000] {
            let converter = try PCMResampler(sampleRate: rate)
            let frames = Int(rate / 10)
            let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: UInt32(frames))!
            buffer.frameLength = UInt32(frames)
            for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: frames) }
            var actual = 0
            let check: (AVAudioPCMBuffer) -> Void = { output in
                actual += Int(output.frameLength)
                for channel in 0..<2 {
                    XCTAssertTrue(UnsafeBufferPointer(start: output.floatChannelData![channel], count: Int(output.frameLength)).allSatisfy { $0 == 0 })
                }
            }
            try converter.append(buffer, output: check); try converter.finish(output: check)
            XCTAssertEqual(Double(actual), 4_800, accuracy: 1)
        }
    }
    func testFullPipelinePersistsOnlyChosenChannelMuteAndSilence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let device = InputDevice(objectID: 1, uid: "fixture", name: "Fixture", channels: ["A","B","C"], bufferChannels: [3], sampleRate: 48_000)
        let store = try SessionStore(root: root.appendingPathComponent("sessions"), manifest: SessionManifest(input: ResolvedInput(device: device, channel: 2, selection: .systemDefault), formats: [], destination: destination))
        let pipeline = try AudioPipeline(sampleRate: 48_000, store: store)
        try withRing(buffers: [3,2], mic: 2, left: 3, right: 4) { ring in
            for block in 0..<4 {
                CRRingSetMicrophoneEnabled(ring, block != 1)
                let mic = block == 3 ? [Float](repeating: 0, count: 3) : [1,1,0.25]
                let system: [Float] = block == 3 ? [0,0] : [0.5,-0.5]
                push(ring, channels: [3,2], samples: [Array(repeating: mic, count: 64).flatMap { $0 }, Array(repeating: system, count: 64).flatMap { $0 }], sampleTime: Double(block * 64))
                try pipeline.drain(ring)
            }
            try pipeline.finish()
        }
        XCTAssertEqual(store.manifest.totalFrames, 256)
        XCTAssertEqual(store.manifest.microphoneEvents.map(\.frame), [0,64,128])
        let file = try AVAudioFile(forReading: store.directory.appendingPathComponent(store.manifest.chunks[0].filename))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 256)!
        try file.read(into: buffer)
        XCTAssertEqual(buffer.format.channelCount, 3)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.25)
        XCTAssertEqual(buffer.floatChannelData![1][0], 0.5)
        XCTAssertEqual(buffer.floatChannelData![2][0], -0.5)
        XCTAssertEqual(buffer.floatChannelData![0][64], 0)
        XCTAssertEqual(buffer.floatChannelData![1][64], 0.5)
        XCTAssertEqual(buffer.floatChannelData![2][64], -0.5)
        XCTAssertEqual(buffer.floatChannelData![0][128], 0.25)
        XCTAssertEqual(buffer.floatChannelData![0][255], 0)
        XCTAssertEqual(buffer.floatChannelData![1][255], 0)
        XCTAssertEqual(buffer.floatChannelData![2][255], 0)
    }
    func testResamplerDrainsUpsamplingAcrossMultipleOutputBuffers() throws {
        let converter = try PCMResampler(sampleRate: 8_000)
        let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: 8_192)!
        input.frameLength = 8_192
        for channel in 0..<2 { input.floatChannelData![channel].initialize(repeating: 0, count: 8_192) }
        var count = 0
        var writes = 0
        let collect: (AVAudioPCMBuffer) -> Void = { output in count += Int(output.frameLength); writes += 1 }
        try converter.append(input, output: collect); try converter.finish(output: collect)
        XCTAssertEqual(count, 49_152)
        XCTAssertGreaterThan(writes, 1)
    }
    func test16000HzSeparateTracksPreservePitchDurationAndMuteBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WebcamTimelineTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = InputDevice(objectID: 1, uid: "fixture", name: "16 kHz fixture", channels: ["A", "B"], bufferChannels: [2], sampleRate: 16_000)
        let store = try SessionStore(root: root, manifest: SessionManifest(input: ResolvedInput(device: device, channel: 0, selection: .systemDefault), formats: [], destination: root))
        let pipeline = try AudioPipeline(sampleRate: 16_000, store: store)
        try withRing(buffers: [2,2], mic: 0, left: 2, right: 3) { ring in
            for offset in stride(from: 0, to: 16_000, by: 64) {
                CRRingSetMicrophoneEnabled(ring, offset < 8_000)
                var mic: [Float] = [], system: [Float] = []
                for frame in offset..<(offset + 64) {
                    mic += [0.2 * Float(sin(2 * .pi * 500 * Double(frame) / 16_000)), 9]
                    let tone = 0.4 * Float(sin(2 * .pi * 1_000 * Double(frame) / 16_000))
                    system += [tone, -tone]
                }
                push(ring, channels: [2,2], samples: [mic, system], sampleTime: Double(offset))
                try pipeline.drain(ring)
            }
            try pipeline.finish()
        }
        XCTAssertEqual(pipeline.snapshot.frames, 48_000)
        XCTAssertEqual(pipeline.snapshot.clippedSamples, 0) // Unselected sentinel never reaches the worker.
        XCTAssertEqual(store.manifest.microphoneEvents.map(\.frame), [0,24_000])
        let file = try AVAudioFile(forReading: store.directory.appendingPathComponent(store.manifest.chunks[0].filename))
        let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        try file.read(into: output)
        func amplitude(at frequency: Double, from start: Int, channel: Int) -> Double {
            var real = 0.0, imaginary = 0.0
            for frame in start..<(start + 9_600) {
                let sample = Double(output.floatChannelData![channel][frame])
                let phase = 2 * .pi * frequency * Double(frame) / 48_000
                real += sample * cos(phase); imaginary += sample * sin(phase)
            }
            return 2 * hypot(real, imaginary) / 9_600
        }
        XCTAssertEqual(amplitude(at: 500, from: 4_800, channel: 0), 0.2, accuracy: 0.002)
        XCTAssertEqual(amplitude(at: 1_000, from: 4_800, channel: 1), 0.4, accuracy: 0.002)
        XCTAssertEqual(amplitude(at: 1_000, from: 4_800, channel: 2), 0.4, accuracy: 0.002)
        XCTAssertEqual(amplitude(at: 1_000, from: 4_800, channel: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(amplitude(at: 500, from: 4_800, channel: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(amplitude(at: 500, from: 28_800, channel: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(amplitude(at: 1_000, from: 28_800, channel: 1), 0.4, accuracy: 0.002)
        XCTAssertTrue((24_000..<48_000).allSatisfy { output.floatChannelData![0][$0] == 0 })
    }
}
