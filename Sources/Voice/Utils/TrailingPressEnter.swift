import Foundation

/// Conservative, opt-in interpretation of an explicit trailing voice command.
/// The caller must independently verify insertion before sending Return.
enum TrailingPressEnter {
    struct Parsed: Equatable {
        let text: String
        let shouldSubmit: Bool
    }

    static func parse(_ text: String, enabled: Bool) -> Parsed {
        let unchanged = Parsed(text: text, shouldSubmit: false)
        let quoteCharacters = CharacterSet(charactersIn: "\"'‘’“”`")
        guard enabled, text.rangeOfCharacter(from: quoteCharacters) == nil else { return unchanged }
        // Restrict the command to its own final sentence or line. A phrase in
        // normal prose, a quoted command, or a negation must remain literal.
        let negation = #"(?i)\b(?:not|never|don't|dont|do not|without)\b"#
        guard text.range(of: negation, options: .regularExpression) == nil,
              let match = text.range(of: #"(?i)(?:[.!?][ \t]+|\n[ \t]*)press[ \t]+enter[.]?[ \t\r\n]*$"#,
                                     options: .regularExpression) else { return unchanged }
        // Keep the sentence punctuation, dropping only the command separator.
        let separator = text[match]
        let punctuation = separator.first.map { ".!?".contains($0) } == true ? String(separator.prefix(1)) : ""
        let content = (String(text[..<match.lowerBound]) + punctuation).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return unchanged }
        return Parsed(text: content, shouldSubmit: true)
    }

    /// All offsets are UTF-16, as used by Accessibility selected text ranges.
    /// A match is evidence of the expected edit, not evidence of delivery of Return.
    static func insertionVerified(original: String, replacedRange: NSRange, inserted: String,
                                  observed: String, caret: NSRange, sameTarget: Bool) -> Bool {
        guard sameTarget, !inserted.isEmpty, replacedRange.location != NSNotFound,
              replacedRange.location >= 0, replacedRange.length >= 0 else { return false }
        let originalNSString = original as NSString
        guard replacedRange.location <= originalNSString.length,
              replacedRange.length <= originalNSString.length - replacedRange.location else { return false }
        let insertedLength = (inserted as NSString).length
        guard insertedLength <= Int.max - replacedRange.location else { return false }
        return originalNSString.replacingCharacters(in: replacedRange, with: inserted).utf16.elementsEqual(observed.utf16) &&
            caret.location == replacedRange.location + insertedLength && caret.length == 0
    }
}
