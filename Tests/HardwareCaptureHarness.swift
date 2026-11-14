// Opt-in live preview. Processes samples in memory; never creates a SessionStore.
// Run as an app so macOS applies the recorder's normal privacy permissions.
import AppKit
import CoreAudio
import CaptureBridge
@testable import RecorderCore

guard CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--preview",
      let deviceIndex = Int(CommandLine.arguments[2]) else { exit(2) }
freopen(CommandLine.arguments[3], "w", stdout)
setbuf(stdout, nil)

func runChecks() throws {
    let devices = try DeviceCatalog.inputs()
    guard devices.indices.contains(deviceIndex) else { throw RecorderError.message("Invalid device index") }
    let device = devices[deviceIndex]
    let input = ResolvedInput(device: device, channel: 0, selection: .device(uid: device.uid))
    let defaultInput = try DeviceCatalog.defaultInputID()
    let defaultOutput = try HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
    let devicesBefore = Set(try HAL.ids(HAL.system, kAudioHardwarePropertyDevices))
    let tapsBefore = Set(try HAL.ids(HAL.system, kAudioHardwarePropertyTapList))
    print("No-save live preview: \(device.name), channel 1, \(device.sampleRate) Hz; three 3-second cycles. No captured audio will be saved.")
    for cycle in 1...3 {
        let capture = CoreAudioCapture()
        defer { capture.close() }
        try capture.prepare(input: input, queue: .main) { _ in }
        guard let layout = capture.layout, let ring = capture.ring else { throw RecorderError.message("Missing layout/ring") }
        let pipeline = try AudioPipeline(sampleRate: layout.sampleRate, store: nil)
        try capture.start()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var micPeak: Float = 0, systemPeak: Float = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            try pipeline.drain(ring)
            micPeak = max(micPeak, pipeline.snapshot.microphonePeak)
            systemPeak = max(systemPeak, pipeline.snapshot.systemPeak)
            Thread.sleep(forTimeInterval: 0.01)
        }
        let stopErrors = capture.stopIO()
        guard stopErrors.isEmpty else { throw RecorderError.message(stopErrors.joined(separator: "; ")) }
        try pipeline.drain(ring)
        try pipeline.finish()
        let stats = CRRingGetStats(ring)
        let expected = Int64((Double(stats.acceptedFrames) * 48_000 / layout.sampleRate).rounded())
        guard !stats.failed, stats.invalidBuffers == 0, stats.droppedFrames == 0,
              stats.callbacks > 0, abs(pipeline.snapshot.frames - expected) <= 1,
              abs(Double(pipeline.snapshot.frames) / 48_000 - 3) < 0.25 else {
            throw RecorderError.message("Unexpected live duration or buffer failure")
        }
        let cleanupErrors = capture.close()
        guard cleanupErrors.isEmpty else { throw RecorderError.message(cleanupErrors.joined(separator: "; ")) }
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < cleanupDeadline {
            if Set(try HAL.ids(HAL.system, kAudioHardwarePropertyDevices)) == devicesBefore,
               Set(try HAL.ids(HAL.system, kAudioHardwarePropertyTapList)) == tapsBefore { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard Set(try HAL.ids(HAL.system, kAudioHardwarePropertyDevices)) == devicesBefore,
              Set(try HAL.ids(HAL.system, kAudioHardwarePropertyTapList)) == tapsBefore else {
            throw RecorderError.message("Audio resources did not return to baseline")
        }
        print("PASS cycle \(cycle): \(stats.callbacks) callbacks, \(stats.acceptedFrames) source frames → \(pipeline.snapshot.frames) output frames; zero drops; mic peak \(micPeak), system peak \(systemPeak). Resources released.")
    }
    guard let after = try DeviceCatalog.inputs().first(where: { $0.uid == device.uid }),
          after.sampleRate == device.sampleRate,
          try DeviceCatalog.defaultInputID() == defaultInput,
          try HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0)) == defaultOutput else {
        throw RecorderError.message("Hardware rate or default routing changed")
    }
    print("PASS three live Start/Stop cycles through the production capture and conversion pipeline; microphone rate/default input/output unchanged. No speech intelligibility or long-run drift claim.")
}
DispatchQueue.global(qos: .userInitiated).async {
    do { try runChecks(); exit(0) }
    catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
}
DispatchQueue.global().asyncAfter(deadline: .now() + 30) { print("FAIL: live preview timed out"); exit(3) }
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
