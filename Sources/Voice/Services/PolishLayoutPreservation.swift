import Foundation

/// Layout-only postprocessing. Existing separators and structured whitespace
/// belong to the text; sentence spacing is confined to plain prose lines.
enum PolishLayoutPreservation {
    private static let salutationGap = try! NSRegularExpression(pattern:
        #"\A(?:Hi|Hello|Hey|Dear|Good morning|Good afternoon|Good evening)[ \t]+\p{Lu}[\p{L}\p{M}'’\-]*(?:[ \t]+and[ \t]+\p{Lu}[\p{L}\p{M}'’\-]*)?,(?<gap>[ \t]+)(?=\S)"#)
    private static let sentenceGap = try! NSRegularExpression(pattern: #"(?<=[.!?])[ \t]+(?=\p{Lu})"#)
    private static let structuredStart = try! NSRegularExpression(pattern: #"\A(?:[-+*•>]|[0-9]{1,3}[.)]|#{1,6})[ \t]+"#)
    private static let repeatedSpaces = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let punctuationRules: [(NSRegularExpression, String)] = [
        (#"[ \t]+([,;:!?])"#, "$1"),
        (#"[ \t]+(\.)(?!\.)"#, "$1"),
        (#"(?<![A-Za-z])([a-z][a-z]+)\.([A-Z][a-z])"#, "$1. $2"),
        (#"([a-z])([!?])([A-Z])"#, "$1$2 $3"),
        (#"([,;])([A-Za-z])"#, "$1 $2"),
        (#"\([ \t]+"#, "("),
        (#"[ \t]+\)"#, ")")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func normalizeEmailSalutation(_ text: String) -> String {
        // Only an inline horizontal gap can be changed. A deliberate line or
        // paragraph break (including CRLF) is already valid email layout.
        guard let match = salutationGap.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return text
        }
        return (text as NSString).replacingCharacters(in: match.range(withName: "gap"), with: "\n\n")
    }

    static func forceParagraphBreaks(_ text: String) -> String {
        // This fallback is for an unformatted prose block. Explicit lines,
        // blank lines, lists, indentation and code must keep their own layout.
        guard !text.contains(where: \.isNewline), text.first?.isWhitespace != true,
              !text.contains(where: { "`{}".contains($0) }), !text.contains("</"),
              structuredStart.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else {
            return text
        }
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words > 80 else { return text }
        let ns = text as NSString
        let matches = sentenceGap.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return text }
        let targets: [Double] = words > 160 ? [0.33, 0.66] : [0.5]
        var gaps: [NSRange] = []
        for target in targets {
            let position = Int(Double(ns.length) * target)
            if let closest = matches.min(by: { abs($0.range.location - position) < abs($1.range.location - position) }),
               !gaps.contains(closest.range) {
                gaps.append(closest.range)
            }
        }
        let result = NSMutableString(string: text)
        for gap in gaps.sorted(by: { $0.location > $1.location }) {
            // Replace the whole gap, not one UTF-16 unit of a multi-space run.
            result.replaceCharacters(in: gap, with: "\n\n")
        }
        return result as String
    }

    static func whitespacePass(_ text: String) -> String {
        proseLines(text) { line in
            repeatedSpaces.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: " ")
        }
    }

    static func punctuationSpacingPass(_ text: String) -> String {
        proseLines(text) { line in
            var result = line
            for (pattern, replacement) in punctuationRules {
                result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                          withTemplate: replacement)
            }
            return repeatedSpaces.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                            withTemplate: " ")
        }
    }

    /// Transform only prose contents, keeping the original separators. Swift
    /// treats CRLF as one Character, so appending that Character preserves both
    /// code units and never creates a stray carriage return.
    private static func proseLines(_ text: String, transform: (String) -> String) -> String {
        let multiline = text.contains(where: \.isNewline)
        var fence: (marker: Character, count: Int)?
        func horizontal(_ character: Character) -> Bool { character == " " || character == "\t" }
        func line(_ value: Substring) -> String {
            let prefix = value.prefix(while: horizontal)
            let content = value.dropFirst(prefix.count)
            if let first = content.first, first == "`" || first == "~" {
                let count = content.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if let open = fence {
                        if first == open.marker, count >= open.count,
                           content.dropFirst(count).allSatisfy(horizontal) { fence = nil }
                    } else {
                        fence = (first, count)
                    }
                    return String(value)
                }
            }
            // An indented code line, fenced block or inline code span should
            // not have spacing inside it rewritten by a prose normalizer.
            if fence != nil || prefix.contains("\t") || prefix.count >= 4 || content.contains("`") {
                return String(value)
            }
            guard !content.isEmpty else { return multiline ? String(value) : "" }
            let suffix = content.reversed().prefix(while: horizontal).reversed()
            let body = String(content.dropLast(suffix.count))
            let structured = structuredStart.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
            // Keep indentation and hard-break whitespace in structured text.
            // Ordinary one-line model padding is still removed.
            let leading = multiline || structured ? String(prefix) : ""
            let trailing = multiline || structured ? String(suffix) : ""
            return leading + transform(body) + trailing
        }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var start = text.startIndex
        for index in text.indices where text[index].isNewline {
            result += line(text[start..<index])
            result.append(text[index])
            start = text.index(after: index)
        }
        result += line(text[start...])
        return result
    }
}
