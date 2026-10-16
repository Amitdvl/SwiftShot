import Foundation

/// Bounds the UI wait without draining an SDK task which may ignore cancellation.
/// The original task retains its capture memory reservation until it really ends.
enum CaptureRequestDeadline {
    static func value<Value: Sendable>(of task: Task<Value, Error>, timeout: Duration) async throws -> Value {
        let completion = CaptureDeadlineCompletion<Value>()
        // Transport errors as values to preserve the original SDK NSError.
        let result: Result<Value, any Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                Task { _ = completion.finish(await task.result) }
                let timer = Task {
                    do {
                        try await Task.sleep(for: timeout)
                        _ = completion.finish(.failure(CaptureError.failed(
                            "Screen capture took too long. Try capturing again.")), cancelling: task)
                    } catch { /* Successful acquisition or cancellation stopped the timer. */ }
                }
                completion.installTimer(timer)
            }
        } onCancel: {
            _ = completion.finish(.failure(CancellationError()), cancelling: task)
        }
        return try result.get()
    }
}

/// Only the first result owns the continuation. Callback observation, the timer,
/// and caller cancellation may run on different executors or precede installation.
private final class CaptureDeadlineCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var pending: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Result<Value, any Error>, Never>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Result<Value, any Error>, Never>) {
        let result: Result<Value, any Error>? = lock.withLock {
            if let result = pending {
                pending = nil
                return result
            }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(returning: result) }
    }

    func installTimer(_ timer: Task<Void, Never>) {
        let cancel = lock.withLock {
            if finished { return true }
            self.timer = timer
            return false
        }
        if cancel { timer.cancel() }
    }

    @discardableResult
    func finish(_ result: Result<Value, any Error>, cancelling task: Task<Value, Error>? = nil) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        // Choose the winner before cancellation can deliver an SDK error, and
        // request cancellation before publishing timeout/cancellation to callers.
        // Installation may occur during this step; publication takes its handle.
        task?.cancel()
        timer?.cancel()
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        lock.unlock()
        continuation?.resume(returning: result)
        return true
    }
}
