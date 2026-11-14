import Foundation

/// Runs `operation` and returns its result, or nil once `seconds` pass without one. On a timeout the
/// operation is cancelled but not waited for: a recogniser that never answers can't hold us up.
/// Not a task group, which would wait for every child, the hung one too.
public func withDeadline<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let once = ResumeOnce<T?>()
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    let result = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        once.set(continuation)
        work = Task { once.resume(await operation()) }
        timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            once.resume(nil)
        }
    }
    work?.cancel()
    timer?.cancel()
    return result
}

/// A continuation the first of two racers resumes; the other's resume is ignored.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func set(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
