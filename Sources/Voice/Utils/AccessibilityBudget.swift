// AccessibilityBudget.swift
// ============================================================
// Bounds the Accessibility (AX) calls that the dictation and Opt+1 paths make,
// so one slow target app can never hold the hotkey or the paste for long.
//
// How it works
//   * Every element we query gets a messaging timeout first
//     (AXUIElementSetMessagingTimeout). The process default is also set once at
//     launch, for elements we do not bind one by one.
//   * A call that runs past the timeout returns kAXErrorCannotComplete. That is
//     reported as `.timedOut`, and callers take their existing "no context"
//     fallback. A timeout is never a reason to retry or to paste again.
//   * The first timeout from each app is logged. Later ones are not, so a hung
//     app cannot flood the log.
//
// Pure decision logic lives here too, so it can be unit tested without a
// running target app.
// ============================================================

import Foundation
import ApplicationServices

enum AccessibilityBudget {
    /// Longest time one AX call may wait on a target app, in seconds.
    /// Normal AX answers take milliseconds. A slow first answer from an
    /// Electron app can exceed this once; that read then falls back.
    static let messagingTimeout: Float = 0.6

    /// What one AX read means to a caller.
    enum ReadOutcome: Equatable {
        case value      // the app answered with a value
        case absent     // the app answered, but there is no usable value
        case timedOut   // the app did not answer within the budget
    }

    /// Pure mapping from an AX result to what the caller should do.
    static func outcome(for error: AXError, hasValue: Bool) -> ReadOutcome {
        if error == .cannotComplete { return .timedOut }
        guard error == .success, hasValue else { return .absent }
        return .value
    }

    /// Sets the budget on one element. Returns the same element for chaining.
    @discardableResult
    static func bind(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Sets the process-wide default, covering elements not bound one by one.
    /// Call once at launch.
    static func installProcessDefault() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    /// Reads one attribute under the budget. Returns nil for a timeout or for
    /// any answer without a value, so callers keep their existing nil handling.
    /// A timeout is logged once per app.
    static func copyAttribute(_ element: AXUIElement, _ attribute: String, app: String? = nil) -> CFTypeRef? {
        bind(element)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch outcome(for: error, hasValue: value != nil) {
        case .value:
            return value
        case .absent:
            return nil
        case .timedOut:
            timeoutLog.noteTimeout(app: app ?? "unknown app", attribute: attribute)
            return nil
        }
    }

    private static let timeoutLog = TimeoutLogGate()
}

/// Remembers which apps have already had a timeout logged. The lock makes the
/// first-time check safe from any thread that reads AX.
final class TimeoutLogGate {
    private var loggedApps = Set<String>()
    private let lock = NSLock()

    /// Pure rule: true only for the first call per app.
    func shouldLog(app: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loggedApps.insert(app).inserted
    }

    /// Logs the first timeout from an app. Returns true when it logged.
    @discardableResult
    func noteTimeout(app: String, attribute: String) -> Bool {
        guard shouldLog(app: app) else { return false }
        print("[VOICE-AX] \(attribute) timed out in \(app) after \(AccessibilityBudget.messagingTimeout)s; using fallback. Later timeouts from this app are not logged.")
        return true
    }
}
