// Separate process used only by run-crash-test.sh. Never linked into the app.
import Foundation
import AVFoundation
import Darwin
@testable import RecorderCore

let mode = CommandLine.arguments[1]
let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let output = root.appendingPathComponent("output", isDirectory: true)
if mode == "write" {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let device = InputDevice(objectID: 1, uid: "synthetic-crash-fixture", name: "Fixture", channels: ["Mono"], bufferChannels: [1], sampleRate: 48_000)
    let manifest = SessionManifest(input: ResolvedInput(device: device, channel: 0, selection: .systemDefault), formats: [], destination: output)
    let store = try SessionStore(root: root.appendingPathComponent("sessions"), manifest: manifest)
    let buffer = AVAudioPCMBuffer(pcmFormat: store.format, frameCapacity: 4_800)!
    buffer.frameLength = 4_800
    for block in 0..<220 {
        let frequency = block < 100 ? 440.0 : block < 200 ? 880.0 : 1320.0
        for f in 0..<4_800 {
            let value = Float(sin(Double(block * 4_800 + f) * 2 * .pi * frequency / 48_000)) * 0.3
            buffer.floatChannelData![0][f] = value
            buffer.floatChannelData![1][f] = Float(sin(Double(block * 4_800 + f) * 2 * .pi * 1_760 / 48_000)) * 0.2
            buffer.floatChannelData![2][f] = -buffer.floatChannelData![1][f]
        }
        try store.append(buffer)
    }
    try Data(store.directory.path.utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
    // Keep AVAudioFile open so SIGKILL exercises the unfinished CAF path.
    withExtendedLifetime(store) { while true { pause() } }
} else if mode == "recover" {
    let directory = URL(fileURLWithPath: try String(contentsOf: root.appendingPathComponent("ready"), encoding: .utf8))
    let recovered = try Recovery.load(directory: directory)
    precondition(recovered.manifest.totalFrames >= 960_000 && recovered.manifest.totalFrames <= 1_056_000)
    let frames = recovered.manifest.totalFrames
    let fileURL = try Exporter.export(recovered)
    try Exporter.validateDelivery(fileURL, manifest: recovered.manifest)
    let file = try AVAudioFile(forReading: fileURL.deletingLastPathComponent().appendingPathComponent("Microphone.m4a"))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800)!
    func energy(_ frequency: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for index in 0..<Int(buffer.frameLength) {
            let angle = Double(index) * 2 * .pi * frequency / 48_000
            real += Double(buffer.floatChannelData![0][index]) * cos(angle)
            imaginary += Double(buffer.floatChannelData![0][index]) * sin(angle)
        }
        return real * real + imaginary * imaginary
    }
    for (position, wanted, unwanted) in [(48_000, 440.0, 880.0), (528_000, 880.0, 440.0)] {
        file.framePosition = Int64(position); try file.read(into: buffer)
        precondition(energy(wanted) > 100 * max(energy(unwanted), 0.0001), "Recovered audio ordering changed")
        precondition(energy(wanted) > 100 * max(energy(1_760), 0.0001), "System audio leaked into recovered microphone track")
    }
    let system = try AVAudioFile(forReading: fileURL.deletingLastPathComponent().appendingPathComponent("System.m4a"))
    let systemPCM = AVAudioPCMBuffer(pcmFormat: system.processingFormat, frameCapacity: 4_800)!
    system.framePosition = 48_000; try system.read(into: systemPCM)
    var cross = 0.0, power = 0.0
    for frame in 0..<Int(systemPCM.frameLength) {
        let left = Double(systemPCM.floatChannelData![0][frame]), right = Double(systemPCM.floatChannelData![1][frame])
        cross += left * right; power += left * left
    }
    precondition(power > 1 && cross / power < -0.95, "Recovered system stereo changed")
    precondition(system.length == file.length, "Recovered source tracks have different durations")
    print("PASS forced-termination source-track recovery: \(frames) frames, \(Double(frames) / 48000) s; all three AAC files validated; microphone 440 Hz then 880 Hz ordering and system exclusion verified; system stereo and equal source durations verified")
    print("Export: \(fileURL.path)")
} else { exit(2) }
