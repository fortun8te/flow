import Foundation

/// Immutable vocabulary and guard evidence for one complete transcription.
struct AcousticVocabularySnapshot: Sendable {
    struct Options: Equatable, Sendable {
        static let defaultMinimumSimilarity: Float = 0.6
        let cbw: Float?
        let minimumSimilarity: Float

        init(cbw: Float?, minimumSimilarity: Float?) {
            self.cbw = cbw.flatMap { $0.isFinite ? $0 : nil }
            self.minimumSimilarity = minimumSimilarity.flatMap {
                $0.isFinite && (0...1).contains($0) ? $0 : nil
            } ?? Self.defaultMinimumSimilarity
        }
    }

    struct SessionKey: Equatable, Sendable {
        let termBytes: [Data]
        let options: Options
    }

    let terms: [String]
    let knownOther: Set<String>
    let options: Options
    let sessionKey: SessionKey

    init(terms: [String], knownOther: Set<String>, options: Options) {
        self.terms = terms
        self.knownOther = knownOther
        self.options = options
        // Swift String equality can conflate different tokenizer input bytes.
        sessionKey = SessionKey(termBytes: terms.map { Data($0.utf8) }, options: options)
    }

    /// Names may contain horizontal spacing variants, but never join separate lines.
    static func normalizedTerm(_ text: String) -> String? {
        guard !text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else { return nil }
        let term = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return term.isEmpty ? nil : term
    }
}
