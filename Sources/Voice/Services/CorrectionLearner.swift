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
//   1. After a verified auto-paste, VoiceApp supplies a receipt with the exact
//      target, original selection and inserted payload. The field must match
//      the reconstructed baseline before observation begins.
//   2. Checks at 8 and 30 seconds require external keyboard activity and a
//      stable field. A new Flow edit cancels the pending observation.
//   3. Only changes contained inside the known inserted span are proposals.
//      Single-word SUBSTITUTIONS feed the dictionary; the corrected insertion
//      is logged as an observed edit for independent review, not a gold label.
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
// made. Retained Opt+1 results are weak evidence; Opt+1 Undo is negative evidence.
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
        let editSerial: Int
        var observed: Set<String> = []
    }
    private var pending: Pending?
    private var checkTask: Task<Void, Never>?
    private var keepTasks: [UUID: Task<Void, Never>] = [:]
    private var insertionObserver: NSObjectProtocol?

    init(dictionary: AutoDictionary = .shared) {
        self.dictionary = dictionary
        insertionObserver = NotificationCenter.default.addObserver(forName: .flowWillInsertText,
                                                                    object: nil, queue: .main) { [weak self] _ in
            // The notification is delivered on the main queue before Flow sends its own edit.
            MainActor.assumeIsolated { self?.cancelPending() }
        }
    }

    deinit {
        if let insertionObserver { NotificationCenter.default.removeObserver(insertionObserver) }
        checkTask?.cancel()
        for task in keepTasks.values { task.cancel() }
    }

    // MARK: - Public entry point

    /// Record a freshly-pasted transcript + its target element, and schedule
    /// delayed correction checks. Cancels any prior pending check.
    func track(receipt: CursorPaster.PasteReceipt, dictationID: String? = nil) {
        cancelPending()
        // Only meaningful when we can actually re-read the field later.
        guard !BackgroundActivityGate.privacyMode, AXIsProcessTrusted(), receipt.target.focusedElement != nil else { return }
        let trimmed = receipt.insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return }
        // A repeated phrase elsewhere in the field must never become our correction anchor.
        guard let range = receipt.insertedRange, let before = receipt.before.value,
              let replaced = receipt.replacedRange ?? receipt.before.caret,
              let expected = CorrectionEvidence.baseline(before: before, replacing: replaced, inserted: receipt.insertedText),
              let baseline = paster.currentText(of: receipt.target), baseline.utf16.count <= 20_000,
              baseline.utf16.elementsEqual(expected.utf16) else { return }
        pending = Pending(pasted: receipt.insertedText, snapshot: receipt.target, dictationID: dictationID,
                          baseline: baseline, pastedRange: range, editSerial: receipt.editSerial)

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

    /// A new Flow edit or Undo invalidates the earlier observation window.
    func cancelPending(dictationID: String? = nil) {
        if let dictationID, pending?.dictationID != dictationID { return }
        checkTask?.cancel()
        checkTask = nil
        pending = nil
    }

    /// Opt+1 replaced a selection and the field shows it. Kept for `keepDelay` without an Undo, it counts.
    func trackPolish(diffID: UUID, original: String, polished: String, expectedField: String,
                     target: CursorPaster.PasteTargetSnapshot) {
        keepTasks[diffID]?.cancel()
        guard !BackgroundActivityGate.privacyMode else { return }
        let delay = keepDelay
        keepTasks[diffID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.keepTasks[diffID] = nil
            // Passive retention is weak evidence only; do not match another occurrence of the text.
            guard !BackgroundActivityGate.privacyMode, let field = self.paster.currentText(of: target),
                  field.utf16.elementsEqual(expectedField.utf16) else { return }
            let observedAt = Date(), dictionary = self.dictionary
            let events = await Task.detached(priority: .utility) {
                dictionary.observe(before: original, after: polished, source: .opt1Kept, now: observedAt, operation: diffID)
            }.value
            guard !BackgroundActivityGate.privacyMode else { return }
            self.report(events)
        }
    }

    /// Opt+1 Undo: negative evidence for every learned fix in the undone edit.
    func polishUndone(diffID: UUID, original: String, candidate: String) {
        keepTasks.removeValue(forKey: diffID)?.cancel()
        cancelPending()
        guard !BackgroundActivityGate.privacyMode else { return }
        report(dictionary.observeUndo(original: original, candidate: candidate, operation: diffID))
    }

    // MARK: - The delayed check

    private func readField() -> String? {
        guard !BackgroundActivityGate.privacyMode, let pending else { return nil }
        let current = paster.captureTargetSnapshot()
        guard current.bundleId == pending.snapshot.bundleId,
              let focused = current.focusedElement, let expected = pending.snapshot.focusedElement,
              CFEqual(focused, expected) else { return nil }
        return paster.currentText(of: pending.snapshot)
    }

    private func runCheck(current: String) {
        guard !BackgroundActivityGate.privacyMode, var state = pending,
              PasteInteractionTracker.shared.editSerial != state.editSerial else { return }
        // Field cleared (or emptied) → never learn.
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, current != state.baseline else { return }
        guard let corrected = CorrectionEvidence.correctedInsertion(baseline: state.baseline,
                                                                    pastedRange: state.pastedRange, current: current),
              let edit = Self.editedSpan(baseline: state.baseline, pastedRange: state.pastedRange, current: current) else { return }
        let signature = edit.before + "\u{1F}" + edit.after
        guard state.observed.insert(signature).inserted else { return }
        pending = state

        // A review proposal, not a gold label. Never store the unrelated surrounding field.
        if corrected.utf16.count <= 8_000 {
            DictationTrainingLog.append(DictationTrainingRecord(kind: "edit", id: state.dictationID, recordedAt: Date(),
                app: state.snapshot.bundleId, finalText: state.pasted, editedField: corrected,
                feedbackSource: "observed-edit", targetScope: "pasted-span"))
            // The same correction also lands on the dictation's run record (runs.jsonl), as an "edited" follow-up.
            if let dictationID = state.dictationID, !dictationID.isEmpty {
                FlowRunLog.followup(id: dictationID, kind: "dictation", followup: "edited",
                                    app: state.snapshot.bundleId, editedText: corrected,
                                    feedbackSource: "observed-edit", targetScope: "pasted-span")
            }
        }
        // AX checks stay on MainActor. Diff classification, lexicon checks and
        // persistence use local background compute after the evidence is fixed.
        let observedAt = Date(), evidenceID = state.dictationID, dictionary = self.dictionary
        Task { @MainActor [weak self] in
            let events = await Task.detached(priority: .utility) {
                dictionary.observe(before: edit.before, after: edit.after, source: .dictationEdit,
                                   now: observedAt, evidenceID: evidenceID)
            }.value
            guard !BackgroundActivityGate.privacyMode else { return }
            self?.report(events)
        }
    }

    /// The words he changed inside the pasted text: the baseline and the current field share a prefix and
    /// a suffix; what is between them must lie inside the paste. Edits elsewhere, typing after the paste,
    /// or a new paste give nil. Both sides are widened to whole words.
    nonisolated static func editedSpan(baseline: String, pastedRange: NSRange, current: String) -> (before: String, after: String)? {
        guard CorrectionEvidence.correctedInsertion(baseline: baseline, pastedRange: pastedRange, current: current) != nil else { return nil }
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
