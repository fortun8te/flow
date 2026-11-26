import Foundation

/// What a word scorer considered on one immutable draft, including KEEP.
/// These are model observations, never reviewed targets or calibrated probabilities.
struct WordDecisionEvidence: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let maxPerRun = 64
    static let maxContextUTF16 = 2_048
    static let maxCandidateUTF16 = 128
    static let maxCandidates = 9
    static let maxFeatures = 16

    struct Span: Codable, Equatable, Sendable {
        var location: Int
        var length: Int

        var range: NSRange { NSRange(location: location, length: length) }

        fileprivate var hasValidBounds: Bool {
            location >= 0 && length > 0 && location <= Int.max - length
        }
    }

    struct Candidate: Codable, Equatable, Sendable {
        var text: String
        var rawScore: Double
        var adjustedScore: Double? = nil
        var features: [String: Double] = [:]
    }

    var schemaVersion = WordDecisionEvidence.currentSchema
    var stage: String
    var mode: String
    /// Exact source slice before this stage edits it; it is not a reconstructed/model-normalized sentence.
    var context: String
    var original: String
    /// Both spans use absolute UTF-16 coordinates in the same pre-edit source.
    var sourceSpan: Span
    var contextSpan: Span
    /// Candidate zero is the exact original. Order is the actual scorer order.
    var candidates: [Candidate]
    /// Zero means the production rule kept the original, not that a person approved it.
    var chosenIndex: Int
    var margin: Double
    var threshold: Double
    /// Runtime model identity. Artifact hashes belong in experiment manifests when available.
    var modelID: String

    static func make(stage: String, mode: String, source: String, range: NSRange, contextRange: NSRange,
                     candidates: [Candidate], chosenIndex: Int, margin: Double, threshold: Double,
                     modelID: String) -> WordDecisionEvidence? {
        let text = source as NSString
        guard validUTF16Range(range, in: text), validUTF16Range(contextRange, in: text),
              contextRange.length <= maxContextUTF16, range.length <= maxCandidateUTF16,
              range.location >= contextRange.location,
              range.location + range.length <= contextRange.location + contextRange.length else { return nil }
        let evidence = WordDecisionEvidence(stage: stage, mode: mode, context: text.substring(with: contextRange),
            original: text.substring(with: range), sourceSpan: Span(location: range.location, length: range.length),
            contextSpan: Span(location: contextRange.location, length: contextRange.length), candidates: candidates,
            chosenIndex: chosenIndex, margin: margin, threshold: threshold, modelID: modelID)
        return evidence.isValid ? evidence : nil
    }

    /// Recheck at collection/write time too: decoded or subsequently changed values are untrusted.
    var isValid: Bool {
        guard schemaVersion == Self.currentSchema, Self.identifier(stage, maximum: 64),
              ["dictation", "typed", "slips"].contains(mode), Self.label(modelID, maximum: 256),
              margin.isFinite, threshold.isFinite,
              sourceSpan.hasValidBounds, contextSpan.hasValidBounds,
              contextSpan.length <= Self.maxContextUTF16, sourceSpan.length <= Self.maxCandidateUTF16,
              context.utf16.count == contextSpan.length, original.utf16.count == sourceSpan.length,
              sourceSpan.location >= contextSpan.location,
              sourceSpan.location + sourceSpan.length <= contextSpan.location + contextSpan.length,
              (2...Self.maxCandidates).contains(candidates.count),
              candidates.indices.contains(chosenIndex), candidates[0].text.utf16.elementsEqual(original.utf16),
              Set(candidates.map { Data($0.text.utf8) }).count == candidates.count else { return false }
        let relative = NSRange(location: sourceSpan.location - contextSpan.location, length: sourceSpan.length)
        let slice = context as NSString
        guard Self.validUTF16Range(relative, in: slice),
              slice.substring(with: relative).utf16.elementsEqual(original.utf16) else { return false }
        for candidate in candidates {
            guard !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  candidate.text.utf16.count <= Self.maxCandidateUTF16, candidate.rawScore.isFinite,
                  candidate.adjustedScore?.isFinite ?? true, candidate.features.count <= Self.maxFeatures,
                  candidate.features.allSatisfy({ Self.identifier($0.key, maximum: 48) && $0.value.isFinite }) else { return false }
        }
        return true
    }

    private static func identifier(_ text: String, maximum: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= maximum && text.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func label(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximum
            && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validUTF16Range(_ range: NSRange, in text: NSString) -> Bool {
        guard range.location >= 0, range.length > 0, range.location <= text.length,
              range.length <= text.length - range.location else { return false }
        func boundary(_ offset: Int) -> Bool {
            guard offset > 0 && offset < text.length else { return true }
            return !((0xD800...0xDBFF).contains(text.character(at: offset - 1))
                && (0xDC00...0xDFFF).contains(text.character(at: offset)))
        }
        return boundary(range.location) && boundary(range.location + range.length)
    }
}
