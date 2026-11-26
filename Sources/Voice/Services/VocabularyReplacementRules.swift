import Foundation

/// Compiled whole-phrase rules. Apply to text whose fragile spans are already frozen.
/// Conflicting targets abstain; horizontal spacing may vary without joining paragraphs.
struct VocabularyReplacementRules {
    let regex: NSRegularExpression?
    let replacements: [String: String]

    static func key(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .lowercased().replacingOccurrences(of: "’", with: "'")
    }

    init(_ pairs: [(heard: String, written: String)], blockedAliases: Set<String> = [], excludedTargets: Set<String> = []) {
        var map: [String: String] = [:]
        var blocked = Set(blockedAliases.map(Self.key))
        let excluded = Set(excludedTargets.map(Self.key))
        for pair in pairs {
            let alias = Self.key(pair.heard)
            let target = pair.written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !alias.isEmpty, !target.isEmpty,
                  !pair.heard.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }),
                  !target.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }),
                  !excluded.contains(Self.key(target)) else { continue }
            if let previous = map[alias], Self.key(previous) != Self.key(target) { blocked.insert(alias) }
            else if map[alias] == nil { map[alias] = target }
        }
        for alias in blocked { map.removeValue(forKey: alias) }
        replacements = map
        let alternatives = map.keys.sorted { $0.utf16.count != $1.utf16.count ? $0.utf16.count > $1.utf16.count : $0 < $1 }
            .map { alias in
                alias.components(separatedBy: " ").map {
                    NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: "'", with: "['’]")
                }.joined(separator: "[ \\t\\u00A0]+")
            }.joined(separator: "|")
        regex = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_./@-])(?:"# + alternatives + #")(?![\p{L}\p{N}_/@-])"#,
            options: .caseInsensitive)
    }

    func apply(to text: String) -> String {
        guard let regex else { return text }
        let result = NSMutableString(string: text)
        // Matches are from the original text, so a replacement never triggers another rule in this pass.
        for match in regex.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            let found = result.substring(with: match.range)
            if let target = replacements[Self.key(found)], !found.utf16.elementsEqual(target.utf16) {
                result.replaceCharacters(in: match.range, with: target)
            }
        }
        return result as String
    }
}
