import AppKit
import os

/// Subtle haptic taps for the voice experience (pill, recording, paste, notices, Opt+1). macOS plays
/// them only on a Force Touch trackpad, so a mouse or Magic Mouse pointer gets nothing.
/// Off when `voice.haptics` is false (default on). Companion writes that key in Settings > Voice > Pill,
/// and it is read on every tap, so a change applies without a restart.
enum PillHaptics {
    static let key = "voice.haptics"

    /// Taps closer together than this are dropped, so a burst of events reads as one tap.
    static let minimumInterval: TimeInterval = 0.150
    /// Gap between the two taps of the hands-free lock.
    static let lockGap: TimeInterval = 0.070

    /// Where the gate reads the setting. Tests point this at a throwaway suite.
    static var defaults: UserDefaults = .standard
    /// Seconds since boot. Tests replace it with a fake clock.
    static var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Performs the tap. Tests replace it to capture taps instead of playing them.
    static var performer: (NSHapticFeedbackManager.FeedbackPattern) -> Void = { pattern in
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
    static var limiter = RateLimiter()
    /// Visible with: log show --predicate 'subsystem == "voice" AND category == "haptics"' --last 5m
    private static let logger = Logger(subsystem: "voice", category: "haptics")

    /// The on/off gate. A missing key means on.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    /// Lets one tap through per `minimumInterval`. Pure, so the spacing can be tested with a fake clock.
    struct RateLimiter {
        var minimumInterval: TimeInterval = PillHaptics.minimumInterval
        private(set) var lastTap: TimeInterval?

        mutating func allow(at time: TimeInterval) -> Bool {
            if let lastTap, time - lastTap < minimumInterval { return false }
            lastTap = time
            return true
        }
    }

    /// Recording started (the key-down was accepted).
    static func start() { tap(.levelChange) }

    /// Recording stopped, or the dictation was inserted.
    static func done() { tap(.generic) }

    /// Hands-free lock (double tap): two alignment taps about 70 ms apart. The second tap is
    /// scheduled directly, not through the rate limit, because it lands inside the 150 ms window.
    static func lock() {
        guard isEnabled(in: defaults), limiter.allow(at: clock()) else { return }
        logger.info("haptic fired: lock")
        performer(.alignment)
        DispatchQueue.main.asyncAfter(deadline: .now() + lockGap) {
            guard isEnabled(in: defaults) else { return }
            performer(.alignment)
        }
    }

    /// A pill button was pressed: cancel, finish or stop.
    static func press() { tap(.alignment) }

    /// The pill snapped to another dock while being dragged.
    static func dockSnap() { tap(.alignment) }

    /// The paste was read back in the field: the dictation landed.
    static func pasteConfirmed() { tap(.generic) }

    /// An error notice: mic silent or a failed paste.
    static func error() { tap(.levelChange) }

    /// An Opt+1 polish was applied.
    static func polishFinished() { tap(.alignment) }

    /// A paste was not confirmed, so the text is only on the clipboard. Reported as an error.
    static func pasteNotConfirmed() { error() }

    private static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard isEnabled(in: defaults), limiter.allow(at: clock()) else { return }
        logger.info("haptic fired: \(String(describing: pattern), privacy: .public)")
        performer(pattern)
    }
}
