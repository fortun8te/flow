import Foundation

/// A cancelled waiter does not release an operation that may still be using a model.
/// The underlying operation's completion callback owns release, using its exact token.
final class ModelWorkLease: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: UUID?

    var isBusy: Bool {
        lock.withLock { owner != nil }
    }

    func claim() -> UUID? {
        lock.withLock {
            guard owner == nil else { return nil }
            let token = UUID()
            owner = token
            return token
        }
    }

    func release(_ token: UUID) {
        lock.withLock {
            if owner == token { owner = nil }
        }
    }
}
