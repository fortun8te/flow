// Flow — which Escape goes where.
// While Companion's screenshot selection is up, Escape belongs to the screenshot alone. Companion announces the overlay
// with a distributed notification; Flow's key monitors then skip Escape, so a dictation is not cancelled by it.
import Foundation

struct EscapeRouting: Equatable {
    static let notificationName = Notification.Name("app.pure.shotOverlay")
    /// A missed "ended" message must not silence Escape forever.
    static let maxOverlaySeconds: TimeInterval = 120
    /// The overlay closes on the same Escape press; the end message can beat the key event to Flow.
    static let graceSeconds: TimeInterval = 0.4

    private(set) var overlayStartedAt: Date?
    private(set) var overlayEndedAt: Date?

    mutating func overlayChanged(active: Bool, at now: Date = Date()) {
        if active { overlayStartedAt = now; overlayEndedAt = nil }
        else if overlayStartedAt != nil { overlayStartedAt = nil; overlayEndedAt = now }
    }

    /// True when Escape should go to dictation: no screenshot overlay is up or was up a moment ago.
    func dictationShouldHandleEscape(at now: Date = Date()) -> Bool {
        if let start = overlayStartedAt, now.timeIntervalSince(start) < Self.maxOverlaySeconds { return false }
        if let end = overlayEndedAt, now.timeIntervalSince(end) < Self.graceSeconds { return false }
        return true
    }

    // MARK: Live instance

    private static let lock = NSLock()
    nonisolated(unsafe) private static var live = EscapeRouting()
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    static func startObserving() {
        lock.lock(); defer { lock.unlock() }
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: notificationName, object: nil, queue: nil) { note in
            let active = (note.userInfo?["active"] as? Bool) ?? ((note.userInfo?["active"] as? NSNumber)?.boolValue ?? false)
            lock.lock(); live.overlayChanged(active: active); lock.unlock()
        }
    }

    static func liveDictationShouldHandleEscape() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return live.dictationShouldHandleEscape()
    }
}
