#if canImport(XCTest)
import XCTest
#endif
import AVFoundation
@testable import RecorderCore

final class MixBalanceTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("balance-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func store(balance: Bool = true) throws -> SessionStore {
        let device = InputDevice(objectID: 1, uid: "fixture", name: "Fixture", channels: ["Mic"], bufferChannels: [1], sampleRate: 48_000)
        let destination = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let manifest = SessionManifest(input: .init(device: device, channel: 0, selection: .systemDefault), formats: [], destination: destination, balanceMix: balance)
        let store = try SessionStore(root: root.appendingPathComponent("sessions"), manifest: manifest)
        let buffer = AVAudioPCMBuffer(pcmFormat: store.format, frameCapacity: 4800)!
        for window in 0..<120 {
            buffer.frameLength = 4800
            for frame in 0..<4800 {
                let time = Double(window * 4800 + frame) / 48000
                let envelope = 0.15 + 0.85 * pow(sin(.pi * time * 2.5), 2)
                let mic = ((0.5..<5).contains(time) || (10.5..<11.5).contains(time)) ? 0.003 * envelope * sin(2 * .pi * 440 * time) : 0
                let sys = ((5.5..<10).contains(time) || (10.5..<11.5).contains(time)) ? 0.3 * envelope * sin(2 * .pi * 880 * time) : 0
                buffer.floatChannelData![0][frame] = Float(mic)
                buffer.floatChannelData![1][frame] = Float(sys)
                buffer.floatChannelData![2][frame] = Float(sys * 0.5)
            }
            // An isolated loud bump should be limited, not determine voice gain.
            if window == 104 { buffer.floatChannelData![0][200] = 0.9 }
            try store.append(buffer)
        }
        try store.finish(); return store
    }
    private func read(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
        try file.read(into: buffer); return buffer
    }
    private func rms(_ audio: AVAudioPCMBuffer, start: Double, end: Double, channel: Int? = nil) -> Double {
        let begin = Int(start * 48000), finish = Int(end * 48000)
        let channels = channel.map { [$0] } ?? Array(0..<Int(audio.format.channelCount))
        var energy = 0.0
        for c in channels { for frame in begin..<finish { let sample = Double(audio.floatChannelData![c][frame]); energy += sample * sample } }
        return sqrt(energy / Double((finish - begin) * channels.count))
    }
    func testBalancedAACBringsAlternatingVoicesTogetherKeepsSourcesAndTimeline() throws {
        let session = try store(), plan = try MixBalance.analyze(session)
        XCTAssertTrue(plan.microphoneGainDB > 25)
        XCTAssertTrue(plan.systemGainDB < 0)
        let mixed = try Exporter.export(session), folder = mixed.deletingLastPathComponent()
        let mix = try read(mixed), mic = try read(folder.appendingPathComponent("Microphone.m4a")), system = try read(folder.appendingPathComponent("System.m4a"))
        let gap = 20 * log10(rms(mix, start: 1, end: 4.5) / rms(mix, start: 6, end: 9.5))
        XCTAssertTrue(abs(gap) < 2)
        XCTAssertTrue(20 * log10(rms(system, start: 6, end: 9.5) / rms(mic, start: 1, end: 4.5)) > 35)
        XCTAssertEqual(mix.frameLength, 576000); XCTAssertEqual(mic.frameLength, mix.frameLength); XCTAssertEqual(system.frameLength, mix.frameLength)
        XCTAssertEqual(rms(mix, start: 1, end: 4.5, channel: 0), rms(mix, start: 1, end: 4.5, channel: 1), accuracy: 0.001)
        XCTAssertEqual(rms(mix, start: 6, end: 9.5, channel: 0) / rms(mix, start: 6, end: 9.5, channel: 1), 2, accuracy: 0.05)
        XCTAssertTrue(rms(mix, start: 0, end: 0.4) < 0.0001)
        XCTAssertTrue(rms(mix, start: 11.7, end: 12) < 0.0001)
        for c in 0..<2 { XCTAssertTrue((0..<Int(mix.frameLength)).allSatisfy { mix.floatChannelData![c][$0].isFinite && abs(mix.floatChannelData![c][$0]) < 1 }) }
    }
    func testDisabledAndLegacyRecoveryUseOriginalFixedGainMix() throws {
        let session = try store(balance: false)
        let output = try Exporter.export(session)
        let mix = try read(output), mic = try read(output.deletingLastPathComponent().appendingPathComponent("Microphone.m4a"))
        XCTAssertEqual(rms(mix, start: 1, end: 4.5) / rms(mic, start: 1, end: 4.5), 0.5, accuracy: 0.02)
        let old = try store()
        let path = old.directory.appendingPathComponent("manifest.json")
        var data = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        data.removeValue(forKey: "balanceMix")
        try JSONSerialization.data(withJSONObject: data).write(to: path)
        let recovered = try Recovery.load(directory: old.directory)
        XCTAssertNil(recovered.manifest.balanceMix)
        let legacy = try read(Exporter.export(recovered))
        XCTAssertEqual(rms(legacy, start: 1, end: 4.5), rms(mix, start: 1, end: 4.5), accuracy: 0.0001)
    }
    func testRecoveryKeepsBalanceSettingAndDeterministicAnalysis() throws {
        let session = try store(), plan = try MixBalance.analyze(session)
        let recovered = try Recovery.load(directory: session.directory)
        XCTAssertEqual(recovered.manifest.balanceMix, true)
        XCTAssertEqual(try MixBalance.analyze(recovered), plan)
    }
    func testSilenceAndStationaryNoiseAreNotBoostedAndBoostIsBounded() {
        var silence = MixLevelMeasurement(), noise = MixLevelMeasurement(), quietSpeech = MixLevelMeasurement()
        for index in 0..<48000 {
            silence.append(energy: 0)
            noise.append(energy: 0.000001) // -60 dBFS, constant noise power
            let energy = index % 9600 < 4800 ? 0.0000004 : 0.000004
            quietSpeech.append(energy: energy)
        }
        XCTAssertEqual(silence.finish().gainDB, 0); XCTAssertNil(silence.finish().levelDB)
        XCTAssertEqual(noise.finish().gainDB, 0)
        XCTAssertTrue(quietSpeech.finish().gainDB > 20 && quietSpeech.finish().gainDB <= MixBalance.maximumBoostDB)
    }
    func testLinkedLimiterHandlesOverlapInvalidSamplesAndReleasesWithoutDelay() {
        let plan = MixBalancePlan(microphoneDB: nil, systemDB: nil, microphoneGainDB: 36, systemGainDB: 0)
        var renderer = BalancedMixRenderer(plan: plan)
        for _ in 0..<100 {
            let sample = renderer.sample(microphone: 1, left: 1, right: -0.5)
            XCTAssertTrue(abs(sample.0) <= BalancedMixRenderer.ceiling + 0.00001 && abs(sample.1) <= BalancedMixRenderer.ceiling + 0.00001)
        }
        let invalid = renderer.sample(microphone: .nan, left: .infinity, right: -.infinity)
        XCTAssertEqual(invalid.0, 0); XCTAssertEqual(invalid.1, 0)
        for _ in 0..<96000 { _ = renderer.sample(microphone: 0, left: 0, right: 0) }
        let recovered = renderer.sample(microphone: 0, left: 0.1, right: 0.05)
        XCTAssertEqual(recovered.0, 0.1 * BalancedMixRenderer.makeupGain, accuracy: 0.002)
        XCTAssertEqual(recovered.0 / recovered.1, 2, accuracy: 0.0001)
    }
    func testCompressorReducesResidualPhraseVolumeDifference() {
        var renderer = BalancedMixRenderer(plan: .init(microphoneDB: nil, systemDB: nil, microphoneGainDB: 0, systemGainDB: 0))
        var energy = [0.0, 0.0]
        for section in 0..<2 {
            let amplitude = section == 0 ? 0.1 : 0.4
            for frame in 0..<144000 {
                let input = Float(amplitude * sin(2 * .pi * 440 * Double(frame) / 48000))
                let output = renderer.sample(microphone: input, left: 0, right: 0)
                if frame >= 96000 { energy[section] += Double(output.0) * Double(output.0) }
            }
        }
        let gap = 10 * log10(energy[1] / energy[0])
        XCTAssertTrue(gap > 2 && gap < 5)
        let silence = renderer.sample(microphone: 0, left: 0, right: 0)
        XCTAssertEqual(silence.0, 0); XCTAssertEqual(silence.1, 0)
    }

}
