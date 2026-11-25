import Foundation

/// Sound-alike words in dictation, read in context (22 Nov 2026): whether/weather, their/there/they're,
/// your/you're, its/it's, to/too, then/than, affect/effect, lose/loose. The recogniser hears the sound and
/// picks a spelling; tinynext scores the sentence with each spelling and the word changes only when another
/// spelling reads clearly better (`margin`, in nats). It runs after tinyfix (RealWordFixer), on what tinyfix
/// left.
///
/// Never touched: "two" (a number is never made or removed), names and capitalised words mid-sentence,
/// ALL CAPS, links, code, the user's dictionary, and sentences that are not clearly English. "to" is only
/// judged where "too" is plausible at all: before a clause ends or before much/many/late/... .
///
/// Learning: when Jordan fixes one of these himself (AutoDictionary, kind `.soundAlike`) and the same fix
/// went live, that one direction needs only `learnedMargin`.
enum SoundAlikeCheck {
    struct Config: Equatable, Sendable {
        var margin: Float = 5.5
        var learnedMargin: Float = 2.5
        var before = 12
        var after = 6
        var maxChecks = 40
    }

    struct Decision: Equatable, Sendable {
        let start: Int
        let end: Int
        let original: String
        let replacement: String
        let delta: Float
        let learned: Bool
    }

    static let groups: [[String]] = AutoDictionary.soundAlikeGroups

    /// Words "to" may be a "too" in front of.
    private static let tooHeads: Set<String> = [
        "much", "many", "late", "early", "big", "small", "long", "short", "far", "bad", "good", "hard", "fast",
        "slow", "high", "low", "often", "soon", "little", "few", "busy", "tired", "expensive", "cheap", "close",
        "complicated", "complex", "simple", "loud", "quiet", "dark", "bright", "heavy", "light", "slowly", "quickly",
    ]

