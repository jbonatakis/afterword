import Foundation
import CoreAudio
import AVFoundation

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw RecorderError.osStatus(operation, status) }
    }
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var addr = address(selector, scope)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &result) { pointer in
            try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer), "Read HAL property \(selector)")
        }
        return result
    }
    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "Read HAL list size")
        guard size % 4 == 0, size < 1_000_000 else { throw RecorderError.message("Invalid HAL object list.") }
        var result = [AudioObjectID](repeating: 0, count: Int(size / 4))
        if size > 0 {
            try result.withUnsafeMutableBytes { bytes in
                try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, bytes.baseAddress!), "Read HAL object list")
            }
        }
        return result
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> String {
        var addr = address(selector, scope, element)
        var string: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &string), "Read HAL string")
        guard let string else { throw RecorderError.message("Audio device has no identifier/name.") }
        return string.takeRetainedValue() as String
    }
    static func strings(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [String] {
        var addr = address(selector)
        var array: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &array), "Read HAL string list")
        guard let result = array?.takeRetainedValue() as? [String] else { throw RecorderError.message("Invalid HAL string list.") }
        return result
    }
    static func dictionary(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [String: Any] {
        var addr = address(selector)
        var dictionary: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &dictionary), "Read HAL composition")
        guard let result = dictionary?.takeRetainedValue() as? [String: Any] else { throw RecorderError.message("Invalid HAL composition.") }
        return result
    }
    static func bufferChannels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeInput) throws -> [UInt32] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size), "Read stream configuration size")
        guard size >= MemoryLayout<UInt32>.size, size < 1_000_000 else { throw RecorderError.message("Invalid stream configuration.") }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, memory), "Read stream configuration")
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).map(\.mNumberChannels)
    }
    static func format(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription {
        try value(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
    }
    static func ownProcess() throws -> AudioObjectID {
        var pid = getpid()
        var object: AudioObjectID = 0
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object), "Resolve recorder process object")
        guard object != kAudioObjectUnknown else { throw RecorderError.message("Core Audio has not exposed this application's process object. Try again.") }
        return object
    }
}

public final class HALObservation {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    init(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, queue: DispatchQueue, changed: @escaping () -> Void) throws {
        self.object = object; self.address = HAL.address(selector, scope); self.queue = queue
        self.block = { _, _ in changed() }
        try HAL.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block), "Observe audio topology")
    }
    deinit { AudioObjectRemovePropertyListenerBlock(object, &address, queue, block) }
}

public enum DeviceCatalog {
    public static func observeDevice(_ id: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, changed: @escaping () -> Void) throws -> HALObservation {
        try HALObservation(object: id, selector: selector, scope: scope, queue: .main, changed: changed)
    }
    public static func defaultInputID() throws -> AudioDeviceID {
        try HAL.value(HAL.system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0))
    }
    public static func inputs() throws -> [InputDevice] {
        try HAL.ids(HAL.system, kAudioHardwarePropertyDevices).compactMap { id in
            guard let buffers = try? HAL.bufferChannels(id), buffers.reduce(0, +) > 0,
                  (try? HAL.value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) == 1,
                  let uid = try? HAL.string(id, kAudioDevicePropertyDeviceUID),
                  let name = try? HAL.string(id, kAudioObjectPropertyName),
                  let rate = try? HAL.value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)) else { return nil }
            let count = Int(buffers.reduce(0, +))
            guard count < 4096, rate.isFinite, rate > 0 else { return nil }
            let labels = (0..<count).map { channel in
                let name = try? HAL.string(id, kAudioObjectPropertyElementName, scope: kAudioDevicePropertyScopeInput, element: UInt32(channel + 1))
                return name?.isEmpty == false ? "\(channel + 1) · \(name!)" : "Channel \(channel + 1)"
            }
            return InputDevice(objectID: id, uid: uid, name: name, channels: labels, bufferChannels: buffers, sampleRate: rate,
                               transport: (try? HAL.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0)
        }
    }
    public static func observe(queue: DispatchQueue = .main, changed: @escaping () -> Void) throws -> [HALObservation] {
        try [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyServiceRestarted].map {
            try HALObservation(object: HAL.system, selector: $0, queue: queue, changed: changed)
        }
    }
}

public enum PermissionService {
    public static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    public static func requestMicrophone() async throws {
        switch microphoneStatus {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.microphonePermission }
        default: throw RecorderError.microphonePermission
        }
    }
    // There is no documented process-tap authorization preflight API on macOS 14.2.
    // System permission is requested by AudioDeviceStart, not AVCaptureDevice.
}
