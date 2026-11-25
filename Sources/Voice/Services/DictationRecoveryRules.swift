// Flow: small pure rules for recovery and empty-transcript messages.
// Kept free of UI and storage so they can be unit-tested.

import Foundation

enum DictationRecoveryRules {
    /// Shortest meeting audio that can hold speech. Stubs shorter than this
    /// (a start/stop with no real capture) can never be recovered, so
    /// auto-recovery must not retry them on every launch.
    static let minimumRecoverableDuration: TimeInterval = 2.0

    /// True when an empty meeting has audio that is worth re-transcribing.
    static func needsAutoRetranscribe(_ meeting: Meeting, audioFileExists: Bool) -> Bool {
        guard meeting.kind == .meeting,
              meeting.segments.isEmpty,
              meeting.audioFilePath != nil,
              audioFileExists,
              meeting.duration >= minimumRecoverableDuration
        else { return false }
        return true
    }

    /// Shown when a capture produced no transcript. Says what to check.
    static let emptyTranscriptMessage =
        "Flow didn't hear any speech. Check your microphone in Sound settings."

    /// The same notice, naming the microphone that recorded the silence (22 Nov 2026: 11 of 43 runs ended empty).
    static func emptyTranscriptMessage(mic: String?) -> String {
        guard let mic = mic?.trimmingCharacters(in: .whitespacesAndNewlines), !mic.isEmpty else {
            return emptyTranscriptMessage
        }
        return "Flow didn't hear any speech on \(mic). Check that microphone in Sound settings."
    }
}
