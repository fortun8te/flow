import Foundation

/// One optional acoustic-rescoring allowance across all windows of a transcription.
/// New words can grow the allowance to its cap; elapsed work is never refunded.
final class AcousticRescoreBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let baseSeconds: Double
    private let secondsPerWord: Double
    private let maximumSeconds: Double
    private var words: Double = 0
    private var consumed: Double = 0

    init(baseSeconds: Double, secondsPerWord: Double, maximumSeconds: Double) {
        let valid = baseSeconds.isFinite && secondsPerWord.isFinite && maximumSeconds.isFinite
            && baseSeconds >= 0 && secondsPerWord >= 0 && maximumSeconds >= baseSeconds
        self.baseSeconds = valid ? baseSeconds : 0
        self.secondsPerWord = valid ? secondsPerWord : 0
        self.maximumSeconds = valid ? maximumSeconds : 0
    }

    func remainingSeconds(addingWords count: Int) -> Double {
        lock.withLock {
            words += Double(max(0, count))
            let allowance = min(maximumSeconds, baseSeconds + secondsPerWord * words)
            return max(0, allowance - consumed)
        }
    }

    func consume(seconds: Double) {
        lock.withLock {
            guard seconds.isFinite, seconds >= 0 else { consumed = maximumSeconds; return }
            consumed = min(maximumSeconds, consumed + seconds)
        }
    }

    /// A timed-out native operation may still own the encoder. Do not schedule
    /// more optional work for this recording when later chunks add words.
    func exhaust() {
        lock.withLock { consumed = maximumSeconds }
    }
}
