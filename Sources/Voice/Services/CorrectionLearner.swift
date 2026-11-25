// CorrectionLearner.swift
//
// Wispr-Flow-style "learn from correction" dictionary.
//
// When VOICE auto-pastes a transcript and the user immediately fixes a
// misheard word right there in the text field (e.g. ASR wrote "Diatype" as
// "diatribe", and they retype it), we want to LEARN the corrected word so
// next time both the ASR vocabulary booster AND the LLM polisher recognize
// it — without the user ever opening a settings pane.
//
// HOW IT WORKS
//   1. After a successful auto-paste, VoiceApp hands us (pastedText, snapshot)
//      where `snapshot` captures the focused AX element at paste time.
//   2. We schedule a one-shot check ~5s later (cancellable). Any new paste
//      cancels the prior pending check, so rapid-fire dictation doesn't pile
//      up overlapping diffs.
//   3. On the check we re-read the element's current text via AX. We locate
//      the region where our pasted text landed and diff it token-by-token
//      against what's there now. Single-word SUBSTITUTIONS are the signal:
//      a token VOICE wrote was replaced by a different, plausible new term.
//   4. Plausible new terms get added to the boosted vocabulary (persisted,
//      feeds ASR boosting via UserDictionary → CombinedDictionary, and the
//      polish vocab via ProperNounVocabulary) and surfaced via a toast.
//
// 22 Nov 2026 (autodict): the evidence now goes to AutoDictionary, which keeps
// heard -> written with examples, counts and dates, and routes names, misspellings
// and misheard phrases to the right place. The read-back changed too: the field is
// read right after the verified paste, and only what changed inside the pasted text
// counts. The old alignment matched a short paste against earlier text in the same
// field and queued "Smaller", "empty", "start" and "pale" as corrections he never
// made. Opt+1 results he keeps are evidence; Opt+1 Undo is negative evidence.
//
// GUARDRAILS (AutoDictionary.classify + editedSpan): never crash on denied /
// stale AX, never learn when the field was cleared, skip common English
// words, punctuation, numbers, deletions, and already-known terms. At most a
// couple of words learned per correction.

import Foundation
import AppKit          // AXIsProcessTrusted, AX* accessibility APIs

@MainActor
final class CorrectionLearner {
    static let shared = CorrectionLearner()

    /// Fired (on the main actor) for each newly-learned word so the UI can
    /// show an "Added 'X'" pill. Set by VoiceApp.
    var onWordLearned: ((String) -> Void)?

    /// Read-backs after a paste: a quick fix, then a slower one. Each reads twice, a moment apart, and
    /// only a field that stopped changing counts (a half-typed word is not a correction).
    private let checkDelays: [TimeInterval] = [8, 30]
    private let settleDelay: TimeInterval = 1.5
    /// An Opt+1 result still in the field after this long, and not undone, counts as kept.
    private let keepDelay: TimeInterval = 30

    /// Max words to learn from a single correction — keeps a big rewrite from
    /// flooding the dictionary with one-off edits.
    private let maxWordsPerCorrection = 3

    private let paster = CursorPaster()
    private let dictionary: AutoDictionary

    private struct Pending {
        let pasted: String
        let snapshot: CursorPaster.PasteTargetSnapshot
        let dictationID: String?
        /// The field right after the paste, and where the paste sits in it (UTF-16).
        let baseline: String
        let pastedRange: NSRange
        var observed: Set<String> = []
    }
    private var pending: Pending?
    private var checkTask: Task<Void, Never>?
    private var keepTasks: [UUID: Task<Void, Never>] = [:]

    init(dictionary: AutoDictionary = .shared) {
        self.dictionary = dictionary
    }

    // MARK: - Public entry point

    /// Record a freshly-pasted transcript + its target element, and schedule
    /// delayed correction checks. Cancels any prior pending check.
    func track(pastedText: String, snapshot: CursorPaster.PasteTargetSnapshot, dictationID: String? = nil) {
        // Only meaningful when we can actually re-read the field later.
        guard AXIsProcessTrusted(), snapshot.focusedElement != nil else { return }
        let trimmed = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return }
        checkTask?.cancel()
        pending = nil
        // The paste is verified, so the field now holds it: this is the baseline every edit is read against.
        guard let baseline = paster.currentText(of: snapshot), baseline.utf16.count <= 20_000 else { return }
        let range = (baseline as NSString).range(of: trimmed, options: .backwards)
        guard range.location != NSNotFound else { return }
        pending = Pending(pasted: pastedText, snapshot: snapshot, dictationID: dictationID,
                          baseline: baseline, pastedRange: range)

