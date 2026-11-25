import Foundation

/// Wispr's notification eligibility (main process `Nt`): each card has a most-times-shown and a
/// minimum gap between showings, kept per card.
enum FlowNoticeRules {
    static func eligible(_ id: String, maxTimes: Int = .max, minInterval: TimeInterval = 0,
                         defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        let count = defaults.integer(forKey: "flow.notice.\(id).count")
        guard count < maxTimes else { return false }
        let last = defaults.double(forKey: "flow.notice.\(id).last")
        return last == 0 || now.timeIntervalSince1970 - last > minInterval
    }

    static func markShown(_ id: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(defaults.integer(forKey: "flow.notice.\(id).count") + 1, forKey: "flow.notice.\(id).count")
        defaults.set(now.timeIntervalSince1970, forKey: "flow.notice.\(id).last")
    }

    /// Words dictated so far, Wispr history included (Wispr counts its own lifetime words).
    static func lifetimeWords(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: "voice.totalWords") + defaults.integer(forKey: "flow.importedWisprWords")
    }

    // MARK: Cards

    /// Wispr `Debounce`: a single tap of the shortcut. Alert, 6 s, at most every 12 hours,
    /// and only while the user has dictated 50,000 words or fewer.
    static func debounce(shortcut: String, defaults: UserDefaults = .standard, now: Date = Date()) -> FlowPillNotice? {
        guard lifetimeWords(defaults: defaults) <= 50_000,
              eligible("debounce", minInterval: 12 * 3600, defaults: defaults, now: now) else { return nil }
        markShown("debounce", defaults: defaults, now: now)
        return FlowPillNotice(kind: .general, message: "Hold down \(shortcut) while speaking, release to see text.",
                              title: "Don't tap. Hold down \(shortcut).", status: .alert, timeout: 6)
    }

    /// Wispr `SuggestPOPO`: after holding the shortcut for a minute or more. Info with a Tip
    /// badge, 6 s, at most three times and an hour apart.
    static func suggestHandsFree(shortcut: String, defaults: UserDefaults = .standard, now: Date = Date()) -> FlowPillNotice? {
        guard eligible("suggestPOPO", maxTimes: 3, minInterval: 3600, defaults: defaults, now: now) else { return nil }
        markShown("suggestPOPO", defaults: defaults, now: now)
        return FlowPillNotice(kind: .general, message: "Double tap \(shortcut) to start hands-free mode.",
                              title: "Switch to hands-free mode", status: .info, timeout: 6, badge: "Tip")
    }

    /// Wispr `TranscriptCurrentlyProcessing`: dictating while the last one is still processing.
    static func currentlyProcessing() -> FlowPillNotice {
        FlowPillNotice(kind: .general, message: "If you'd like to cancel, press Esc or click below.",
                       title: "Flow was processing your last transcript", status: .alert, timeout: 6,
                       actions: [.init(title: "Cancel", notification: "")])
    }

    /// Wispr `TranscriptCancelledDetailed`: the first three cancels, at most once a day.
    static func cancelledDetailed(defaults: UserDefaults = .standard, now: Date = Date()) -> FlowPillNotice? {
        guard eligible("cancelledDetailed", maxTimes: 3, minInterval: 24 * 3600, defaults: defaults, now: now) else { return nil }
        markShown("cancelledDetailed", defaults: defaults, now: now)
        return FlowPillNotice(kind: .cancelled, message: "We noticed you cancelled your transcription",
                              title: "You can recover your cancelled transcript", status: .alert, timeout: 8)
    }

    /// "Don't show again" on Wispr's ProcessingDelayNotification.
    static let processingDelayOffKey = "flow.processingDelayNoticeOff"
}
