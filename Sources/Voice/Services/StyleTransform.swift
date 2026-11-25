// Flow: the four writing styles, done by rule after the model, never by rewording.
//
//   Formal      capitals and full stops; "i" becomes "I". No wording change, no exclamation marks.
//   Casual      a capital at the start of the text; no full stop at the very end. Commas, ? and ! stay.
//   Very casual all lower case (except "I" and capitals that are acronyms); full stops that end sentences go.
//   Excited     the last full stop becomes an exclamation mark. Capitals are left as the model wrote them.
//
// These four match the one-line descriptions in Settings. Old "neutral" settings read as Casual.
// Everything here is deterministic and works on any engine, so the style looks the same whichever model ran.

import Foundation

enum StyleTransform {
    static func apply(_ text: String, style: PersonalityStyle) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        switch style {
        case .formal: return formal(text)
        case .casual, .neutral: return casual(text)
        case .veryCasual: return veryCasual(text)
        case .excited: return excited(text)
        }
    }

    /// Same as `apply`, reading the stored style name. Unknown names are left alone.
    static func apply(_ text: String, styleName: String) -> String {
        guard let style = PersonalityStyle(rawValue: styleName.lowercased()) else { return text }
        return apply(text, style: style)
    }

    // MARK: Formal

    static func formal(_ text: String) -> String {
        var out = capitalizeSentenceStarts(text)
        out = standaloneI(out)
        return addFinalFullStop(out)
    }

    // MARK: Casual

    static func casual(_ text: String) -> String {
        var out = capitalizeFirstLetter(text)
        out = standaloneI(out)
        return dropFinalFullStop(out)
    }

    // MARK: Very casual

    static func veryCasual(_ text: String) -> String {
        var out = lowercaseWords(text)
        out = dropSentenceFullStops(out)
        return dropFinalFullStop(out)
    }

    // MARK: Excited

    static func excited(_ text: String) -> String {
        var out = text
        while let last = out.last, last.isWhitespace { out.removeLast() }
        if out.hasSuffix("...") { return text }
        if out.hasSuffix(".") {
            out.removeLast()
            return out + "!" + trailingWhitespace(text)
        }
        if let last = out.last, last.isLetter || last.isNumber {
            return out + "!" + trailingWhitespace(text)
        }
        return text
    }

    // MARK: Helpers

    private static func trailingWhitespace(_ text: String) -> String {
        String(text.reversed().prefix { $0.isWhitespace }.reversed())
    }

    /// Capitalises the first letter of the text and of every sentence after . ! ? or a new line.
    static func capitalizeSentenceStarts(_ text: String) -> String {
        var chars = Array(text)
        var startOfSentence = true
        for i in chars.indices {
            let c = chars[i]
            if startOfSentence, c.isLetter {
                chars[i] = Character(c.uppercased())
                startOfSentence = false
            } else if c == "\n" || c == "." || c == "!" || c == "?" {
                startOfSentence = true
            } else if !c.isWhitespace && !c.isPunctuation {
                startOfSentence = false
            }
        }
        return String(chars)
    }

    static func capitalizeFirstLetter(_ text: String) -> String {
        var chars = Array(text)
        guard let i = chars.firstIndex(where: { $0.isLetter }) else { return text }
        chars[i] = Character(chars[i].uppercased())
        return String(chars)
    }

    /// "i", "i'm", "i’ll" become "I", "I'm", "I’ll". Other words are not touched.
    static func standaloneI(_ text: String) -> String {
        replace(text, pattern: #"(?<![\p{L}\p{N}'’])i(?=$|[^\p{L}\p{N}])"#, options: []) { _ in "I" }
    }

    static func addFinalFullStop(_ text: String) -> String {
        let (body, tail) = splitTrailingWhitespace(text)
        guard let last = body.last, last.isLetter || last.isNumber, !isListLine(body) else { return text }
        return body + "." + tail
    }

    static func dropFinalFullStop(_ text: String) -> String {
        let (body, tail) = splitTrailingWhitespace(text)
        guard body.hasSuffix("."), !body.hasSuffix("..") else { return text }
        let before = body.dropLast()
        guard let prev = before.last, prev.isLetter || prev.isNumber || prev == ")" || prev == "\"" else { return text }
        return String(before) + tail
    }

    /// Lower case for every word except "I" forms and acronyms (two or more capitals, such as OK or API).
    static func lowercaseWords(_ text: String) -> String {
        replace(text, pattern: #"[\p{L}'’]+"#, options: []) { word in
            if word == "I" || word.lowercased() == "i" || word.lowercased().hasPrefix("i'") || word.lowercased().hasPrefix("i’") {
                return "I" + word.dropFirst()
            }
            let letters = word.filter { $0.isLetter }
            if letters.count >= 2, letters == letters.uppercased() { return word }
            return word.lowercased()
        }
    }

    /// Removes full stops that end a sentence: after at least two letters, before a space or the end.
    /// Abbreviations such as "e.g." and "U.S." and numbers such as "3.5" are kept.
    static func dropSentenceFullStops(_ text: String) -> String {
        replace(text, pattern: #"(?<=\p{L}{2})\.(?=\s|$)"#, options: []) { _ in "" }
    }

    private static func isListLine(_ text: String) -> Bool {
        let last = text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? text
        return last.range(of: #"^\s*([-*\u{2022}]|\d+\.)\s+"#, options: .regularExpression) != nil
    }

    private static func splitTrailingWhitespace(_ text: String) -> (String, String) {
        let tail = trailingWhitespace(text)
        return (String(text.dropLast(tail.count)), tail)
    }

    private static func replace(_ text: String, pattern: String, options: NSRegularExpression.Options,
                                with transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform(ns.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