        let delays = checkDelays
        let settle = settleDelay
        checkTask = Task { @MainActor [weak self] in
            var waited: TimeInterval = 0
            for delay in delays {
                try? await Task.sleep(nanoseconds: UInt64((delay - waited) * 1_000_000_000))
                waited = delay
                guard !Task.isCancelled, let self else { return }
                guard let first = self.readField() else { return }
                try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
                waited += settle
                guard !Task.isCancelled else { return }
                guard let second = self.readField(), second == first else { continue }
                self.runCheck(current: second)
            }
        }
    }

    /// Opt+1 replaced a selection and the field shows it. Kept for `keepDelay` without an Undo, it counts.
    func trackPolish(diffID: UUID, original: String, polished: String, target: CursorPaster.PasteTargetSnapshot) {
        keepTasks[diffID]?.cancel()
        let delay = keepDelay
        keepTasks[diffID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.keepTasks[diffID] = nil
            // Still there: he kept it. (Changed or gone: no evidence either way.)
            guard let field = self.paster.currentText(of: target),
                  field.contains(polished.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            self.report(self.dictionary.observe(before: original, after: polished, source: .opt1Kept, operation: diffID))
        }
    }

    /// Opt+1 Undo: negative evidence for every learned fix in the undone edit.
    func polishUndone(diffID: UUID, original: String, candidate: String) {
        keepTasks.removeValue(forKey: diffID)?.cancel()
        report(dictionary.observeUndo(original: original, candidate: candidate, operation: diffID))
    }

    // MARK: - The delayed check

    private func readField() -> String? {
        guard let pending else { return nil }
        return paster.currentText(of: pending.snapshot)
    }

    private func runCheck(current: String) {
        guard var state = pending else { return }
        // Field cleared (or emptied) → never learn.
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, current != state.baseline else { return }
        guard let edit = Self.editedSpan(baseline: state.baseline, pastedRange: state.pastedRange, current: current) else { return }
        let signature = edit.before + "\u{1F}" + edit.after
        guard state.observed.insert(signature).inserted else { return }
        pending = state

        // Training signal: what the field holds after the user corrected the dictation.
        if current.utf16.count <= 8_000 {
            DictationTrainingLog.append(DictationTrainingRecord(kind: "edit", id: state.dictationID, recordedAt: Date(),
                app: state.snapshot.bundleId, finalText: state.pasted, editedField: current))
            // The same correction also lands on the dictation's run record (runs.jsonl), as an "edited" follow-up.
            if let dictationID = state.dictationID, !dictationID.isEmpty {
                FlowRunLog.followup(id: dictationID, kind: "dictation", followup: "edited",
                                    app: state.snapshot.bundleId, editedText: current)
            }
        }
        report(dictionary.observe(before: edit.before, after: edit.after, source: .dictationEdit))
    }

    /// The words he changed inside the pasted text: the baseline and the current field share a prefix and
    /// a suffix; what is between them must lie inside the paste. Edits elsewhere, typing after the paste,
    /// or a new paste give nil. Both sides are widened to whole words.
    nonisolated static func editedSpan(baseline: String, pastedRange: NSRange, current: String) -> (before: String, after: String)? {
        let a = Array(baseline.utf16), b = Array(current.utf16)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        var lo = p, hiA = a.count - s, hiB = b.count - s
        // Only a change inside the paste is a correction of the paste.
        guard lo >= pastedRange.location, hiA <= NSMaxRange(pastedRange) else { return nil }
        func isWordUnit(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return true }
            return CharacterSet.alphanumerics.contains(scalar) || u == 39 || u == 0x2019 || u == 45
        }
        while lo > pastedRange.location, isWordUnit(a[lo - 1]) { lo -= 1 }
        // Past the change both texts are the same, so widening the right edge moves both ends together.
        while hiA < NSMaxRange(pastedRange), hiA < a.count, isWordUnit(a[hiA]) { hiA += 1; hiB += 1 }
        guard hiA > lo, hiB >= lo, hiB <= b.count else { return nil }
        let before = String(utf16CodeUnits: Array(a[lo..<hiA]), count: hiA - lo)
        let after = String(utf16CodeUnits: Array(b[lo..<hiB]), count: hiB - lo)
        guard before != after, before.count <= 200, after.count <= 200 else { return nil }
        // Context around the change, so a capital at a sentence start is read as one.
        let ctxStart = max(pastedRange.location, lo - 60)
        let lead = String(utf16CodeUnits: Array(a[ctxStart..<lo]), count: lo - ctxStart)
        let tailEnd = max(hiA, min(NSMaxRange(pastedRange), hiA + 40))
        let tail = String(utf16CodeUnits: Array(a[hiA..<tailEnd]), count: tailEnd - hiA)
        return (lead + before + tail, lead + after + tail)
    }

    private func report(_ events: [AutoDictionary.Event]) {
        for event in events.prefix(maxWordsPerCorrection) {
            switch event.change {
            case .promoted:
                Telemetry.log("vocab.learned", properties: ["kind": event.kind.rawValue])
                print("[VOICE-CORRECTION] learned a \(event.kind.rawValue) from his fixes")
                onWordLearned?(event.written)
            case .removed:
                Telemetry.log("vocab.unlearned", properties: ["kind": event.kind.rawValue])
                print("[VOICE-CORRECTION] removed a learned \(event.kind.rawValue) after an undo")
            }
        }
    }
}