    private static let wordPattern = try! NSRegularExpression(pattern: #"[A-Za-z]+(?:['’][A-Za-z]+)?"#)
    private static let sentencePattern = try! NSRegularExpression(pattern: #"[^.!?\n]+[.!?]*"#)
    private static let skipPattern = try! NSRegularExpression(pattern:
        #"`[^`\n]*`|https?://\S+|www\.\S+|[\w.+-]+@[\w-]+(?:\.[\w-]+)+|(?<![\w])[~/][\w.\-/]+"#)

    /// Production entry point. Without the model the text comes back unchanged (and loading starts).
    static func check(_ text: String, protectedTerms: [String] = [], learned: Set<String>? = nil,
                      config: Config = Config(), wait: Bool = false) -> (text: String, changes: [Decision]) {
        guard hasCandidates(text), let scorer = TinyNextScorer.shared.ready(wait: wait) else { return (text, []) }
        let found = decisions(text, protectedTerms: protectedTerms, learned: learned ?? AutoDictionary.shared.liveSoundAlikes(),
                              config: config, scorer: { scorer.score($0) })
        return apply(text, decisions: found, config: config)
    }

    static func hasCandidates(_ text: String) -> Bool {
        let lower = text.lowercased()
        return groups.joined().contains { word in word != "two" && word != "to" && lower.contains(word) }
            || lower.contains("to ") || lower.contains("to.") || lower.contains("to,")
    }

    /// Every judged word with its best other spelling and the gain, whatever the margin.
    static func decisions(_ text: String, protectedTerms: [String] = [], learned: Set<String> = [],
                          config: Config = Config(), scorer: ([String]) -> [Float]) -> [Decision] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let protectedKeys = Set(protectedTerms.map { $0.lowercased() })
        let skips = skipPattern.matches(in: text, range: whole).map(\.range)
        let sentences = sentencePattern.matches(in: text, range: whole).map(\.range)
        let words = wordPattern.matches(in: text, range: whole).map(\.range)

        func atSentenceStart(_ r: NSRange) -> Bool {
            var j = r.location - 1
            while j >= 0, ns.character(at: j) == 32 || ns.character(at: j) == 9 || ns.character(at: j) == 34 { j -= 1 }
            guard j >= 0 else { return true }
            return [".", "!", "?", ":", "\n"].contains(ns.substring(with: NSRange(location: j, length: 1)))
        }
        func clauseEndsAfter(_ r: NSRange) -> Bool {
            var j = r.upperBound
            while j < ns.length, ns.character(at: j) == 32 { j += 1 }
            guard j < ns.length else { return true }
            return [".", "!", "?", ",", ";", ":", "\n", ")"].contains(ns.substring(with: NSRange(location: j, length: 1)))
        }

        struct Job { let index: Int; let range: NSRange; let word: String; let options: [String]; let starts: Bool }
        var jobs: [Job] = []
        for (i, r) in words.enumerated() {
            if jobs.count >= config.maxChecks { break }
            let word = ns.substring(with: r)
            let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
            guard let group = groups.first(where: { $0.contains(key) }), key != "two",
                  !protectedKeys.contains(key),
                  !skips.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { continue }
            let starts = atSentenceStart(r)
            if word.first!.isUppercase && !starts { continue }
            if word.count > 1 && word == word.uppercased() { continue }
            if key == "to" {
                let next = i + 1 < words.count ? ns.substring(with: words[i + 1]).lowercased() : ""
                guard clauseEndsAfter(r) || tooHeads.contains(next) else { continue }
            }
            if let s = sentences.first(where: { NSLocationInRange(r.location, $0) }),
               !RealWordFixer.LanguageGate.sentenceIsEnglish(ns.substring(with: s)) { continue }
            let options = group.filter { $0 != key && $0 != "two" }.map { option -> String in
                starts && word.first!.isUppercase ? option.prefix(1).uppercased() + option.dropFirst() : option
            }
            guard !options.isEmpty else { continue }
            jobs.append(Job(index: i, range: r, word: word, options: options, starts: starts))
        }
        guard !jobs.isEmpty else { return [] }

        var texts: [String] = []
        var spans: [Range<Int>] = []
        for job in jobs {
            let lo = words[max(0, job.index - config.before)].location
            let hi = words[min(words.count - 1, job.index + config.after)].upperBound
            let left = ns.substring(with: NSRange(location: lo, length: job.range.location - lo))
            let right = ns.substring(with: NSRange(location: job.range.upperBound, length: hi - job.range.upperBound))
            let start = texts.count
            for candidate in [job.word] + job.options { texts.append(left + candidate + right) }
            spans.append(start..<texts.count)
        }
        let scores = scorer(texts)
        guard scores.count == texts.count else { return [] }
        var out: [Decision] = []
        for (job, span) in zip(jobs, spans) {
            let base = scores[span.lowerBound]
            let best = (1..<span.count).max { scores[span.lowerBound + $0] < scores[span.lowerBound + $1] }!
            let replacement = job.options[best - 1]
            let learned = learned.contains(AutoDictionary.key(job.word, replacement))
            out.append(Decision(start: job.range.location, end: job.range.upperBound, original: job.word,
                                replacement: replacement, delta: scores[span.lowerBound + best] - base, learned: learned))
        }
        return out
    }

    /// Applies the decisions that clear their margin, right to left so offsets stay valid.
    static func apply(_ text: String, decisions: [Decision], config: Config = Config()) -> (text: String, changes: [Decision]) {
        let picked = decisions.filter { $0.delta >= ($0.learned ? config.learnedMargin : config.margin) && $0.replacement != $0.original }
        guard !picked.isEmpty else { return (text, []) }
        let mutable = NSMutableString(string: text)
        for d in picked.sorted(by: { $0.start > $1.start }) {
            mutable.replaceCharacters(in: NSRange(location: d.start, length: d.end - d.start), with: d.replacement)
        }
        return (mutable as String, picked.sorted { $0.start < $1.start })
    }
}
