// Flow: the rules for one Opt+1 polish, kept pure so they can be tested without a text field.
//
// A polish captures the selection, asks the local model once, and replaces the selection once. What it
// reports is one of five plain outcomes. Undo puts back the original only when the text is still exactly
// what Flow wrote; otherwise nothing is overwritten. Selections over 6,000 characters are refused.
// (sol/07, A4 of the plan.)

import Foundation

enum PolishOutcome: Equatable {
    /// The model's version replaced the selection.
    case changed
    /// The model answered, and the answer is the text as it was. Nothing to do.
    case noChangesNeeded
    /// The model answered, but its answer was refused by a check. The text is unchanged.
    case couldNotImprove(reason: String)
    /// No answer at all: the local model was not ready, or it timed out.
    case unavailable(reason: String)
    /// The selection changed while the model was thinking. Nothing was replaced.
    case textChangedWhilePolishing

    /// Short, plain words for the pill, toasts and history.
    var message: String {
        switch self {
        case .changed: return "Polished. Review, Undo or Try again."
        case .noChangesNeeded: return "No changes needed."
        case let .couldNotImprove(reason): return "Couldn't improve this text. \(reason)"
        case let .unavailable(reason): return "Polish is not available. \(reason)"
        case .textChangedWhilePolishing: return "Text changed while polishing. Nothing was replaced."
        }
    }
}

enum PolishTransaction {
    static let shortcutBudgetSeconds: Double = 8
    /// Long selections get time in proportion (the 9B writes ~10-18 words/s on this Mac): a 150-word message
    /// used to hit the flat 8 s and fall back to rule fixes (22 Nov 2026). Capped at 25 s.
    static func shortcutBudgetSeconds(for text: String) -> Double {
        let words = Double(text.split(whereSeparator: \.isWhitespace).count)
        return min(25, max(shortcutBudgetSeconds, 3 + words * 0.12))
    }
    /// Longest selection Opt+1 will take. Longer ones are refused before any model call.
    static let maxCharacters = 6_000

    static func isTooLong(_ text: String) -> Bool {
        text.count > maxCharacters
    }

    /// Longer selections can contain several separate asks.
    static func prefersReviewModel(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= 42
    }

    /// Turns the model's answer into one outcome. `candidate` is nil when there was no usable answer.
    /// `rejection` is the reason a check gave when it refused the answer, if any.
    static func classify(original: String, candidate: String?, rejection: String?) -> PolishOutcome {
        guard let candidate else {
            if let rejection { return .couldNotImprove(reason: rejection) }
            return .unavailable(reason: "Try again when the local model is ready.")
        }
        if candidate.trimmingCharacters(in: .whitespacesAndNewlines) == original.trimmingCharacters(in: .whitespacesAndNewlines) {
            return .noChangesNeeded
        }
        // Polish never translates: Dutch (or English) that comes back partly German is refused.
        if DictationLanguage.germanDrift(source: original, output: candidate) {
            return .couldNotImprove(reason: "It would change the language.")
        }
        return .changed
    }

    /// The whole field's text once `replacement` has been written over the UTF-16 `range`.
    /// Nil when the range does not fit the text, so no expected text is made from a bad range.
    static func expectedFullText(before full: String, range: NSRange, replacement: String) -> String? {
        let ns = full as NSString
        guard range.location >= 0, range.length >= 0, range.location <= ns.length, range.length <= ns.length - range.location else { return nil }
        return ns.replacingCharacters(in: range, with: replacement)
    }

    /// Undo may write the original back only when the field still holds exactly what Flow wrote.
    static func mayUndo(currentFullText: String, expectedAfterPolish: String) -> Bool {
        currentFullText == expectedAfterPolish
    }

    /// A review window may act on the applied edit it actually displays.
    static func matchesUndo(requested: UUID?, active: UUID) -> Bool {
        requested == nil || requested == active
    }
}

/// The last applied Opt+1 polish: what Undo and Try again need to put the original back.
struct LastPolish {
    let diffID: UUID
    let target: CursorPaster.PasteTargetSnapshot
    let original: String
    let candidate: String
    /// Where the candidate sits in the field after the replacement (UTF-16).
    let candidateRange: CFRange
    /// The field's whole text right after the replacement.
    let expectedFullText: String
    let quick: Bool
}
