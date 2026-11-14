import Foundation
import AVFoundation

/// Fixed per-track gain measured over active 100 ms windows. Pauses do not
/// pull down the reference level or cause the gain to rise between words.
struct MixBalancePlan: Equatable, Sendable {
    let microphoneDB: Double?
    let systemDB: Double?
    let microphoneGainDB: Double
    let systemGainDB: Double
    var microphoneGain: Float { Float(pow(10, microphoneGainDB / 20)) }
    var systemGain: Float { Float(pow(10, systemGainDB / 20)) }
}

enum MixBalance {
    static let targetDB = -24.0
    static let maximumBoostDB = 36.0
    static func analyze(_ store: SessionStore) throws -> MixBalancePlan {
        guard store.manifest.hasSeparateTracks else { throw RecorderError.message("Volume balancing requires separate microphone and system tracks.") }
        var microphone = MixLevelMeasurement(), system = MixLevelMeasurement()
        try Exporter.readPCM(store) { input in
            for frame in 0..<Int(input.frameLength) {
                let mic = Double(FixedMix.safe(input.floatChannelData![0][frame]))
                let left = Double(FixedMix.safe(input.floatChannelData![1][frame]))
                let right = Double(FixedMix.safe(input.floatChannelData![2][frame]))
                microphone.append(energy: mic * mic)
                system.append(energy: (left * left + right * right) / 2)
            }
        }
        let mic = microphone.finish(), sys = system.finish()
        return .init(microphoneDB: mic.levelDB, systemDB: sys.levelDB,
                     microphoneGainDB: mic.gainDB, systemGainDB: sys.gainDB)
    }
}

/// Bounded-memory histogram, independent of recording duration and disk chunk
/// boundaries. This estimates active audio levels, not speaker identity/VAD.
struct MixLevelMeasurement {
    private let windowFrames = 4_800
    private var frames = 0
    private var energy = 0.0
    private var counts = [Int](repeating: 0, count: 121)

    mutating func append(energy value: Double) {
        energy += value.isFinite ? max(0, min(1, value)) : 0
        frames += 1
        if frames == windowFrames { commitWindow() }
    }
    private mutating func commitWindow() {
        guard frames > 0 else { return }
        let db = 10 * log10(max(energy / Double(frames), 1e-12))
        let bin = max(0, min(120, Int(db.rounded()) + 120))
        counts[bin] += 1
        frames = 0; energy = 0
    }
    mutating func finish() -> (levelDB: Double?, gainDB: Double) {
        commitWindow()
        // A fully muted or extremely quiet track must not become amplified hiss.
        let minimumBin = 55 // -65 dBFS
        let audible = counts[minimumBin...].reduce(0, +)
        guard audible >= 3 else { return (nil, 0) }
        func percentile(_ fraction: Double, from lower: Int = 55) -> Int {
            let total = counts[lower...].reduce(0, +)
            let target = max(1, Int(ceil(Double(total) * fraction)))
            var count = 0
            for bin in lower...120 {
                count += counts[bin]
                if count >= target { return bin }
            }
            return 120
        }
        let gate = max(minimumBin, percentile(0.95) - 20)
        // A percentile reference prevents an isolated click or handling bump
        // from setting the volume of an otherwise quiet voice.
        let level = Double(percentile(0.70, from: gate) - 120)
        var gain = min(MixBalance.maximumBoostDB, max(-24, MixBalance.targetDB - level))
        // Stationary low-level noise (or a constant tone) is not evidence of
        // quiet speech. Attenuation is still allowed; boosting needs variation.
        if gain > 0, percentile(0.90) - percentile(0.10) < 6 { gain = 0 }
        return (level, gain)
    }
}

/// A stereo-linked speech compressor evens out the remaining phrase-to-phrase
/// variation after track balancing. A separate fast limiter catches transients.
/// Both envelopes preserve the stereo image and add no delay or frame loss.
struct BalancedMixRenderer {
    private var power = 0.0
    private var compressorGain = 1.0
    private var limiterGain: Float = 1
    private let powerCoefficient = exp(-1 / (0.030 * 48_000))
    private let attackCoefficient = exp(-1 / (0.010 * 48_000))
    private let releaseCoefficient = exp(-1 / (0.200 * 48_000))
    private let release = Float(exp(-1 / (0.080 * 48_000)))
    static let makeupGain: Float = 1.4125375 // +3 dB
    static let ceiling: Float = 0.7943282 // -2 dBFS, allowing AAC reconstruction headroom
    private let microphoneGain: Float
    private let systemGain: Float
    init(plan: MixBalancePlan) {
        microphoneGain = plan.microphoneGain; systemGain = plan.systemGain
    }
    mutating func sample(microphone: Float, left: Float, right: Float) -> (Float, Float) {
        let mic = FixedMix.safe(microphone) * microphoneGain
        var left = mic + FixedMix.safe(left) * systemGain
        var right = mic + FixedMix.safe(right) * systemGain
        let energy = (Double(left) * Double(left) + Double(right) * Double(right)) / 2
        power = powerCoefficient * power + (1 - powerCoefficient) * energy
        // -26 dBFS threshold, 3:1 ratio, 6 dB soft knee. The compressor only
        // reduces louder phrases; it never turns up the gain during pauses.
        let over = 10 * log10(max(power, 1e-12)) + 26
        let reduction = over <= -3 ? 0 : over >= 3 ? over * (2.0 / 3) : (over + 3) * (over + 3) / 18
        let target = pow(10, -reduction / 20)
        let coefficient = target < compressorGain ? attackCoefficient : releaseCoefficient
        compressorGain = coefficient * compressorGain + (1 - coefficient) * target
        let gain = Float(compressorGain) * Self.makeupGain
        left *= gain; right *= gain
        let peak = max(abs(left), abs(right))
        let required = peak > Self.ceiling ? Self.ceiling / peak : 1
        if required < limiterGain { limiterGain = required }
        else { limiterGain = release * limiterGain + (1 - release) * required }
        return (left * limiterGain, right * limiterGain)
    }
}
