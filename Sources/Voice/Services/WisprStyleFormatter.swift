import Foundation

/// A conservative presentation pass for the imported very-casual style.
/// Keep names, identifiers and punctuation that may carry meaning intact.
enum WisprStyleFormatter {
    static func format(_ text: String, style: String, protectedTerms: [String] = []) -> String {
        guard style.lowercased() == "verycasual" else { return text }
        var output = text
        let protected = protectedTerms.filter { !$0.isEmpty }
        // Lowercase ordinary sentence openings, but not a known term, acronym,
        // mixed-case identifier, URL, email or a word inside a quoted passage.
        let pattern = #"(?m)(?:^|[.!?]\s+)([A-Z][a-z]+|I)(?=\b)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let range = match.range(at: 1)
                guard let swiftRange = Range(range, in: output) else { continue }
                let word = String(output[swiftRange])
                let suffix = ns.substring(from: range.location)
                if protected.contains(where: { suffix.hasPrefix($0) }) { continue }
                if suffix.range(of: #"^[A-Za-z]+(?:[A-Z0-9_]|://|@|\.[A-Za-z]{2,})"#, options: .regularExpression) != nil { continue }
                output.replaceSubrange(swiftRange, with: word.lowercased())
            }
        }
        // Drop only a final full stop on prose, not abbreviations, ellipses or lists.
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("."), !trimmed.hasSuffix(".."),
           trimmed.range(of: #"(?:\b[A-Z]\.|\b(?:etc|inc|ltd|vs|e\.g|i\.e)\.)$"#, options: [.regularExpression, .caseInsensitive]) == nil,
           trimmed.range(of: #"(?m)^\s*(?:[-*•]|\d+\.)\s+"#, options: .regularExpression) == nil,
           let dot = output.lastIndex(of: ".") {
            output.remove(at: dot)
        }
        return output
    }
}
