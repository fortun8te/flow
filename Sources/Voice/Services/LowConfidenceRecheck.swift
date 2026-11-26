import Foundation

/// Conservative tinynext pass after cleanup. Parakeet flags tokens below 0.6 confidence ("suspects");
/// for each flagged word this pass lists near-word alternatives from the lexicon, scores each one in its
/// spoken context with tinynext, and swaps only when an alternative beats the written word by a clear
/// margin. Names, capitalised mid-sentence words, acronyms, URLs and code, Flow's dictionary and product
/// terms, and non-English sentences are never touched. Without the lexicon or the model the text is
/// returned unchanged, so the rules pass still stands on its own.
enum LowConfidenceRecheck {

    struct Config: Equatable, Sendable {
        /// Nats: an alternative must beat the written word by at least this much in context.
        var margin: Float = 10
        /// Words of context on each side of the flagged word.
        var before = 10
        var after = 4
        /// Edit distance for alternatives of 6+ letters (5 and shorter always use 1).
        var maxDistance = 2
        var maxCandidates = 6
        /// Flagged words considered per dictation; the rest are left alone.
        var maxFlagged = 200
    }

    /// One flagged word and its best alternative. `delta` is the gain in nats over the written word.
    struct Decision: Equatable, Sendable {
        let start: Int
        let end: Int
        let original: String
        let replacement: String
        let delta: Float
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"[A-Za-z]+(?:['’][A-Za-z]+)?"#)
    private static let sentencePattern = try! NSRegularExpression(pattern: #"[^.!?\n]+[.!?]*"#)
    private static let skipPattern = try! NSRegularExpression(pattern:
        #"`[^`\n]*`|https?://\S+|www\.\S+|[\w.+-]+@[\w-]+(?:\.[\w-]+)+|(?<![\w])[~/][\w.\-/]+"#)

    /// Production entry point: lexicon and model must already be loaded (or are loaded when `wait`).
    static func recheck(_ text: String, suspects: [String], protectedTerms: [String] = [],
                        config: Config = Config(), wait: Bool = false) -> (text: String, changes: [Decision]) {
        guard !suspects.isEmpty,
              let lexicon = TypoRepair.shared.lexicon(wait: wait),
              let scorer = TinyNextScorer.shared.ready(wait: wait) else { return (text, []) }
        let found = decisions(text, suspects: suspects, protectedTerms: protectedTerms,
                              lexicon: lexicon, scorer: scorer, config: config)
        return apply(text, decisions: found, margin: config.margin)
    }

    /// Every flagged word with its best alternative and the gain, whatever the margin. Used by the
    /// production path (through `recheck`) and by the offline sweep that picks the margin on dev.
    static func decisions(_ text: String, suspects: [String], protectedTerms: [String] = [],
                          lexicon: TypoRepair.Lexicon, scorer: TinyNextScorer.Model,
                          config: Config = Config()) -> [Decision] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let flagged = Set(suspects.map { $0.lowercased() })
        guard !flagged.isEmpty else { return [] }
        var protectedKeys = Set(protectedTerms.map { $0.lowercased() })
        for entry in TypoRepair.productVocabulary { protectedKeys.insert(entry.term.lowercased()) }
        for (k, v) in TypoRepair.personalDictionary {
            protectedKeys.insert(k.lowercased()); protectedKeys.insert(v.lowercased())
        }
        let codeRanges = skipPattern.matches(in: text, range: whole).map(\.range)
        let sentences = sentencePattern.matches(in: text, range: whole).map(\.range)
        let words = wordPattern.matches(in: text, range: whole).map(\.range)

        func atSentenceStart(_ r: NSRange) -> Bool {
            var j = r.location - 1
            while j >= 0, ns.character(at: j) == 32 || ns.character(at: j) == 9 { j -= 1 }
            guard j >= 0 else { return true }
            return [".", "!", "?", ":", "\n"].contains(ns.substring(with: NSRange(location: j, length: 1)))
        }

        struct Job {
            let range: NSRange
            let word: String
            let candidates: [String]
            let contexts: [String]
        }
        var out: [Decision] = []
        var jobs: [Job] = []
        var batchCount = 0
        var considered = 0

        func flush() {
            guard !jobs.isEmpty else { return }
            let contexts = jobs.flatMap(\.contexts)
            let scores = scorer.score(contexts)
            if scores.count == contexts.count {
                var offset = 0
                for job in jobs {
                    let span = scores[offset..<(offset + job.candidates.count)]
                    if span.allSatisfy(\.isFinite),
                       let best = (1..<job.candidates.count).max(by: { span[offset + $0] < span[offset + $1] }) {
                        out.append(Decision(start: job.range.location, end: job.range.upperBound,
                                            original: job.word, replacement: job.candidates[best],
                                            delta: span[offset + best] - span[offset]))
                    }
                    offset += job.candidates.count
                }
            }
            jobs.removeAll(keepingCapacity: true)
            batchCount = 0
        }

        for (i, r) in words.enumerated() {
            if considered >= config.maxFlagged || Task.isCancelled { break }
            let word = ns.substring(with: r)
            let key = word.lowercased()
            guard flagged.contains(key), key.count >= 4, key.allSatisfy({ $0 >= "a" && $0 <= "z" }),
                  !protectedKeys.contains(key),
                  !codeRanges.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { continue }
            let starts = atSentenceStart(r)
            if word.first!.isUppercase && !starts { continue }          // a name in the middle of a sentence
            if word.count > 1 && word == word.uppercased() { continue } // an acronym
            if let s = sentences.first(where: { NSLocationInRange(r.location, $0) }),
               !RealWordFixer.LanguageGate.sentenceIsEnglish(ns.substring(with: s)) { continue }

            // Alternatives: lexicon words within the edit budget, cheapest keyboard cost first.
            let budget = key.count <= 5 ? 1 : config.maxDistance
            let pool = lexicon.trie.search(Array(key.utf8), maxDistance: budget)
                .filter { $0 != key && (lexicon.logFrequency[$0] ?? -99) > -13 && !protectedKeys.contains($0) }
                .sorted { TypoRepair.typoCost(key, $0) < TypoRepair.typoCost(key, $1) }
                .prefix(config.maxCandidates)
            guard !pool.isEmpty else { continue }

            let lo = words[max(0, i - config.before)].location
            let hi = words[min(words.count - 1, i + config.after)].upperBound
            let left = ns.substring(with: NSRange(location: lo, length: r.location - lo))
            let right = ns.substring(with: NSRange(location: r.upperBound, length: hi - r.upperBound))
            let candidates = [word] + pool.map { alt -> String in
                starts && word.first!.isUppercase ? alt.prefix(1).uppercased() + alt.dropFirst() : alt
            }
            // Bound temporary tensors; TinyNext runs these contexts together.
            if batchCount + candidates.count > 32 { flush() }
            jobs.append(Job(range: r, word: word, candidates: candidates,
                            contexts: candidates.map { left + $0 + right }))
            batchCount += candidates.count
            considered += 1
        }
        if !Task.isCancelled { flush() }
        return out
    }

    /// Applies the decisions whose gain clears `margin`, right to left so offsets stay valid.
    static func apply(_ text: String, decisions: [Decision], margin: Float) -> (text: String, changes: [Decision]) {
        let picked = decisions.filter { $0.delta >= margin && $0.replacement != $0.original }
        guard !picked.isEmpty else { return (text, []) }
        let mutable = NSMutableString(string: text)
        for d in picked.sorted(by: { $0.start > $1.start }) {
            mutable.replaceCharacters(in: NSRange(location: d.start, length: d.end - d.start), with: d.replacement)
        }
        return (mutable as String, picked.sorted { $0.start < $1.start })
    }
}
