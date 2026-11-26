import Foundation

/// Literal FTS5 terms. Punctuation is a word boundary, never permission to
/// splice neighboring words or interpret user text as an FTS operator.
enum HistorySearchQuery {
    static func literalTerms(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: "-_*"))
        let separated = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            allowed.contains($0) ? $0 : UnicodeScalar(0x20)!
        }))
        return separated.split(whereSeparator: \.isWhitespace).compactMap { token in
            let prefix = token.hasSuffix("*")
            let word = token.replacingOccurrences(of: "*", with: " ")
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return "\"" + word.trimmingCharacters(in: .whitespaces) + "\"" + (prefix ? "*" : "")
        }.joined(separator: " ")
    }
}
