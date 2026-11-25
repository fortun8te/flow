import Foundation

/// Layout for an Opt+1 result (22 Nov 2026: "it still really doesn't do proper line breaks").
///
/// - Text he laid out himself (any line break in the selection) keeps exactly that layout.
/// - One block of 40+ words becomes short paragraphs, and a spoken or typed enumeration ("First, ...
///   Second, ...") becomes a lead-in line and one item per line, with the same rules as dictation
///   (DictationParagraphs). Under 25 words it always stays one line.
/// - Code, markup and anything the edit already broke into lines are left alone.
///
/// Deterministic and cheap (no model call): a few regex passes over the edited text.
enum OptOneLayout {
    static func apply(source: String, edited: String) -> String {
        guard !source.contains(where: \.isNewline), !edited.contains(where: \.isNewline) else { return edited }
        guard !looksLikeCode(edited) else { return edited }
        let laidOut = DictationParagraphs.formatDictation(edited)
        // Only line breaks and list markers may change: the words must be the same.
        return sameWords(edited, laidOut) ? laidOut : edited
    }

    static func looksLikeCode(_ text: String) -> Bool {
        if text.contains("`") || text.contains("{") || text.contains("}") || text.contains("</") || text.contains("=>") { return true }
        let semicolons = text.filter { $0 == ";" }.count
        return semicolons >= 2
    }

    /// Same words in the same order, ignoring list markers ("1.", "-") and spoken ordinals the list replaced.
    static func sameWords(_ a: String, _ b: String) -> Bool {
        let markers: Set<String> = ["first", "firstly", "second", "secondly", "third", "thirdly", "fourth", "fifth",
                                    "sixth", "seventh", "eighth", "ninth", "lastly", "finally", "number", "one", "two",
                                    "three", "four", "five", "six", "seven", "eight", "nine", "and", "of", "all"]
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
                .map(String.init).filter { Int($0) == nil }
        }
        let x = words(a).filter { !markers.contains($0) }, y = words(b).filter { !markers.contains($0) }
        return x == y
    }
}
