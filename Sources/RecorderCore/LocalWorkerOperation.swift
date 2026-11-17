import Foundation

/// Runs blocking local inference off the UI thread. Only the process owned by this operation is cancelled.
final class LocalWorkerOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool { lock.withLock { cancelled } }
    func checkCancellation() throws { if isCancelled { throw CancellationError() } }

    func cancel() {
        lock.lock()
        cancelled = true
        let child = process
        if let child, child.isRunning { child.terminate() }
        lock.unlock()
        if let child {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    if self.process === child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    func start(_ child: Process) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try child.run()
            process = child
        }
    }

    func finish(_ child: Process) {
        lock.withLock { if process === child { process = nil } }
    }

    func publish<T>(_ write: () throws -> T) throws -> T {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            return try write()
        }
    }

    func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try self.checkCancellation(); return try work() })
                }
            }
        } onCancel: { self.cancel() }
    }
}
