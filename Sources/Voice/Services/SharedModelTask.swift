import Foundation

/// One model load with independently cancellable waiters. Cancelling a request
/// releases its wait immediately without cancelling preparation for the next
/// request. Only the owner calls `cancel()` when it replaces or stops the load.
final class SharedModelTask<Value: Sendable>: @unchecked Sendable {
    let id = UUID()
    private let state: State
    private let task: Task<Void, Never>

    init(priority: TaskPriority = .userInitiated,
         onCompletion: @escaping @Sendable () -> Void = {},
         operation: @escaping @Sendable () async throws -> Value) {
        let state = State()
        self.state = state
        // Weight mapping and tokenizer setup must not inherit MainActor.
        task = Task.detached(priority: priority) {
            // The underlying work owns its lease until it actually ends, even
            // if cancellation already released every waiter. This also runs
            // when cancellation happens before operation starts.
            defer { onCompletion() }
            do {
                try Task.checkCancellation()
                state.finish(.success(try await operation()))
            }
            catch { state.finish(.failure(error)) }
        }
    }

    var value: Value {
        get async throws {
            try Task.checkCancellation()
            let id = UUID()
            let (stream, continuation) = AsyncStream<Result<Value, Error>>.makeStream(bufferingPolicy: .bufferingNewest(1))
            continuation.onTermination = { [state] _ in state.remove(id) }
            state.add(id, continuation)
            defer { continuation.finish() }
            var iterator = stream.makeAsyncIterator()
            // AsyncStream wakes this waiter on cancellation even if loading
            // weights is inside an operation which cannot yet be interrupted.
            guard let result = await iterator.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return try result.get()
        }
    }

    func cancel() {
        // Publish cancellation first: an uncooperative loader cannot overwrite
        // it later or keep the owner's callers suspended.
        state.finish(.failure(CancellationError()))
        task.cancel()
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        private var waiters: [UUID: AsyncStream<Result<Value, Error>>.Continuation] = [:]

        func add(_ id: UUID, _ continuation: AsyncStream<Result<Value, Error>>.Continuation) {
            lock.lock()
            let result = self.result
            if result == nil { waiters[id] = continuation }
            lock.unlock()
            if let result {
                continuation.yield(result)
                continuation.finish()
            }
        }

        func remove(_ id: UUID) {
            lock.lock()
            waiters[id] = nil
            lock.unlock()
        }

        func finish(_ result: Result<Value, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuations = Array(waiters.values)
            waiters.removeAll()
            lock.unlock()
            // Resuming a waiter can run its termination callback immediately.
            // Never yield/finish while holding the lock.
            for continuation in continuations {
                continuation.yield(result)
                continuation.finish()
            }
        }
    }
}
