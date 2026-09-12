import Foundation

/// Whichever of two answers arrives first, without waiting for the other.
///
/// **`withTaskGroup` cannot express this, and two places in this app assumed
/// it could.** A task group does not return until every child has completed,
/// so `group.cancelAll()` after `group.next()` bounds nothing when the losing
/// child is not cancellation-aware — and `await someTask.value` on a
/// `Task<T, Never>` is exactly that: non-throwing, never observing its own
/// cancellation, and unstructured so it never inherited the group's.
///
/// Measured with a 10 s worker against a 2 s watchdog:
///
///     group.next() returned at 2.07s   <- the watchdog fired
///     cancelAll() called at 2.07s
///     withTaskGroup RETURNED at 10.23s <- everything after it waited
///
/// So the refresh watchdog could not clear `isRefreshing` until the hang it
/// existed to abandon had ended on its own, and the per-candidate picture
/// deadline ended when `timeoutIntervalForResource` ended, not when it said.
///
/// This resumes on the first answer and lets the loser run on unwatched. The
/// loser is not free — it still holds whatever it holds until its own resource
/// ceiling ends it — but nothing waits for it, which is the property both call
/// sites actually wanted.
enum FirstAnswer {

    /// `work`, or `fallback` after `seconds`, whichever answers first.
    static func of<T: Sendable>(_ seconds: TimeInterval,
                                fallback: T,
                                work: @escaping @Sendable () async -> T) async -> T {
        let box = Box<T>()
        return await withCheckedContinuation { continuation in
            box.install(continuation)
            Task { let value = await work(); box.resume(value) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
                box.resume(fallback)
            }
        }
    }

    /// Resumes a continuation exactly once, from either task.
    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        private var pending: T?

        func install(_ continuation: CheckedContinuation<T, Never>) {
            lock.lock()
            // A racer that answered before the continuation was installed.
            if let pending {
                lock.unlock()
                continuation.resume(returning: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ value: T) {
            lock.lock()
            guard let waiting = continuation else {
                if pending == nil { pending = value }
                lock.unlock()
                return
            }
            continuation = nil
            lock.unlock()
            waiting.resume(returning: value)
        }
    }
}
