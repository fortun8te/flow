// Flow: one operation at a time for the text-changing work.
//
// Dictation and Opt+1 polish both read the focused field and write into it. They must never run
// together: a polish that starts while a dictation is recording or transcribing would share the
// cancel state and the pill would hide it. This file holds the pure admission rule so it can be
// tested without the app running. VoiceApp asks it before starting either operation.

import Foundation

enum OperationAdmission {
    enum Verdict: Equatable {
        case admitted
        /// A polish is running; a new dictation waits for it.
        case refusedBecausePolishing
        /// A dictation is recording or being transcribed; a new polish waits for it.
        case refusedBecauseDictating
        /// Another polish is still running; a second one would share its field.
        case refusedBecauseAlreadyPolishing
    }

    /// Decides whether a new Opt+1 polish may start.
    static func forPolish(isRecording: Bool, pendingStart: Bool, isTranscribing: Bool, isPolishing: Bool) -> Verdict {
        if isRecording || pendingStart || isTranscribing { return .refusedBecauseDictating }
        // Overlapping polishes are refused too; the running one owns the field.
        if isPolishing { return .refusedBecauseAlreadyPolishing }
        return .admitted
    }

    /// Decides whether a new dictation may start.
    static func forDictation(isPolishing: Bool) -> Verdict {
        isPolishing ? .refusedBecausePolishing : .admitted
    }

    /// The short plain notice for a refused start. Nil when admitted.
    static func notice(for verdict: Verdict) -> String? {
        switch verdict {
        case .admitted: return nil
        case .refusedBecausePolishing: return "Flow is polishing your text. Dictate when it's done."
        case .refusedBecauseDictating: return "Finish dictating first, then polish."
        case .refusedBecauseAlreadyPolishing: return "Flow is still polishing. Wait for it to finish."
        }
    }
}

/// Tracks which Opt+1 operation is current. Cancelling or starting a new one makes every older
/// operation stale, so a late callback from it cannot touch shared state (sol/01 finding 1).
struct OperationGate: Equatable {
    private(set) var current: UUID?

    /// Starts a new operation and makes it the only current one.
    mutating func begin(_ id: UUID = UUID()) -> UUID {
        current = id
        return id
    }

    /// True while `id` is still the current operation.
    func isCurrent(_ id: UUID) -> Bool { current == id }

    /// Ends `id` only if it is still current. Returns true when it was.
    @discardableResult
    mutating func end(_ id: UUID) -> Bool {
        guard current == id else { return false }
        current = nil
        return true
    }

    /// Stops whatever is current (used by Escape).
    mutating func cancel() { current = nil }
}
