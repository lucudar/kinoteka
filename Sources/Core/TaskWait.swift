import Foundation

enum TaskWait {
    /// The result of the task when it ends within `seconds`, otherwise nil. The task is not
    /// cancelled and keeps running: awaiting `Task.value` alone cannot be given up early.
    static func result<Success: Sendable>(of task: Task<Success, Error>, within seconds: TimeInterval) async -> Result<Success, Error>? {
        let once = OnceContinuation<Result<Success, Error>?>()
        let nanoseconds = UInt64(max(0, min(seconds, 3_600)) * 1_000_000_000)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<Success, Error>?, Never>) in
            once.set(continuation)
            let timer = Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                once.resume(nil)
            }
            Task {
                let value: Result<Success, Error>
                do {
                    value = .success(try await task.value)
                } catch {
                    value = .failure(error)
                }
                timer.cancel()
                once.resume(value)
            }
        }
    }
}

extension TaskWait {
    /// The first of the tasks to succeed, with its index; when all fail, the error of the last one.
    /// The other tasks are not cancelled.
    static func firstSuccess<Success: Sendable>(_ tasks: [Task<Success, Error>]) async -> (index: Int, result: Result<Success, Error>) {
        guard !tasks.isEmpty else { return (-1, .failure(CancellationError())) }
        let once = OnceContinuation<(index: Int, result: Result<Success, Error>)>()
        let failures = Countdown(tasks.count)
        return await withCheckedContinuation { (continuation: CheckedContinuation<(index: Int, result: Result<Success, Error>), Never>) in
            once.set(continuation)
            for (index, task) in tasks.enumerated() {
                Task {
                    do {
                        let value = try await task.value
                        once.resume((index, .success(value)))
                    } catch {
                        if failures.finishOne() { once.resume((index, .failure(error))) }
                    }
                }
            }
        }
    }
}

/// Counts down from a number; true for the call that reaches zero.
final class Countdown: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int

    init(_ count: Int) {
        left = count
    }

    func finishOne() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        left -= 1
        return left == 0
    }
}

/// Resumes a continuation once, with the first value given.
final class OnceContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    func set(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
