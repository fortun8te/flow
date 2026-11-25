import Foundation

/// "Safe to paste" score for a cleanup model's output, next to the content guard.
///
/// The guard keeps its hard, literal checks (links, numbers, names, negations, language, empty) and its
/// coverage rule (every sentence keeps half its content words). This adds a small logistic score over the
/// guard's own measurements: how much content each sentence kept, how much the output dropped or added,
/// its length next to the source, and how much of the source was filler. An output counts as safe when it
/// is no further from Wispr's reference than the guard's fallback (the transcript with hesitations
/// stripped) and keeps every number, negation and link the fallback keeps.
///
/// The score goes to the referee and the trace, so a dictation's risk can be read and the rule tuned.
/// It does not overrule the coverage rule: on the held-out test it would not have changed one decision.
enum PasteSafety {
    struct Features: Equatable, Sendable {
        var coverageMin: Double = 1
        var coverageMean: Double = 1
        var unitsBelowHalf: Double = 0
        var units: Int = 0
        var stemRecall: Double = 1
        var stemNew: Double = 0
        var lengthRatio: Double = 1
        var contentDeleted: Double = 0
        var fillerShare: Double = 0
        var sourceWords: Int = 0

        var vector: [Double] {
            [coverageMin, coverageMean, unitsBelowHalf, log(Double(max(1, units))), stemRecall, stemNew,
             log(max(0.05, lengthRatio)), contentDeleted, fillerShare, log(Double(max(1, sourceWords)))]
        }
    }

    static let featureNames = ["coverage_min", "coverage_mean", "units_below_half", "log_units", "stem_recall",
                               "stem_new", "log_length_ratio", "content_deleted", "filler_share", "log_source_words"]

    static func features(source: String, output: String) -> Features {
        typealias G = WhisperNowContentGuard
        var f = Features()
        let sourceWords = G.words(source), outWords = G.words(output)
        f.sourceWords = sourceWords.count
        f.lengthRatio = Double(outWords.count) / Double(max(1, sourceWords.count))
        let outStems = G.contentStems(output), sourceStems = G.contentStems(source)
        if !sourceStems.isEmpty { f.stemRecall = Double(sourceStems.intersection(outStems).count) / Double(sourceStems.count) }
        if !outStems.isEmpty { f.stemNew = Double(outStems.subtracting(sourceStems).count) / Double(outStems.count) }
        let ratios = G.coverageUnits(source).map { unit -> Double in
            let stems = G.contentStems(unit)
            return Double(stems.intersection(outStems).count) / Double(max(1, stems.count))
        }
        f.units = ratios.count
        if !ratios.isEmpty {
            f.coverageMin = ratios.min()!
            f.coverageMean = ratios.reduce(0, +) / Double(ratios.count)
            f.unitsBelowHalf = Double(ratios.filter { $0 < G.coverageThreshold }.count) / Double(ratios.count)
        }
        let deleted = G.editReasons(source: source, output: output)
        f.contentDeleted = Double(deleted.filter { $0.reason == .content }.count) / Double(max(1, sourceWords.count))
        f.fillerShare = Double(G.fillerPositions(sourceWords).count) / Double(max(1, sourceWords.count))
        return f
    }

    // Logistic weights (raw features, intercept separate), fitted 21 Nov 2026 on 2,757 dev outputs that pass
    // the literal checks (labels against Wispr's references, scorer next-t5-v3/work/score_v3.py).
    // Held-out test (764 outputs): AUC 0.69, and at the threshold that keeps wrong accepts at or below the
    // old rule's it accepts exactly what the old rule accepts. So the score is reported, and the old rule
    // still decides: the score is not good enough to overrule it.
    static let intercept: Double = -0.9725358832089173
    static let weights: [Double] = [1.6191, 10.2743, 15.2308, 0.1473, -7.4101, -2.2389, 6.7762, 3.8285, 18.8397, -0.5082]
    static let threshold: Double = 0.35
    static let fitNote = "dev 2,757 / test 764 outputs; AUC 0.73 / 0.69; decisions unchanged on test"

    /// Probability that the output is safe to paste, or nil when the score is not available.
    static func probability(_ f: Features) -> Double? {
        guard weights.count == featureNames.count else { return nil }
        let z = zip(weights, f.vector).reduce(intercept) { $0 + $1.0 * $1.1 }
        return 1 / (1 + exp(-z))
    }

    /// The soft part of the guard: true when the output may be pasted on content coverage.
    /// The old rule (every sentence keeps half its content words); see the note on the weights.
    static func coverageAccepts(source: String, output: String) -> Bool {
        WhisperNowContentGuard.coverageRuleAccepts(source: source, output: output)
    }

    /// The decision with its score and the plain reason, for the referee and the trace.
    static func decide(source: String, output: String) -> (accept: Bool, probability: Double, reason: String) {
        let accept = coverageAccepts(source: source, output: output)
        let f = features(source: source, output: output)
        guard f.units > 0, let p = probability(f) else {
            return (accept, accept ? 0.9 : 0.1, accept ? "too short to score" : "a sentence lost too much")
        }
        if !accept { return (false, min(p, 0.5), "a sentence lost too much") }
        return (true, p, p >= threshold ? "safe to paste" : "kept, low score")
    }
}
