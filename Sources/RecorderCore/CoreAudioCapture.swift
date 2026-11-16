import Foundation
import CoreAudio
import CaptureBridge

enum CapturePreparationStage: String, CaseIterable {
    case tapCreated, aggregateCreated, layoutValidated, queueAllocated, callbackRegistered, observationsAttached
}

public struct CaptureLayout {
    // The IOProc's timeline rate, which may differ from a tap stream's reported ASBD.
    public let sampleRate: Double
    public let buffers: [UInt32]
    public let microphoneChannel: Int
    public let systemLeftChannel: Int
    public let systemRightChannel: Int
    static func validate(format: AudioStreamBasicDescription, startingChannel: Int, totalChannels: Int) throws {
        let channelCount = Int(format.mChannelsPerFrame)
        let bytesPerFrame = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? UInt64(4) : UInt64(channelCount) * 4
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32,
              format.mSampleRate.isFinite, (8_000...192_000).contains(format.mSampleRate),
              UInt64(format.mBytesPerFrame) == bytesPerFrame,
              format.mFramesPerPacket == 1, format.mBytesPerPacket == format.mBytesPerFrame,
              channelCount > 0, startingChannel >= 0,
              startingChannel <= totalChannels, channelCount <= totalChannels - startingChannel else {
            throw RecorderError.message("Unsupported capture stream at channel \(startingChannel + 1). Packed little-endian Float32 PCM with a valid channel layout is required.")
        }
        // A drift-compensated tap can retain its native rate in the stream ASBD
        // while HAL delivers equal-sized buffers on the aggregate clock. Verified
        // with a 16 kHz C920 + 48 kHz tap and a live tone on macOS 15.8.1.
        // Do not independently resample the tap from this metadata: that would
        // convert it twice. The ring checks equal frame counts at runtime, and
        // AudioPipeline checks timestamp continuity before converting the sources together.
    }
    public static func reference(channel: Int, buffers: [UInt32]) throws -> CRChannel {
        guard channel >= 0 else { throw RecorderError.message("Invalid channel index.") }
        var offset = channel
        for (index, count) in buffers.enumerated() {
            if offset < Int(count) { return CRChannel(buffer: UInt32(index), channel: UInt32(offset)) }
            offset -= Int(count)
        }
        throw RecorderError.message("Audio channel is outside the discovered layout.")
    }
}

// Owned exclusively by the recording worker. The HAL callback accesses only ring.
public final class CoreAudioCapture {
    public static let maxFrames: UInt32 = 8192
    public private(set) var ring: OpaquePointer?
    public private(set) var layout: CaptureLayout?
    public private(set) var formats: [SourceFormat] = []
    private var tap: AudioObjectID = 0
    private var aggregate: AudioDeviceID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var started = false
    private var observations: [HALObservation] = []
    private var inputID: AudioDeviceID = 0
    private let checkpoint: (CapturePreparationStage) throws -> Void
    public convenience init() { self.init(checkpoint: { _ in }) }
    init(checkpoint: @escaping (CapturePreparationStage) throws -> Void) { self.checkpoint = checkpoint }

