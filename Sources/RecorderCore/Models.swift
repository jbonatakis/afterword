import Foundation
import CoreAudio

public enum RecorderError: LocalizedError {
    case message(String)
    case osStatus(String, OSStatus)
    case microphonePermission
    case systemAudioPermission(String)
    public var requiresPermission: Bool {
        switch self {
        case .microphonePermission, .systemAudioPermission: return true
        case .osStatus(_, let status): return status == kAudioDevicePermissionsError
        default: return false
        }
    }
    public var errorDescription: String? {
        switch self {
        case .message(let s): return s
        case .microphonePermission: return "Microphone permission is required. Open System Settings → Privacy & Security → Microphone and enable Call Recorder."
        case .systemAudioPermission(let operation): return "System audio access was refused during \(operation). Open System Settings → Privacy & Security and find the screen/system audio recording controls. Enable Call Recorder, then try again."
        case .osStatus(let operation, let code):
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: code) >> (24 - $0 * 8)) }
            let fourCC = bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(bytes: bytes, encoding: .ascii)! : ""
            return "\(operation) failed (OSStatus \(code)\(fourCC.isEmpty ? "" : ", '\(fourCC)'" ))."
        }
    }
}

public enum MicrophoneSelection: Codable, Equatable {
    case systemDefault
    case device(uid: String)
}
public struct ChannelPreference: Codable, Equatable {
    public var index: Int
    public var layout: String
    public init(index: Int, layout: String) { self.index = index; self.layout = layout }
}
public struct InputDevice: Identifiable, Equatable {
    public var id: String { uid }
    public let objectID: AudioDeviceID
    public let uid: String
    public let name: String
    public let channels: [String]
    public let bufferChannels: [UInt32]
    public let sampleRate: Double
    public let transport: UInt32
    public var layout: String { bufferChannels.map(String.init).joined(separator: ",") + "|" + channels.joined(separator: "|") }
    public var needsExplicitVerification: Bool {
        transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate
    }
    public init(objectID: AudioDeviceID, uid: String, name: String, channels: [String], bufferChannels: [UInt32], sampleRate: Double, transport: UInt32 = kAudioDeviceTransportTypeBuiltIn) {
        self.objectID = objectID; self.uid = uid; self.name = name; self.channels = channels
        self.bufferChannels = bufferChannels; self.sampleRate = sampleRate; self.transport = transport
    }
}
public struct ResolvedInput {
    public let device: InputDevice
    public let channel: Int
    public let selection: MicrophoneSelection
    public init(device: InputDevice, channel: Int, selection: MicrophoneSelection) {
        self.device = device; self.channel = channel; self.selection = selection
    }
}
public enum DeviceSelection {
    public static func resolve(_ selection: MicrophoneSelection, devices: [InputDevice], defaultID: AudioDeviceID) throws -> InputDevice {
        let device: InputDevice?
        switch selection {
        case .systemDefault: device = devices.first { $0.objectID == defaultID }
        case .device(let uid): device = devices.first { $0.uid == uid }
        }
        guard let device else {
            throw RecorderError.message(selection == .systemDefault ? "No usable system-default microphone is available." : "Selected microphone unavailable. Choose a replacement or System default.")
        }
        return device
    }
    public static func channel(for device: InputDevice, preferences: [String: ChannelPreference]) -> Int? {
        if let pref = preferences[device.uid] {
            return pref.layout == device.layout && device.channels.indices.contains(pref.index) ? pref.index : nil
        }
        return device.channels.count == 1 && !device.needsExplicitVerification ? 0 : nil
    }
    public static func displayName(_ device: InputDevice, in devices: [InputDevice]) -> String {
        guard devices.filter({ $0.name == device.name }).count > 1 else { return device.name }
        // A stable local hash distinguishes duplicate names without exposing a serial/UID.
        let hash = device.uid.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return "\(device.name) · \(String(format: "%04X", hash & 0xffff))"
    }
}

public enum RecordingState: String, Codable {
    case idle, preparing, recording, previewing, finalizing, needsPermission, error, recoverable

    public enum ToggleAction: Equatable { case start, stop, none }
    public var toggleAction: ToggleAction {
        switch self {
        case .idle, .needsPermission, .error, .recoverable: return .start
        case .preparing, .recording, .previewing: return .stop
        case .finalizing: return .none
        }
    }
}
public struct Lifecycle {
    public private(set) var state: RecordingState = .idle
    public init() {}
    @discardableResult public mutating func begin() -> Bool {
        guard [.idle, .error, .needsPermission, .recoverable].contains(state) else { return false }
        state = .preparing; return true
    }
    @discardableResult public mutating func started(preview: Bool) -> Bool {
        guard state == .preparing else { return false }
        state = preview ? .previewing : .recording; return true
    }
    @discardableResult public mutating func stop() -> Bool {
        guard [.preparing, .recording, .previewing].contains(state) else { return false }
        state = .finalizing; return true
    }
    public mutating func finish(_ state: RecordingState = .idle) { self.state = state }
}

public struct SourceFormat: Codable, Equatable {
    public var name: String
    public var sampleRate: Double
    public var channels: Int
    public var formatID: UInt32
    public var flags: UInt32
    public var latencyFrames: UInt32
}
public struct PipelineSnapshot {
    public var frames: Int64 = 0
    public var microphonePeak: Float = 0
    public var systemPeak: Float = 0
    public var clippedSamples: UInt64 = 0
    public var invalidSamples: UInt64 = 0
    public var callbacks: UInt64 = 0
    public var droppedFrames: UInt64 = 0
    public init() {}
}

public enum StorageGuard {
    public static let startReserve: Int64 = 1_000_000_000
    public static let emergencyReserve: Int64 = 256_000_000
    public static let pcmBytesPerSecond: Int64 = 48_000 * 3 * 4
    public static func available(at url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let free = attrs[.systemFreeSize] as? NSNumber else { throw RecorderError.message("Cannot determine available disk space.") }
        return free.int64Value
    }
    public static func check(_ url: URL, reserve: Int64) throws {
        let free = try available(at: url)
        guard free >= reserve else { throw RecorderError.message("Low disk space: \(free / 1_000_000) MB available at \(url.lastPathComponent). Recording needs a \(reserve / 1_000_000) MB reserve.") }
    }
}
