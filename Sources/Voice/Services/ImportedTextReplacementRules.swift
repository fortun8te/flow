import Foundation

/// Explicit imported text expansions. Unlike recognition vocabulary, a snippet
/// can contain newlines, an empty replacement, or literal regex punctuation.
/// Compile once per archive revision and apply a single non-cascading pass.
struct ImportedTextReplacementRules {
    private let mapping: [String: String]
    private let regex: NSRegularExpression?

    init(_ pairs: [(from: String, to: String)]) {
        var mapping: [String: String] = [:]
        for pair in pairs where !pair.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mapping[pair.from.lowercased()] = pair.to
        }
        self.mapping = mapping
        let terms = mapping.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        let alternatives = terms.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        regex = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_])(?:"# + alternatives + #")(?![\p{L}\p{N}_])"#,
            options: .caseInsensitive)
    }

    func apply(to text: String) -> String {
        guard let regex else { return text }
        let original = text as NSString
        let output = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            guard let replacement = mapping[original.substring(with: match.range).lowercased()] else { continue }
            output.replaceCharacters(in: match.range, with: replacement)
        }
        return output as String
    }
}