    public func prepare(input: ResolvedInput, queue: DispatchQueue, changed: @escaping (String) -> Void) throws {
        do {
            inputID = input.device.objectID
            guard input.device.channels.indices.contains(input.channel) else { throw RecorderError.message("Choose a valid microphone channel.") }
            let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [try HAL.ownProcess()])
            desc.name = "Afterword system audio"
            desc.isPrivate = true
            desc.muteBehavior = .unmuted
            try HAL.check(AudioHardwareCreateProcessTap(desc, &tap), "Create system audio tap")
            try checkpoint(.tapCreated)
            let tapUID = try HAL.string(tap, kAudioTapPropertyUID)
            let tapFormat = try HAL.value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard tapFormat.mChannelsPerFrame == 2 else { throw RecorderError.message("System audio tap did not expose stereo audio.") }
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Afterword session",
                kAudioAggregateDeviceUIDKey: "io.local.callrecorder.session.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                // A stacked/multi-output aggregate omits the input-only mic on macOS 15.8.1.
                // Use an ordinary aggregate; both source spans were verified via HAL.
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: input.device.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: input.device.uid, kAudioSubDeviceDriftCompensationKey: false]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
                // false is essential: true waits for NON-SILENT application playback to start.
                kAudioAggregateDeviceTapAutoStartKey: false
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "Create private capture aggregate")
            try checkpoint(.aggregateCreated)
            // HAL publishes aggregate subdevices asynchronously. Wait for the declared
            // composition to become active before deriving channel references.
            var buffers = try HAL.bufferChannels(aggregate)
            let expectedChannels = input.device.channels.count + 2
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while buffers.reduce(0, +) != expectedChannels && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.02)
                buffers = try HAL.bufferChannels(aggregate)
            }
            let rate = try HAL.value(aggregate, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
            guard rate.isFinite, rate >= 8_000, rate <= 192_000 else { throw RecorderError.message("Unsupported aggregate sample rate.") }
            let subUIDs = try HAL.strings(aggregate, kAudioAggregateDevicePropertyFullSubDeviceList)
            let tapUIDs = try HAL.strings(aggregate, kAudioAggregateDevicePropertyTapList)
            guard subUIDs == [input.device.uid], tapUIDs == [tapUID] else {
                throw RecorderError.message("Aggregate composition could not be verified; recording has not started.")
            }
            guard try HAL.string(aggregate, kAudioAggregateDevicePropertyMainSubDevice) == input.device.uid,
                  try HAL.ids(aggregate, kAudioAggregateDevicePropertyActiveSubDeviceList) == [inputID] else {
                throw RecorderError.message("The microphone clock source is not active in the aggregate.")
            }
            // Some macOS releases publish an inactive subtap object until IO starts.
            // Verify the accepted composition here; long-run alignment still requires measurement.
            let composition = try HAL.dictionary(aggregate, kAudioAggregateDevicePropertyComposition)
            guard let tapEntries = composition[kAudioAggregateDeviceTapListKey] as? [[String: Any]], tapEntries.count == 1,
                  (tapEntries[0][kAudioSubTapDriftCompensationKey] as? NSNumber)?.boolValue == true else {
                throw RecorderError.message("System audio clock drift compensation could not be verified.")
            }
            // HAL's ordered subdevice composition determines stream order. Derive the mic
            // span from its current stream configuration, then verify every aggregate span.
            let micChannels = Int(try HAL.bufferChannels(inputID).reduce(0, +))
            guard micChannels == input.device.channels.count,
                  buffers.reduce(0, +) == micChannels + 2 else {
                throw RecorderError.message("The aggregate input layout differs from the microphone plus stereo tap (microphone: \(micChannels), aggregate buffers: \(buffers)). This configuration is unsupported.")
            }
            let streams = try HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var covered = Set<Int>()
            for stream in streams {
                let format = try HAL.format(stream)
                let start = Int(try HAL.value(stream, kAudioStreamPropertyStartingChannel, initial: UInt32(0))) - 1
                try CaptureLayout.validate(format: format, startingChannel: start, totalChannels: micChannels + 2)
                for channel in start..<(start + Int(format.mChannelsPerFrame)) {
                    guard covered.insert(channel).inserted else { throw RecorderError.message("Overlapping aggregate channel spans.") }
                }
                formats.append(SourceFormat(name: "aggregate stream at channel \(start + 1) (reported)", sampleRate: format.mSampleRate,
                                            channels: Int(format.mChannelsPerFrame), formatID: format.mFormatID, flags: format.mFormatFlags,
                                            latencyFrames: (try? HAL.value(stream, kAudioStreamPropertyLatency, initial: UInt32(0))) ?? 0))
            }
            guard covered.count == micChannels + 2 else { throw RecorderError.message("Incomplete aggregate channel map.") }
            formats.append(SourceFormat(name: "aggregate IO timeline", sampleRate: rate, channels: micChannels + 2,
                                        formatID: kAudioFormatLinearPCM, flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, latencyFrames: 0))
            for stream in try HAL.ids(inputID, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput) {
                let f = try HAL.format(stream)
                formats.append(SourceFormat(name: "microphone source", sampleRate: f.mSampleRate, channels: Int(f.mChannelsPerFrame), formatID: f.mFormatID, flags: f.mFormatFlags,
                                            latencyFrames: (try? HAL.value(stream, kAudioStreamPropertyLatency, initial: UInt32(0))) ?? 0))
            }
            formats.append(SourceFormat(name: "system tap", sampleRate: tapFormat.mSampleRate, channels: 2, formatID: tapFormat.mFormatID, flags: tapFormat.mFormatFlags, latencyFrames: 0))
            let deviceLatency = (try? HAL.value(inputID, kAudioDevicePropertyLatency, scope: kAudioDevicePropertyScopeInput, initial: UInt32(0))) ?? 0
            let safety = (try? HAL.value(inputID, kAudioDevicePropertySafetyOffset, scope: kAudioDevicePropertyScopeInput, initial: UInt32(0))) ?? 0
            formats.append(SourceFormat(name: "microphone device latency + safety offset (reported)", sampleRate: input.device.sampleRate, channels: micChannels, formatID: kAudioFormatLinearPCM, flags: 0, latencyFrames: deviceLatency + safety))
            let layout = CaptureLayout(sampleRate: rate, buffers: buffers, microphoneChannel: input.channel, systemLeftChannel: micChannels, systemRightChannel: micChannels + 1)
            self.layout = layout
            try checkpoint(.layoutValidated)
            let mic = try CaptureLayout.reference(channel: input.channel, buffers: buffers)
            let left = try CaptureLayout.reference(channel: micChannels, buffers: buffers)
            let right = try CaptureLayout.reference(channel: micChannels + 1, buffers: buffers)
            ring = buffers.withUnsafeBufferPointer { CRRingCreate(64, Self.maxFrames, $0.baseAddress!, UInt32(buffers.count), mic, left, right) }
            guard ring != nil else { throw RecorderError.message("Could not allocate the bounded audio queue.") }
            try checkpoint(.queueAllocated)
            for (object, selector, scope, message) in [
                (inputID, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, "Microphone disconnected."),
                (inputID, kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput, "Microphone stream configuration changed."),
                (inputID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, "Microphone sample rate changed."),
                (aggregate, kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput, "Capture layout changed."),
                (aggregate, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, "Capture sample rate changed."),
                (tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, "System audio tap format changed."),
                (HAL.system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, "System output route changed; start a new recording after checking Test audio."),
                (HAL.system, kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal, "System sound output route changed."),
                (HAL.system, kAudioHardwarePropertyServiceRestarted, kAudioObjectPropertyScopeGlobal, "Core Audio restarted.")
            ] {
                observations.append(try HALObservation(object: object, selector: selector, scope: scope, queue: queue) { [weak self] in
                    guard self?.started == true else { return }; changed(message)
                })
            }
            let outputID = try HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
            if outputID != 0 {
                for (selector, scope) in [(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
                                          (kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)] {
                    observations.append(try HALObservation(object: outputID, selector: selector, scope: scope, queue: queue) { [weak self] in
                        guard self?.started == true else { return }; changed("System output format changed.")
                    })
                }
            }
            try checkpoint(.observationsAttached)
        } catch { close(); throw error }
    }
    public func start() throws {
        guard let ring, aggregate != 0, ioProc == nil else { throw RecorderError.message("Capture is not prepared or has already started.") }
        // Match Apple's lifecycle: register immediately before starting, after every
        // fallible layout/listener/storage preparation step has completed. In particular,
        // cancelled preparation never leaves a registered but unstarted IO context.
        try HAL.check(AudioDeviceCreateIOProcID(aggregate, CRInputCallback, UnsafeMutableRawPointer(ring), &ioProc), "Create capture IOProc")
        try checkpoint(.callbackRegistered)
        guard let ioProc else { throw RecorderError.message("Core Audio did not return an IOProc.") }
        try HAL.check(CRDisableOutputStreams(aggregate, ioProc), "Disable recorder output streams")
        let status = AudioDeviceStart(aggregate, ioProc)
        if status == kAudioDevicePermissionsError { throw RecorderError.systemAudioPermission("starting capture") }
        try HAL.check(status, "Start microphone and system audio capture")
        started = true
    }
    @discardableResult public func stopIO() -> [String] {
        var errors: [String] = []
        observations.removeAll()
        // Stop even when Start never succeeded: HAL may have initialized an IO
        // context during registration. Balance that context before destroying it.
        if let ioProc {
            let status = AudioDeviceStop(aggregate, ioProc)
            if status == noErr || status == kAudioHardwareNotRunningError { started = false }
            else { errors.append(RecorderError.osStatus("Stop capture IO", status).localizedDescription) }
        }
        if let ioProc {
            let status = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            if status == noErr { self.ioProc = nil; started = false }
            else { errors.append(RecorderError.osStatus("Destroy capture IOProc", status).localizedDescription) }
        }
        return errors
    }
    @discardableResult public func close() -> [String] {
        var errors = stopIO()
        if aggregate != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            if status == noErr { aggregate = 0; ioProc = nil; started = false }
            else { errors.append(RecorderError.osStatus("Destroy session aggregate", status).localizedDescription) }
        }
        // If the driver failed both stop/destroy, retain callback storage instead of
        // freeing memory still referenced by HAL. Quitting releases it with the process.
        if ioProc == nil { if let ring { CRRingDestroy(ring) }; ring = nil }
        if tap != 0 && aggregate == 0 {
            let status = AudioHardwareDestroyProcessTap(tap)
            if status == noErr { tap = 0 }
            else { errors.append(RecorderError.osStatus("Destroy session tap", status).localizedDescription) }
        }
        return errors
    }
    deinit { close() }
}
