import Foundation

/// Main-thread work needed by EPUB background rendering, including attachment
/// construction and a host's view-based formula typesetter.
///
/// A synchronous print callback must use ``wait(for:)`` instead of blocking on
/// its workers: they may need ``sync(_:)`` before they can finish. Both routes
/// service the same queue, including jobs submitted before the wait began.
/// Parsing, archive access, styling and pagination belong outside these jobs.
public enum EPUBMainThreadRelay {
    private static let condition = NSCondition()
    // Guarded by condition; executed only on main, outside the lock.
    nonisolated(unsafe) private static var jobs: [@MainActor () -> Void] = []

    /// Runs a bounded piece of EPUB main-thread work and returns its result.
    /// Main callers run inline. Background callers hand the result back only
    /// after the main job completes; they must not hold a lock the job needs.
    /// Capture immutable or synchronized inputs. A newly created cell is handed
    /// exclusively to the caller; the job must not retain it for later mutation.
    ///
    /// Normal servicing runs one job per main-queue callback. A synchronous
    /// host wait must use ``wait(for:)`` so those same jobs remain reachable.
    public static func sync<Result>(_ work: @escaping @MainActor () -> Result) -> Result {
        let request = Request(work)
        if Thread.isMainThread {
            MainActor.assumeIsolated { request.run() }
        } else {
            condition.lock()
            jobs.append { request.run() }
            condition.signal()
            condition.unlock()
            // Never use main.sync here: a print wait can start after enqueueing
            // but before this callback runs, and must be able to take the job.
            DispatchQueue.main.async { runNext() }
            request.done.wait()
        }
        return request.result!
    }

    /// Runs `work` in the background while the calling main thread services
    /// EPUB constructor/typesetter jobs until it finishes. No general run-loop
    /// pumping or unrelated UI callbacks occur during this synchronous wait.
    /// Use only at a synchronous host boundary such as print pagination.
    @MainActor public static func wait(for work: @escaping @Sendable () -> Void) {
        let completion = Completion()
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            condition.lock()
            completion.isFinished = true
            condition.signal()
            condition.unlock()
        }
        while true {
            condition.lock()
            while jobs.isEmpty && !completion.isFinished { condition.wait() }
            if completion.isFinished {
                condition.unlock()
                return
            }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }

    @MainActor private static func runNext() {
        condition.lock()
        let job = jobs.isEmpty ? nil : jobs.removeFirst()
        condition.unlock()
        job?()
    }

    // The worker reads only after done; the main thread alone writes result.
    private final class Request<Result>: @unchecked Sendable {
        let work: @MainActor () -> Result
        let done = DispatchSemaphore(value: 0)
        var result: Result?
        init(_ work: @escaping @MainActor () -> Result) { self.work = work }
        @MainActor func run() {
            result = work()
            done.signal()
        }
    }

    // Accessed only while condition is locked.
    private final class Completion: @unchecked Sendable {
        var isFinished = false
    }
}
