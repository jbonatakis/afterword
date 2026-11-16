import Foundation
import CoreServices

/// A single recursive stream handles atomic replacements from already-connected
/// MCP helpers without opening a file descriptor for every recording.
final class LibrarySummaryMonitor {
    private final class Context {
        let changed: () -> Void
        init(changed: @escaping () -> Void) { self.changed = changed }
    }
    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private let changed: () -> Void

    init(changed: @escaping () -> Void) { self.changed = changed }
    deinit { stop() }

    /// Called on the main thread; event callbacks use that same queue.
    func watch(_ roots: [URL]) {
        let paths = Array(Set(roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })).sorted()
        guard paths != self.paths || stream == nil else { return }
        stop()
        guard !paths.isEmpty else { return }
        let box = Context(changed: changed)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Context>.fromOpaque(info).retain()
                return info
            },
            release: { info in if let info { Unmanaged<Context>.fromOpaque(info).release() } },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        let created = withExtendedLifetime(box) {
            FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
                guard let info else { return }
                let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
                let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
                for index in 0..<count {
                    let name = (paths[index] as NSString).lastPathComponent
                    if flags[index] & rescan != 0 || name == "Summary.json" || name.hasSuffix(".summary.json") {
                        Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().changed()
                        break
                    }
                }
            }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
        }
        guard let created else { return }
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created)
            return
        }
        stream = created; self.paths = paths
    }
    func stop() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
        stream = nil; paths = []
    }
}
