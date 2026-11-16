import Foundation
import CaptureBridge

public enum EngineEvent {
    case prepared(formats: [SourceFormat], layout: CaptureLayout)
    case started
    case levels(PipelineSnapshot)
    case finalizing
    case finished(file: URL?, reason: String?, recovery: URL?, needsPermission: Bool)
}

public final class RecordingEngine {
    private let queue = DispatchQueue(label: "io.local.callrecorder.audio-worker", qos: .userInitiated)
    private let onEvent: (EngineEvent) -> Void
    private var capture: CoreAudioCapture?
    private var pipeline: AudioPipeline?
    private var store: SessionStore?
    private var timer: DispatchSourceTimer?
    private var active = false
    private var announced = false
    private var preview = false
    private var startTime: TimeInterval = 0
    private var lastUI: TimeInterval = 0
    private var lastCallbackTime: TimeInterval = 0
    private var lastCallbackCount: UInt64 = 0
    // This lock is NEVER taken by the HAL callback. It protects the ring's lifetime
    // while a UI toggle updates its atomic flag without waiting behind disk/encoding work.
    private let controlLock = NSLock()
    private var controlRing: OpaquePointer?
    private var desiredMicrophoneEnabled = true
    private var permissionFailure = false
    private var lastPermissionCheck: TimeInterval = 0
    public init(onEvent: @escaping (EngineEvent) -> Void) { self.onEvent = onEvent }
    public func start(input: ResolvedInput, destination: URL, preview: Bool, microphoneEnabled: Bool, callDetails: CallDetails? = nil, balanceMix: Bool = true) {
        controlLock.lock(); desiredMicrophoneEnabled = microphoneEnabled; controlLock.unlock()
        queue.async { [self] in
            guard !active else { return }
            active = true; self.preview = preview; announced = false; permissionFailure = false
            do {
                if !preview {
                    try PrivateFiles.directory(SessionStore.defaultRoot)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    }
                    try StorageGuard.check(SessionStore.defaultRoot, reserve: StorageGuard.startReserve)
                    try StorageGuard.check(destination, reserve: StorageGuard.startReserve)
                }
                let capture = CoreAudioCapture(); self.capture = capture
                try capture.prepare(input: input, queue: queue) { [weak self] message in self?.finish(reason: message) }
                guard let layout = capture.layout, let ring = capture.ring else { throw RecorderError.message("Capture layout is unavailable.") }
                onEvent(.prepared(formats: capture.formats, layout: layout))
                if !preview {
                    store = try SessionStore(manifest: SessionManifest(input: input, formats: capture.formats, destination: destination, callDetails: callDetails, balanceMix: balanceMix))
                }
                pipeline = try AudioPipeline(sampleRate: layout.sampleRate, store: store)
                controlLock.lock()
                controlRing = ring; CRRingSetMicrophoneEnabled(ring, desiredMicrophoneEnabled)
                controlLock.unlock()
                try capture.start()
                startTime = ProcessInfo.processInfo.systemUptime; lastCallbackTime = startTime
                lastCallbackCount = 0; lastUI = 0
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
            } catch {
                permissionFailure = (error as? RecorderError)?.requiresPermission ?? false
                finish(reason: error.localizedDescription)
            }
        }
    }
    public func setMicrophoneEnabled(_ enabled: Bool) {
        controlLock.lock(); defer { controlLock.unlock() }
        desiredMicrophoneEnabled = enabled
        if let controlRing { CRRingSetMicrophoneEnabled(controlRing, enabled) }
    }
    public func stop(reason: String? = nil) { queue.async { [weak self] in self?.finish(reason: reason) } }
    private func tick() {
        guard active, let ring = capture?.ring, let pipeline else { return }
        do {
            let stats = CRRingGetStats(ring)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPermissionCheck >= 2 {
                lastPermissionCheck = now
                if PermissionService.microphoneStatus != .authorized { permissionFailure = true; throw RecorderError.microphonePermission }
            }
            if stats.callbacks != lastCallbackCount { lastCallbackCount = stats.callbacks; lastCallbackTime = now }
            if !announced {
                if stats.acceptedFrames > 0 && !stats.failed { announced = true; onEvent(.started) }
                else if now - startTime > 10 {
                    throw RecorderError.message("Capture did not deliver valid buffers within 10 seconds. Check system audio permission in System Settings and the selected devices. Silence alone is not a permission failure.")
                }
            } else if now - lastCallbackTime > 3 {
                throw RecorderError.message("Core Audio stopped delivering callbacks. The captured portion was preserved.")
            }
            try pipeline.drain(ring)
            if now - lastUI >= 0.1 { lastUI = now; onEvent(.levels(pipeline.snapshot)) }
            if preview && now - startTime >= 60 { finish(reason: nil) }
        } catch { finish(reason: error.localizedDescription) }
    }
    private func finish(reason: String?) {
        guard active else { return }
        active = false
        controlLock.lock(); controlRing = nil; controlLock.unlock()
        timer?.cancel(); timer = nil
        onEvent(.finalizing)
        let stopErrors = capture?.stopIO() ?? []
        var failure = reason
        if !stopErrors.isEmpty { failure = ([reason].compactMap { $0 } + stopErrors).joined(separator: "\n") }
        if let ring = capture?.ring {
            do { try pipeline?.drain(ring) } catch { failure = failure ?? error.localizedDescription }
        }
        if let failure { store?.recordError(failure, droppedFrames: pipeline?.snapshot.droppedFrames ?? 0) }
        var checkpointSucceeded = true
        do { try pipeline?.finish() }
        catch { checkpointSucceeded = false; failure = failure ?? error.localizedDescription; store?.recordError(error.localizedDescription) }
        let cleanupErrors = capture?.close() ?? []
        if !cleanupErrors.isEmpty {
            failure = ([failure].compactMap { $0 } + cleanupErrors + ["Quit Afterword if the audio privacy indicator remains active."]).joined(separator: "\n")
            store?.recordError(failure!)
        }
        capture = nil; pipeline = nil
        var file: URL?
        var recovery = store?.directory
        if let store, store.manifest.totalFrames == 0, (try? store.discardIfEmpty()) == true { recovery = nil }
        if checkpointSucceeded, let store, store.manifest.totalFrames > 0 {
            do { file = try Exporter.export(store); recovery = store.manifest.retainRecoveryFiles == true ? store.directory : nil }
            catch { failure = "\(failure.map { $0 + "\n" } ?? "")\(error.localizedDescription)" }
        }
        self.store = nil
        onEvent(.finished(file: file, reason: failure, recovery: recovery, needsPermission: permissionFailure))
    }
    public func recover(_ candidate: RecoveryCandidate, destination: URL?) {
        queue.async { [self] in
            guard !active else { return }
            active = true; onEvent(.finalizing)
            do {
                let store = try Recovery.load(directory: candidate.directory)
                if let destination { try store.setDestination(destination) }
                let file = try Exporter.export(store)
                active = false
                onEvent(.finished(file: file, reason: store.manifest.errors.last, recovery: store.manifest.retainRecoveryFiles == true ? store.directory : nil, needsPermission: false))
            } catch { active = false; onEvent(.finished(file: nil, reason: error.localizedDescription, recovery: candidate.directory, needsPermission: false)) }
        }
    }
}
