import Foundation

public enum SpeakerBleedReduction: String, Codable, Sendable {
    case enabled, disabled, unavailable
    public static let preferenceKey = "reduceSpeakerBleed"
    public static func preference(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) == nil ? true : defaults.bool(forKey: preferenceKey)
    }
    public static func resolve(enabled: Bool, input: TranscriptionInput) -> SpeakerBleedReduction {
        guard enabled else { return .disabled }
        return input.tracks.count == 2 && Set(input.tracks.map(\.source)) == [.microphone, .system] ? .enabled : .unavailable
    }
    public var description: String {
        switch self {
        case .enabled: return "On"
        case .disabled: return "Off"
        case .unavailable: return "Not applied (separate microphone and system tracks required)"
        }
    }
}

public struct EchoCancellationDetails: Codable, Equatable, Sendable {
    public let engine: String
    public let referenceLookaheadMilliseconds: Int
    public let sampleRate: Int
    public init(engine: String, referenceLookaheadMilliseconds: Int, sampleRate: Int) {
        self.engine = engine; self.referenceLookaheadMilliseconds = referenceLookaheadMilliseconds; self.sampleRate = sampleRate
    }
}

public struct TranscriptionCompletion: Decodable, Sendable {
    public let engine: String
    public let speakerBleedReductionApplied: Bool
    public let echoCancellation: EchoCancellationDetails?

    public func validate(expected: SpeakerBleedReduction) throws {
        guard speakerBleedReductionApplied == (expected == .enabled) else {
            throw RecorderError.message("Speaker bleed reduction did not match the selected setting. No transcript was saved. Rebuild or reinstall Call Recorder.")
        }
        if speakerBleedReductionApplied {
            guard let details = echoCancellation, !details.engine.isEmpty,
                  details.sampleRate == 16000, details.referenceLookaheadMilliseconds == 40 else {
                throw RecorderError.message("The transcription worker did not confirm valid speaker bleed reduction. No transcript was saved.")
            }
        } else if echoCancellation != nil {
            throw RecorderError.message("The transcription worker returned unexpected cleanup metadata.")
        }
    }
}
