import Foundation

/// Shared by manual dictionary edits and imported-vocabulary reconciliation.
/// UserDefaults is thread safe, but a complete read/merge/write is not atomic.
enum VocabularyPreferenceTransaction {
    private static let lock = NSRecursiveLock()

    static func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }
}
