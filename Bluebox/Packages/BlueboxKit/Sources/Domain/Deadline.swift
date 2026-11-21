import Foundation
import Synchronization

/// Waiting with a time limit, for screens that would rather go on without an
/// answer than hang on a slow server.
public enum Deadline {
    /// What `work` returns, or nil once `seconds` pass. Unlike a task group it
    /// doesn't wait for work that ignores cancellation: past the limit that
    /// work goes on in the background (filling whatever cache it fills, so the
    /// next look has the answer at once) and its answer is dropped. Cancelling
    /// the caller cancels the work and returns nil at once.
    public static func value<T: Sendable>(within seconds: TimeInterval,
                                          _ work: @escaping @Sendable () async -> T?) async -> T? {
        let task = Task { await work() }
        let race = Race<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
                let timer = Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    race.finish(nil)
                }
                race.start(done, timer: timer)
                Task { race.finish(await task.value) }
            }
        } onCancel: {
            task.cancel()
            race.finish(nil)
        }
    }

    /// Whichever comes first, the answer, the limit or the caller's
    /// cancellation, resumes; the others are dropped. Cancellation can come
    /// before the continuation exists, so the result waits for it.
    private final class Race<T: Sendable>: Sendable {
        private struct State {
            var done: CheckedContinuation<T?, Never>?
            var timer: Task<Void, Never>?
            var result: T??
        }
        private let state = Mutex(State())

        func start(_ done: CheckedContinuation<T?, Never>, timer: Task<Void, Never>) {
            let early: T?? = state.withLock { s in
                if let result = s.result { return .some(result) }
                s.done = done
                s.timer = timer
                return .none
            }
            if let early {
                timer.cancel()
                done.resume(returning: early)
            }
        }

        func finish(_ value: T?) {
            let taken = state.withLock { s -> (CheckedContinuation<T?, Never>?, Task<Void, Never>?)? in
                guard s.result == nil else { return nil }
                s.result = .some(value)
                defer { s.done = nil; s.timer = nil }
                return (s.done, s.timer)
            }
            guard let (done, timer) = taken else { return }
            timer?.cancel()
            done?.resume(returning: value)
        }
    }
}
