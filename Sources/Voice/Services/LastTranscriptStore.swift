// VOICE — Last finished dictation, kept in memory only.
// ============================================================
// Backs Control+Command+V ("paste last transcript"). Owned by AppDelegate and
// updated at the single place where a dictation's final text is decided, so
// the value is the text that was (or was meant to be) pasted. Not persisted:
// it is lost on quit, by design, to keep transcripts off disk here.
// ============================================================

import Foundation

struct LastTranscriptStore {
    /// The most recent non-empty final text. Empty or whitespace-only results never replace it.
    private(set) var text: String?

    mutating func remember(_ finalText: String) {
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = finalText
    }

    /// Pure decision: handle Control+Command+V only when there is text to paste
    /// and no recording is in progress. Otherwise the key must pass through.
    func shouldHandlePasteLast(isRecording: Bool) -> Bool {
        !isRecording && text != nil
    }
}
