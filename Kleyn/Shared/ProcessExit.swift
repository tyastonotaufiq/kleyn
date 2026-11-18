//
//  ProcessExit.swift
//  Kleyn
//

import Foundation

/// Waits for a `Process` to end without `waitUntilExit()`.
///
/// `waitUntilExit()` waits by running a run loop on the calling thread. On the threads Swift
/// concurrency runs tasks on, it can miss the end of a process that has already exited, and
/// wait forever: ADB Explorer's Check Now hung that way. This uses the process's
/// `terminationHandler` instead. Create it, then start the process, then await `wait()`.
nonisolated final class ProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// Sets `process`'s termination handler. Call it before `process.run()`, so an end can't be missed.
    init(_ process: Process) {
        process.terminationHandler = { [self] _ in end() }
    }

    /// Returns once the process has ended, at once if it already has.
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if ended {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private func end() {
        lock.lock()
        ended = true
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume()
    }
}
