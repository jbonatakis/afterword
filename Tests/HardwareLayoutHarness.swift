// Read-only device interrogation plus temporary private resources; never AudioDeviceStart.
import Foundation
import CoreAudio
@testable import RecorderCore
setbuf(stdout, nil)


func runChecks() throws {
let devices = try DeviceCatalog.inputs()
let defaultID = try DeviceCatalog.defaultInputID()
for (index, device) in devices.enumerated() {
    print("\(index): \(DeviceSelection.displayName(device, in: devices)); default=\(device.objectID == defaultID); \(device.channels.count) channels; \(device.sampleRate) Hz")
}
guard CommandLine.arguments.count == 2, let index = Int(CommandLine.arguments[1]), devices.indices.contains(index) else { exit(0) }
let device = devices[index]
let input = ResolvedInput(device: device, channel: 0, selection: .device(uid: device.uid))
func resources() throws -> (Set<AudioObjectID>, Set<AudioObjectID>) {
    (Set(try HAL.ids(HAL.system, kAudioHardwarePropertyDevices)), Set(try HAL.ids(HAL.system, kAudioHardwarePropertyTapList)))
}
let baseline = try resources()
func verifyCleanup() throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var after = try resources()
    while (after.0 != baseline.0 || after.1 != baseline.1) && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.02)
        after = try resources()
    }
    guard after.0 == baseline.0 && after.1 == baseline.1 else {
        throw RecorderError.message("Resource lists did not return to baseline: new devices \(after.0.subtracting(baseline.0)), missing devices \(baseline.0.subtracting(after.0)), new taps \(after.1.subtracting(baseline.1)), missing taps \(baseline.1.subtracting(after.1))")
    }
}
let preparationStages = CapturePreparationStage.allCases.filter { $0 != .callbackRegistered }
for failure in preparationStages {
    let capture = CoreAudioCapture { stage in
        if stage == failure { throw RecorderError.message("Injected failure after \(stage.rawValue)") }
    }
    do { try capture.prepare(input: input, queue: .main) { _ in }; throw RecorderError.message("Failure was not injected") }
    catch { guard error.localizedDescription.contains("Injected failure") else { throw error } }
    guard capture.ring == nil else { throw RecorderError.message("Queue was not released") }
    try verifyCleanup()
    print("PASS balanced teardown after \(failure.rawValue)")
}
for cycle in 1...50 {
    let capture = CoreAudioCapture()
    try capture.prepare(input: input, queue: .main) { _ in }
    if cycle == 1 {
        print("Verified layout: \(String(describing: capture.layout))")
        print(String(data: try JSONEncoder().encode(capture.formats), encoding: .utf8)!)
    }
    capture.close()
    try verifyCleanup()
}
let afterwards = try DeviceCatalog.inputs().first { $0.uid == device.uid }!
guard afterwards.sampleRate == device.sampleRate else { throw RecorderError.message("Hardware sample rate changed") }
let finalDefault = try DeviceCatalog.defaultInputID()
guard finalDefault == defaultID else { throw RecorderError.message("Default input changed") }
print("PASS 50 prepare/teardown cycles; five injected preparation failures; no orphaned resources, microphone rate or default-input changes. IOProc registration and audio IO were not exercised.")

}
DispatchQueue.global(qos: .userInitiated).async {
    do { try runChecks(); exit(0) }
    catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
}
DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
    print("FAIL: Core Audio layout/lifecycle check timed out; no IO was started."); exit(3)
}
// HAL uses CFRunLoop sources as well as the main dispatch queue. Match AppKit's
// event loop instead of blocking the main thread in a command-line dispatchMain.
RunLoop.main.add(Port(), forMode: .default)
RunLoop.main.run()
