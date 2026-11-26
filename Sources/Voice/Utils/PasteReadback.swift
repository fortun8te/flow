// PasteReadback.swift
// ============================================================
// Decides whether a dictation paste landed, from two Accessibility looks at the
// field after the paste. Pure functions only: CursorPaster reads the field and
// acts on the answer.
//
// Verdicts
//   verified   The field holds exactly the intended edit, and the caret sits
//              right after the inserted text.
//   notLanded  The field text and the caret are both exactly as they were before
//              the paste, both were readable, and the target is the same element.
//   unknown    Anything else: no readable text, a different element, a changed
//              field that is not our edit (the user typed, or the app rewrote it).
//              Unknown never triggers a second insertion.
//
// Fallback rule
//   Only two notLanded verdicts may trigger one insertion by typing. An
//   inconclusive first look can be followed by a verified second look.
//
// Text is compared in UTF-16 units, as Accessibility ranges are.
// ============================================================

import Foundation

enum PasteVerdict: Equatable {
    case verified
    case notLanded
    case unknown
}

/// One Accessibility look at the paste target.
struct PasteFieldLook: Equatable {
    /// Whole field text, nil when the app exposes none.
    var value: String?
    /// Selection in UTF-16 units, nil when the app exposes none.
    var caret: NSRange?
    /// True when the focused app and element still match the paste target.
    var sameTarget: Bool
}

enum PasteReadbackStep: Equatable {
    case lookAgain
    case typeOnce
    case finish(PasteVerdict)
}

enum PasteReadback {
    /// Delay from the paste to the first look, in seconds.
    static let firstLookDelay: TimeInterval = 0.2
    /// Delay from the paste to the second look, in seconds. Ends the readback window.
    /// Anything not confirmed by then gets the "Copied — press ⌘V" notice (22 Nov 2026: 68 of 85
    /// readbacks were unknown and showed nothing).
    static let secondLookDelay: TimeInterval = 0.3
    /// Longest insertion, in UTF-16 units, that the typed fallback may send.
    static let maxTypedUnits = 500

    /// Whether the user must be told the text is only on the clipboard ("Copied — press ⌘V").
    /// 22 Nov 2026: 68 of 85 readbacks were unknown, so unknown alone is too noisy.
    /// - verified, or a typed insertion that went in: no notice.
    /// - focus moved to another app or no focused element, or no editable element at paste time: notice.
    /// - notLanded: notice.
    /// - unknown: notice only in an app whose readback has verified before (a likely failure there).
    ///   Apps that never give a readback are trusted when an editable element had focus.
    static func needsCopiedNotice(final verdict: PasteVerdict, typed: Bool, editableAtPaste: Bool,
                                  focusAway: Bool, appVerifiedBefore: Bool) -> Bool {
        if typed || verdict == .verified { return false }
        if focusAway || !editableAtPaste { return true }
        if verdict == .notLanded { return true }
        return appVerifiedBefore
    }

    /// Per-app memory: bundle IDs whose paste has been verified by a readback at least once.
    static let verifiedAppsKey = "voice.pasteReadbackVerifiedApps"

    static func appHasVerified(bundleID: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let bundleID else { return false }
        return (defaults.stringArray(forKey: verifiedAppsKey) ?? []).contains(bundleID)
    }

    static func recordVerified(bundleID: String?, defaults: UserDefaults = .standard) {
        guard let bundleID else { return }
        var apps = defaults.stringArray(forKey: verifiedAppsKey) ?? []
        guard !apps.contains(bundleID) else { return }
        apps.append(bundleID)
        defaults.set(apps, forKey: verifiedAppsKey)
    }

    /// Classifies one look against the state before the paste.
    static func verdict(before: PasteFieldLook, after: PasteFieldLook,
                        inserted: String, replacing range: NSRange?) -> PasteVerdict {
        guard before.sameTarget, after.sameTarget, !inserted.isEmpty,
              let beforeValue = before.value, let afterValue = after.value,
              let beforeCaret = before.caret, let afterCaret = after.caret,
              validRange(afterCaret, in: afterValue),
              let insertedRange = insertionRange(before: before, inserted: inserted, replacing: range) else { return .unknown }

        // Verified: exactly our edit, caret directly after the inserted text.
        let edit = range ?? beforeCaret
        let expected = (beforeValue as NSString).replacingCharacters(in: edit, with: inserted)
        if expected.utf16.elementsEqual(afterValue.utf16),
           afterCaret.length == 0, afterCaret.location == insertedRange.location + insertedRange.length {
            return .verified
        }

        // Not landed: nothing moved. Same text, same caret, same element.
        if beforeValue.utf16.elementsEqual(afterValue.utf16), beforeCaret == afterCaret {
            return .notLanded
        }
        return .unknown
    }

    /// Exact post-paste UTF-16 span for readback and correction learning. Invalid
    /// or mismatched ranges cannot authorize a fallback or a training label.
    static func insertionRange(before: PasteFieldLook, inserted: String, replacing range: NSRange?) -> NSRange? {
        guard before.sameTarget, !inserted.isEmpty, let value = before.value,
              let caret = before.caret, validRange(caret, in: value) else { return nil }
        let edit = range ?? caret
        guard edit == caret, validRange(edit, in: value) else { return nil }
        return NSRange(location: edit.location, length: inserted.utf16.count)
    }

    private static func validRange(_ range: NSRange, in value: String) -> Bool {
        let length = value.utf16.count
        return range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && range.location <= length && range.length <= length - range.location
            && Range(range, in: value) != nil
    }

    /// A second look may confirm a paste, but may only authorize typing when
    /// both looks confirm the field stayed unchanged.
    static func nextStep(verdict: PasteVerdict, firstVerdict: PasteVerdict?, canType: Bool) -> PasteReadbackStep {
        if verdict == .verified { return .finish(.verified) }
        guard let firstVerdict else { return .lookAgain }
        guard verdict == .notLanded else { return .finish(.unknown) }
        return firstVerdict == .notLanded && canType ? .typeOnce : .finish(.notLanded)
    }

    /// Whether the typed fallback may run for this insertion. Newlines and tabs are
    /// never typed, because a typed Return can send a message in chat apps.
    static func canType(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf16.count <= maxTypedUnits else { return false }
        // Checked per scalar: "\r\n" is one Character, so a Character comparison would miss it.
        return !text.unicodeScalars.contains { CharacterSet.newlines.contains($0) || $0 == "\t" }
    }

    /// Splits text into pieces of at most `maxUnits` UTF-16 units without splitting
    /// a Character. A single Character longer than the limit gets its own piece.
    static func typingChunks(_ text: String, maxUnits: Int = 20) -> [String] {
        var chunks: [String] = []
        var current = ""
        var units = 0
        for character in text {
            let width = String(character).utf16.count
            if units + width > maxUnits, !current.isEmpty {
                chunks.append(current)
                current = ""
                units = 0
            }
            current.append(character)
            units += width
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
