import Foundation

/// Locates correction evidence using the verified insertion, never a text search.
/// UTF-16 ranges come from Accessibility. Anything outside the inserted span is unrelated.
enum CorrectionEvidence {
    static func valid(_ range: NSRange, in text: String) -> Bool {
        let count = text.utf16.count
        return range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && range.location <= count && range.length <= count - range.location
            && Range(range, in: text) != nil
    }

    static func baseline(before: String, replacing range: NSRange, inserted: String) -> String? {
        guard !inserted.isEmpty, valid(range, in: before), let indices = Range(range, in: before) else { return nil }
        return before.replacingCharacters(in: indices, with: inserted)
    }

    /// The entire corrected insertion, without surrounding field text. An insertion immediately
    /// before or after the paste is ambiguous, so it does not become a correction example.
    static func correctedInsertion(baseline: String, pastedRange: NSRange, current: String) -> String? {
        guard pastedRange.length > 0, valid(pastedRange, in: baseline),
              baseline.utf16.count <= 20_000, current.utf16.count <= 20_000,
              !baseline.utf16.elementsEqual(current.utf16) else { return nil }
        let a = Array(baseline.utf16), b = Array(current.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let changedEnd = a.count - suffix
        let pasteEnd = pastedRange.location + pastedRange.length
        guard prefix >= pastedRange.location, changedEnd <= pasteEnd else { return nil }
        if prefix == changedEnd, prefix == pastedRange.location || prefix == pasteEnd { return nil }

        let correctedLength = pastedRange.length + b.count - a.count
        guard correctedLength > 0 else { return nil }
        let correctedRange = NSRange(location: pastedRange.location, length: correctedLength)
        guard valid(correctedRange, in: current), let indices = Range(correctedRange, in: current) else { return nil }
        let target = String(current[indices])
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return target
    }
}
