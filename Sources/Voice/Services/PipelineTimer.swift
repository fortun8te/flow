import Foundation

/// Durations and latency budgets must not change when the wall clock is corrected.
struct PipelineTimer: Sendable {
    let started: ContinuousClock.Instant

    init(started: ContinuousClock.Instant = .now) { self.started = started }

    func seconds(at now: ContinuousClock.Instant = .now) -> Double {
        let elapsed = started.duration(to: now).components
        return max(0, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    func milliseconds(at now: ContinuousClock.Instant = .now) -> Int {
        Int(seconds(at: now) * 1_000)
    }
}
