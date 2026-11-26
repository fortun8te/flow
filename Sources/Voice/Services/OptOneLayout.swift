import Foundation

/// Layout for an Opt+1 result (22 Nov 2026: "it still really doesn't do proper line breaks").
///
/// - Existing structured lines keep their layout; independent plain prose lines can still be laid out.
/// - One block of 40+ words becomes short paragraphs, and a spoken or typed enumeration ("First, ...
///   Second, ...") becomes a lead-in line and one item per line, with the same rules as dictation
///   (DictationParagraphs). Under 25 words it always stays one line.
/// - Code, markup and anything the edit already broke into lines are left alone.
///
/// Deterministic and cheap (no model call): a few regex passes over the edited text.
enum OptOneLayout {
    static func apply(source: String, edited: String) -> String {
        guard !looksLikeCode(source), !looksLikeCode(edited) else { return edited }
        // The deterministic formatter leaves existing list lines, indentation
        // and fenced blocks alone. It can still lay out each long prose line.
        return DictationParagraphs.formatDictation(edited)
    }

    static func looksLikeCode(_ text: String) -> Bool {
        if text.contains("`") || text.contains("{") || text.contains("}") || text.contains("</") || text.contains("=>") { return true }
        // Semicolons in ordinary enumerations do not make a message code.
        // Require actual syntax cues before opting out of prose layout.
        return text.range(of: #"(?m)^\s*(?:let|var|const|func|def|class|struct|import|return)\s+[^\n]*[;=()]"#,
                          options: .regularExpression) != nil
    }

    /// Only the exact deterministic layout, or a pure case/whitespace change,
    /// may disregard enumeration markers. Do not erase all numbers or ordinary
    /// words such as "one" and "and" when comparing arbitrary drafts.
    static func sameWords(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func words(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }).map(String.init)
        }
        return words(a) == words(b) || (!looksLikeCode(a) && DictationParagraphs.formatDictation(a) == b)
    }
}
