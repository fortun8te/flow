import Foundation
import NaturalLanguage

/// Content guard for the WhisperNow tuned cleanup model.
///
/// A line-for-line port of `scripts/pc/wn_metrics.py` (`words`, `filler_positions`, `spoken_values`,
/// `invented_numbers`, `edit_reasons`, the negation count of `score_row`) and `scripts/pc/dev/guard.py`
/// (`trips`, `strip_hesitations`). The cleanup is kept unless it drops a non-filler content word with no
/// explainable reason (filler, repetition/restart, self-correction cue, light function-word smoothing),
/// loses a negation, or writes a number the speaker never said. `difflib.SequenceMatcher` (no junk,
/// autojunk off) is ported too, so the Swift guard trips on exactly the rows the Python guard trips on.
enum WhisperNowContentGuard {
    enum Trip: Equatable, Sendable {
        case empty
        case cut([String])
        case negation
        case number
        /// v2 guard: a name, link or email from the transcript is missing or changed.
        case name
        case link
        /// v2 guard: a sentence lost too much of its content.
        case coverage

        /// Telemetry label: never contains transcript words.
        var label: String {
            switch self {
            case .empty: return "empty"
            case .cut: return "cut"
            case .negation: return "negation"
            case .number: return "number"
            case .name: return "name"
            case .link: return "link"
            case .coverage: return "coverage"
            }
        }
    }

    // MARK: Word lists (wn_metrics.py)

    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "ah", "like", "basically",
                                       "literally", "mm", "mhm"]
    static let fillerPhrases = ["you know", "i mean", "sort of", "kind of"]
    static let soft: Set<String> = ["so", "just", "really", "actually", "okay", "ok", "yeah", "right", "well", "oh",
                                    "anyway", "and", "but", "then", "now", "pretty", "very", "stuff", "whatever"]
    static let droppable: Set<String> = ["a", "an", "the", "and", "so", "to", "of", "in", "on", "at", "for", "is", "are",
                                         "was", "were", "be", "that", "it", "as", "by", "then", "there", "it's", "that's",
                                         "this"]
    static let cues: Set<String> = ["no", "sorry", "wait", "actually", "mean", "rather", "scratch", "instead",
                                    "correction", "not"]
    static let negations: Set<String> = ["not", "never", "don't", "doesn't", "didn't", "can't", "cannot", "won't",
                                         "isn't", "aren't", "wasn't", "weren't", "shouldn't", "wouldn't", "couldn't",
                                         "haven't", "hasn't", "nothing", "none", "without"]
    static let grammar: Set<String> = droppable.union(["or", "but", "with", "if", "than", "about", "from", "does", "do",
        "did", "many", "much", "am", "has", "have", "had", "will", "would", "can", "could", "should", "its", "these",
        "those", "there's", "into", "onto", "i", "i'm", "me", "my", "we", "you", "your", "they", "also", "up", "going"])
    static let units: [String: Int] = ["zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "first": 1,
        "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
        "tenth": 10, "twelfth": 12, "thirteenth": 13, "fifteenth": 15, "twentieth": 20, "thirtieth": 30]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
                                      "seventy": 70, "eighty": 80, "ninety": 90]
    static let scales: [String: Int] = ["hundred": 100, "thousand": 1000, "k": 1000, "million": 1_000_000,
                                        "billion": 1_000_000_000]
    static let expansions: [String: Set<String>] = ["gonna": ["going", "to"], "wanna": ["want", "to"],
        "gotta": ["got", "to"], "kinda": ["kind", "of"], "sorta": ["sort", "of"], "lemme": ["let", "me"],
        "gimme": ["give", "me"], "ok": ["okay"], "okay": ["ok"], "alright": ["all", "right"], "cause": ["because"],
        "till": ["until"], "yeah": ["yes"], "yep": ["yes"]]
    static let spokenSymbols: [String: String] = ["slash": "/", "backslash": "\\", "underscore": "_", "dot": ".",
        "dash": "-", "hyphen": "-", "colon": ":", "percent": "%", "hashtag": "#", "hash": "#", "ampersand": "&",
        "tilde": "~", "asterisk": "*", "equals": "=", "plus": "+"]
    /// Words that make a transcript "noise only" (score_row's `noise_only`): an EMPTY reply is right for these.
    static let noiseWords: Set<String> = fillers.union(["oh", "hm", "huh"])

    // MARK: Guard (guard.py)

    /// nil = keep the model's output. `output` is the raw reply ("EMPTY" counts as empty).
    ///
    /// v2 (21 Nov 2026). The strict guard below rejected 38% of the cleanup model's outputs on the
    /// 216-row dev set, mostly long or list-shaped dictations where one dropped "there's", "first" or
    /// "five" counted as a cut, so Flow pasted the raw transcript (fillers, no paragraphs). This guard
    /// checks what matters literally and the rest by coverage (after the T5P guard):
    /// - links and emails must match exactly;
    /// - every number in the transcript must survive (as digits or words), and none may be invented;
    /// - names (capitalised mid-sentence words) must survive, allowing a spelling fix ("Quen" -> "Qwen");
    /// - no negation may be lost ("I don't know" said as a filler may go);
    /// - every sentence (or 14-word stretch) with at least 3 content words keeps at least half of them.
    /// Dropped function words, list markers and reordering into a list no longer trip it.
    static func trip(source: String, output: String) -> Trip? {
        if let hard = hardTrip(source: source, output: output) { return hard }
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // The soft part: did every sentence keep enough of its content? A calibrated score
        // (PasteSafety) when it applies, else the old rule (each sentence keeps half its content words).
        return PasteSafety.coverageAccepts(source: source, output: out) ? nil : .coverage
    }

    /// The literal checks only: empty, links, numbers, names, negations, language. nil = none failed.
    static func hardTrip(source: String, output: String) -> Trip? {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty || out == "EMPTY" { return .empty }
        if linkTokens(source) != linkTokens(out) { return .link }
        let deleted = editReasons(source: source, output: out)
        let excused = Set(deleted.filter { $0.reason == .correction || $0.reason == .repeat }.map(\.word))
        let sourceDigits = digitParts(source), outputDigits = digitParts(out)
        for (part, count) in sourceDigits where (outputDigits[part] ?? 0) < count && !excused.contains(part) {
            return .number
        }
        let spokenSource = spokenNumberForm(source)
        if !inventedNumbers(source: spokenSource, output: out).isEmpty { return .number }
        let outputValues = spokenValues(out)
        for run in cardinalRuns(spokenSource) where compose(run).isDisjoint(with: outputValues) { return .number }
        let outWords = Set(words(out))
        for name in names(in: source) where !nameSurvives(name, in: outWords) && !excused.contains(name) { return .name }
        let idk = #"(?i)\bi\s+don['’]?t\s+know\b"#
        let negSource = replace(idk, in: source, with: " "), negOutput = replace(idk, in: out, with: " ")
        if negationsLost(source: negSource, output: negOutput,
                         deleted: editReasons(source: negSource, output: negOutput)) > 0 { return .negation }
        if languageChanged(source: source, output: out) { return .coverage }
        return nil
    }

    /// The old coverage rule: every sentence (or 14-word stretch) with 3+ content words keeps half of them.
    static func coverageRuleAccepts(source: String, output: String) -> Bool {
        let outStems = contentStems(output)
        for unit in coverageUnits(source) {
            let stems = contentStems(unit)
            if Double(stems.intersection(outStems).count) / Double(stems.count) < coverageThreshold { return false }
        }
        return true
    }

    static let coverageThreshold = 0.5

    /// Long-dictation loss guard (22 Nov 2026). A cleanup that keeps under 85% of the source words for a
    /// source of 40+ words has dropped content. On the 296-case bench, 13 of 118 long outputs fell under 85%,
    /// and the coverage rule passed one 126-word case that lost a whole sentence and its closing clause.
    static let shortenedRatio = 0.85
    static let shortenedMinimumWords = 40

    static func shortened(source: String, output: String) -> Bool {
        let sourceCount = words(source).count
        guard sourceCount >= shortenedMinimumWords else { return false }
        return Double(words(output).count) < shortenedRatio * Double(sourceCount)
    }

    /// Cleanup never translates: a clearly Dutch sentence must not come back as English or German.
    static func languageChanged(source: String, output: String) -> Bool {
        guard words(source).count >= 3 else { return false }
        if words(source).count < 6 { return DictationLanguage.germanDrift(source: source, output: output) }
        func dominant(_ text: String) -> (NLLanguage, Double)? {
            let r = NLLanguageRecognizer()
            r.processString(text)
            return r.languageHypotheses(withMaximum: 1).first.map { ($0.key, $0.value) }
        }
        // A few words turned German is a half translation even when the whole still reads as Dutch.
        if DictationLanguage.germanDrift(source: source, output: output) { return true }
        guard let (from, p) = dominant(source), p >= 0.8, let (to, q) = dominant(output), q >= 0.8 else { return false }
        return from != to
    }

    /// The strict guard, a line-for-line port of guard.py (kept for parity tests and comparison).
    static func strictTrip(source: String, output: String) -> Trip? {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty || out == "EMPTY" { return .empty }
        let deleted = editReasons(source: source, output: out)
        let unexplained = deleted.filter { $0.reason == .content }.map(\.word)
        if !unexplained.isEmpty { return .cut(unexplained) }
        if negationsLost(source: source, output: out, deleted: deleted) > 0 { return .negation }
        if !inventedNumbers(source: source, output: out).isEmpty { return .number }
        return nil
    }

    /// True when the transcript holds nothing but hesitation sounds (the case an EMPTY reply is trained for).
    static func isNoiseOnly(_ source: String) -> Bool {
        let w = words(source)
        return !w.isEmpty && w.allSatisfy(noiseWords.contains)
    }

    /// The last-resort fallback: the transcript with only clear hesitation sounds removed.
    static func stripHesitations(_ source: String) -> String {
        // A transcript that talks about a filler ("the word um") keeps it: this regex cannot tell a mention apart.
        if !DictationFinalPass.fillerMentions(source).isEmpty { return capitalisingLines(source) }
        // Spaces and tabs only: line and paragraph breaks survive the fallback (21 Nov 2026).
        var text = replace(#"(?i)(?:,[ \t]*)?\b(?:um+|uh+|uhm|erm|hmm+)\b[,.]?[ \t]*"#, in: source, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = replace(#"[ \t]{2,}"#, in: text, with: " ")
        text = replace(#"[ \t]+\n"#, in: text, with: "\n")
        text = replace(#"\n[ \t]+"#, in: text, with: "\n")
        guard !text.isEmpty else { return source }
        return capitalisingLines(text)
    }

    /// Every line starts with a capital, as the first one does (a removed "uh" often began it).
    static func capitalisingLines(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            guard let first = line.first else { return line }
            return first.uppercased() + line.dropFirst()
        }.joined(separator: "\n")
    }

    // MARK: v2 guard helpers

    static let coverageStop: Set<String> = Set("""
        the and for that this with you your are was were have has had not but just like also really very then than
        them they their there here what when where which who why how can could would should will shall about into onto from
        some any all more most much many make made sure want need get got yeah okay its it's i'm i've we're you're don't
        because so if or of to in on at by be is am an as do does did it me my we us our he she his her him one two
        etc bro idk lol thing things stuff whatever kind sort maybe probably actually basically literally pretty quite
        gonna wanna gotta lets let's well still even way bit lot little now right oh hey yo ok first second third
        there's that's what's i'll i'd we'll you'll it'll um uh uhm ehm erm hmm know mean
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    static func contentStems(_ text: String) -> Set<String> {
        Set(words(text).filter { w in
            w.count >= 3 && !coverageStop.contains(w) && units[w] == nil && tens[w] == nil && scales[w] == nil
                && !w.contains(where: \.isNumber)
        }.map { String($0.prefix(5)) })
    }

    /// Sentences, lines and clauses after ";"; an unpunctuated run-on is cut into 14-word stretches.
    static func coverageUnits(_ source: String) -> [String] {
        var units: [String] = []
        for part in split(source, on: #"(?<=[.!?])\s+|\n+|;\s+"#) {
            let ws = part.split(whereSeparator: \.isWhitespace)
            if ws.count > 28 {
                for start in stride(from: 0, to: ws.count, by: 14) {
                    units.append(ws[start..<min(ws.count, start + 14)].joined(separator: " "))
                }
            } else {
                units.append(part)
            }
        }
        return units.filter { contentStems($0).count >= 3 }
    }

    static func linkTokens(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for raw in matches(#"(?i)https?://\S+|www\.\S+|[\w.+-]+@[\w-]+(?:\.[\w-]+)+"#, in: text) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,);!?")).lowercased()
            counts[token, default: 0] += 1
        }
        return counts
    }

    /// Every run of digits, outside links, with list markers ("1. ") and thousands commas removed:
    /// "50 80" and "50/80", "V 4.1" and "V4.1" compare equal.
    static func digitParts(_ text: String) -> [String: Int] {
        var t = replace(#"(?i)https?://\S+|www\.\S+|[\w.+-]+@[\w-]+(?:\.[\w-]+)+"#, in: text, with: " ")
        t = replace(#"(?m)^\s*\d+[.)]\s"#, in: t, with: "")
        t = replace(#"(?<=\d),(?=\d{3}\b)"#, in: t, with: "")
        var counts: [String: Int] = [:]
        for part in matches(#"\d+"#, in: t) { counts[part, default: 0] += 1 }
        return counts
    }

    /// Hesitations out and "hundred and sixty" joined, so "sixty um four" reads 64 and
    /// "two hundred and sixty" reads 260.
    static func spokenNumberForm(_ text: String) -> String {
        let noHesitation = replace(#"(?i)\b(?:u+m+|u+h+m*|e+r+m+|e+h+m*|hmm+)\b[,.]?\s*"#, in: text, with: " ")
        return replace(#"(?i)\b(hundred|thousand|million|billion)\s+and\b"#, in: noHesitation, with: "$1")
    }

    /// Runs of spoken number words that hold a real cardinal ("five", "twenty one"). "one", "oh" and
    /// ordinals alone are not required: they are often a pronoun or a list marker.
    static func cardinalRuns(_ text: String) -> [[String]] {
        let weak: Set<String> = ["oh", "one", "zero"]
        var runs: [[String]] = [], current: [String] = []
        func required(_ w: String) -> Bool {
            (units[w] != nil && !weak.contains(w) && !w.hasSuffix("th") && !["first", "second", "third"].contains(w))
                || tens[w] != nil
        }
        for w in words(text) + ["<end>"] {
            if required(w) || scales[w] != nil || (!current.isEmpty && units[w] != nil) {
                current.append(w)
            } else {
                if current.contains(where: required) { runs.append(current) }
                current = []
            }
        }
        return runs
    }

    /// Capitalised words inside a sentence, when the transcript has real casing.
    static func names(in source: String) -> Set<String> {
        guard source != source.lowercased() else { return [] }
        let skip = coverageStop.union(fillers).union(soft).union(["i", "i'm", "i'd", "i'll", "i've"])
        var out = Set<String>()
        let ns = source as NSString
        for m in regex(#"\b([A-Z][\w'’-]*)"#).matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1))
            let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            guard let last = before.last, !".!?\n:\"“".contains(last) else { continue }
            let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
            if skip.contains(key) { continue }
            out.insert(key)
        }
        return out
    }

    static func nameSurvives(_ name: String, in outWords: Set<String>) -> Bool {
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "'" }).map(String.init).filter { $0 != "s" && !$0.isEmpty }
        return parts.allSatisfy { part in
            outWords.contains(part) || outWords.contains { w in
                (part.count >= 4 && sameStem(part, w)) || (part.count >= 3 && closeSpelling(part, w))
            }
        }
    }

    /// Same first letter and one edit (two for words of five letters or more): a spelling fix
    /// ("Quen" -> "Qwen"), not a different word ("Lark" is not "has").
    static func closeSpelling(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        let allowed = Swift.min(x.count, y.count) >= 5 ? 2 : 1
        guard y.count >= 3, let fx = x.first, fx == y.first, abs(x.count - y.count) <= allowed else { return false }
        var d = Array(0...y.count)
        for i in 1...x.count {
            var row = [i]
            for j in 1...y.count {
                row.append(Swift.min(d[j] + 1, row[j - 1] + 1, d[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)))
            }
            d = row
        }
        return (d.last ?? 99) <= allowed
    }

    // MARK: wn_metrics.py port

    enum Reason: String { case filler, symbol, `repeat`, correction, soft, content }

    struct Deletion: Equatable {
        let index: Int
        let word: String
        let reason: Reason
    }

    static func words(_ text: String) -> [String] {
        matches(#"[\w'’]+"#, in: text).map { $0.lowercased().replacingOccurrences(of: "’", with: "'") }
    }

    static func fillerPositions(_ tokens: [String]) -> Set<Int> {
        var hits = Set(tokens.indices.filter { fillers.contains(tokens[$0]) })
        for phrase in fillerPhrases {
            let n = phrase.split(separator: " ").count
            guard tokens.count >= n else { continue }
            for i in 0...(tokens.count - n) where tokens[i..<(i + n)].joined(separator: " ") == phrase {
                hits.formUnion(i..<(i + n))
            }
        }
        return hits
    }

    static func negationsLost(source: String, output: String, deleted: [Deletion]) -> Int {
        let s = words(source), o = words(output)
        let isNeg: (String) -> Bool = { negations.contains($0) || $0.hasSuffix("n't") }
        let droppedOK = Set(deleted.filter { $0.reason == .repeat || $0.reason == .filler }.map(\.index))
        let negIn = s.indices.filter { isNeg(s[$0]) && !droppedOK.contains($0) }.count
        return max(0, negIn - o.filter(isNeg).count)
    }

    static func editReasons(source: String, output: String) -> [Deletion] {
        let s = words(source), o = words(output)
        let fillerSet = fillerPositions(s)
        var deleted: [Deletion] = []
        for op in SequenceMatcher(s, o).opcodes() where op.tag != .equal {
            let gone = Array(s[op.i1..<op.i2]), new = Array(o[op.j1..<op.j2])
            if op.tag == .replace {
                let joinedA = gone.joined(), joinedB = new.joined()
                let sameJoined = joinedA == joinedB
                    || joinedA.replacingOccurrences(of: "'", with: "") == joinedB.replacingOccurrences(of: "'", with: "")
                let numberRewrite = gone.allSatisfy(numberish) && new.allSatisfy(isDigitToken)
                let expansion = gone.contains { g in Set(new).isSubset(of: (expansions[g] ?? []).union([g])) }
                let stem = new.count == 1 && gone.count <= 2
                    && gone.allSatisfy { sameStem($0, new[0]) || droppable.contains($0) || fillers.contains($0) }
                    && gone.contains { sameStem($0, new[0]) }
                if sameJoined || numberRewrite || expansion || symbolJoin(gone, new) || stem { continue }
            }
            if gone.isEmpty { continue }
            let afterEnd = min(s.count, op.i2 + max(8, gone.count + 4))
            let after = Array(s[op.i2..<afterEnd])
            let nearby = Set(s[max(0, op.i1 - gone.count - 12)..<op.i1]).union(after)
            let window = Set(s[max(0, op.i1 - 3)..<min(s.count, op.i2 + 3)])
            let restart = after.prefix(3).contains(gone[0]) || gone.allSatisfy { after.contains($0) }
            for (k, w) in gone.enumerated() {
                let i = op.i1 + k
                let reason: Reason
                if fillerSet.contains(i) { reason = .filler }
                else if let symbol = spokenSymbols[w], output.contains(symbol) { reason = .symbol }
                else if nearby.contains(w) || restart { reason = .repeat }
                else if !window.isDisjoint(with: cues) { reason = .correction }
                else if soft.contains(w) || droppable.contains(w) { reason = .soft }
                else { reason = .content }
                deleted.append(Deletion(index: i, word: w, reason: reason))
            }
        }
        return deleted
    }

    static func sameStem(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let a = Array(a), b = Array(b)
        if min(a.count, b.count) >= 4 && (a.hasSuffixArray(b) || b.hasSuffixArray(a)) { return true }
        var n = 0
        while n < min(a.count, b.count) && a[n] == b[n] { n += 1 }
        return (n >= 3 && n >= min(a.count, b.count) - 1) || (n >= 4 && Double(n) >= 0.6 * Double(max(a.count, b.count)))
    }

    static func numberish(_ w: String) -> Bool {
        units[w] != nil || tens[w] != nil || scales[w] != nil
            || ["and", "point", "by", "percent", "o'clock", "number"].contains(w) || isAllDigits(w)
    }

    static func symbolJoin(_ spoken: [String], _ written: [String]) -> Bool {
        let a = spoken.filter { spokenSymbols[$0] == nil && $0 != "point" }
            .map { w -> String in
                if let u = units[w] { return String(u) }
                if let t = tens[w] { return String(t) }
                return w
            }.joined()
        let b = replace(#"[_./:\\-]"#, in: written.joined(), with: "")
        return !a.isEmpty && a == b
    }

    // MARK: Numbers

    static func spokenValues(_ text: String) -> Set<Int> {
        var values = Set<Int>()
        for match in matches(#"\d+(?:[.,:/]\d+)*"#, in: text) {
            for part in split(match.replacingOccurrences(of: ",", with: ""), on: #"[.,:/]"#) where !part.isEmpty {
                if let v = Int(part) { values.insert(v) }
            }
            let joined = replace(#"\D"#, in: match, with: "")
            if !joined.isEmpty && joined.count < 12, let v = Int(joined) { values.insert(v) }
        }
        var run: [String] = []
        for token in words(text) + ["<end>"] {
            if units[token] != nil || tens[token] != nil || scales[token] != nil {
                run.append(token)
            } else if !run.isEmpty {
                values.formUnion(compose(run))
                run = []
            }
        }
        return values
    }

    static func compose(_ run: [String]) -> Set<Int> {
        var out = Set<Int>(), parts: [Int] = [], current = 0, total = 0
        for token in run {
            if let value = units[token] {
                out.insert(value)
                if 20 <= current && current < 100 && current % 10 == 0 && value < 10 {
                    current += value
                } else {
                    if current != 0 { parts.append(current) }
                    current = value
                }
            } else if let value = tens[token] {
                out.insert(value)
                if current != 0 { parts.append(current) }
                current = value
            } else if let scale = scales[token] {
                current = mul(current == 0 ? 1 : current, scale)
                total = add(total, current)
                out.insert(total)
                current = 0
            }
        }
        if current != 0 { parts.append(current) }
        out.formUnion(parts)
        if total != 0 { out.insert(add(total, (parts.last.map { $0 < 1000 ? $0 : 0 }) ?? 0)) }
        for (a, b) in zip(parts, parts.dropFirst()) { out.insert(add(mul(a, 100), b)) }
        return out
    }

    static func inventedNumbers(source: String, output: String) -> [String] {
        let values = spokenValues(source)
        let layoutFree = replace(#"(?m)^(\s*)\d+[.)]\s"#, in: output, with: "$1")
        var bad: [String] = []
        for raw in matches(#"(?i)\d+(?:[.,:/]\d+)*(?:st|nd|rd|th|k|%)?"#, in: layoutFree) {
            let core = replace(#"(?i)(st|nd|rd|th|k|%)$"#, in: raw, with: "")
            let parts = split(core.replacingOccurrences(of: ",", with: ""), on: #"[.,:/]"#)
                .filter(isAllDigits).compactMap { Int($0) }
            let joined = replace(#"\D"#, in: core, with: "")
            let joinedOK = !joined.isEmpty && joined.count < 12 && Int(joined).map(values.contains) == true
            let partsOK = !parts.isEmpty && parts.allSatisfy(values.contains)
            if !(joinedOK || partsOK) { bad.append(raw) }
        }
        return bad
    }

    // MARK: Helpers

    private static func isDigitToken(_ w: String) -> Bool { fullMatch(#"[\d.,:/%]+\w{0,2}"#, w) }

    private static func isAllDigits(_ w: String) -> Bool {
        !w.isEmpty && w.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private static func mul(_ a: Int, _ b: Int) -> Int {
        let (r, o) = a.multipliedReportingOverflow(by: b); return o ? Int.max : r
    }

    private static func add(_ a: Int, _ b: Int) -> Int {
        let (r, o) = a.addingReportingOverflow(b); return o ? Int.max : r
    }

    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexLock = NSLock()

    private static func regex(_ pattern: String) -> NSRegularExpression {
        regexLock.lock(); defer { regexLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        // Patterns are compile-time constants; a failure here is a programming error caught by the tests.
        let compiled = try! NSRegularExpression(pattern: pattern)
        regexCache[pattern] = compiled
        return compiled
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        let ns = text as NSString
        return regex(pattern).matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func fullMatch(_ pattern: String, _ text: String) -> Bool {
        let ns = text as NSString
        guard let m = regex(pattern).firstMatch(in: text, options: [.anchored], range: NSRange(location: 0, length: ns.length)) else { return false }
        return m.range.length == ns.length
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        let ns = text as NSString
        return regex(pattern).stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    private static func split(_ text: String, on pattern: String) -> [String] {
        let ns = text as NSString
        var pieces: [String] = [], start = 0
        for m in regex(pattern).matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        pieces.append(ns.substring(from: start))
        return pieces
    }
}

private extension Array where Element == Character {
    func hasSuffixArray(_ suffix: [Character]) -> Bool {
        suffix.count <= count && Array(self[(count - suffix.count)...]) == suffix
    }
}

// MARK: - difflib.SequenceMatcher (isjunk=None, autojunk=False)

struct SequenceMatcher {
    enum Tag { case equal, replace, delete, insert }
    struct Opcode: Equatable { let tag: Tag; let i1: Int; let i2: Int; let j1: Int; let j2: Int }

    private let a: [String]
    private let b: [String]
    private let b2j: [String: [Int]]

    init(_ a: [String], _ b: [String]) {
        self.a = a; self.b = b
        var map: [String: [Int]] = [:]
        for (j, element) in b.enumerated() { map[element, default: []].append(j) }
        b2j = map
    }

    func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        if alo < ahi {
            for i in alo..<ahi {
                var newj2len: [Int: Int] = [:]
                for j in b2j[a[i]] ?? [] {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (j2len[j - 1] ?? 0) + 1
                    newj2len[j] = k
                    if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
                }
                j2len = newj2len
            }
        }
        // No junk: the non-junk extension loops of difflib.
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] { besti -= 1; bestj -= 1; bestsize += 1 }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] { bestsize += 1 }
        return (besti, bestj, bestsize)
    }

    func matchingBlocks() -> [(Int, Int, Int)] {
        var queue = [(0, a.count, 0, b.count)]
        var blocks: [(Int, Int, Int)] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = findLongestMatch(alo, ahi, blo, bhi)
            if k > 0 {
                blocks.append((i, j, k))
                if alo < i && blo < j { queue.append((alo, i, blo, j)) }
                if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
            }
        }
        blocks.sort { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2) }
        var i1 = 0, j1 = 0, k1 = 0
        var collapsed: [(Int, Int, Int)] = []
        for (i2, j2, k2) in blocks {
            if i1 + k1 == i2 && j1 + k1 == j2 { k1 += k2 }
            else {
                if k1 > 0 { collapsed.append((i1, j1, k1)) }
                i1 = i2; j1 = j2; k1 = k2
            }
        }
        if k1 > 0 { collapsed.append((i1, j1, k1)) }
        collapsed.append((a.count, b.count, 0))
        return collapsed
    }

    func opcodes() -> [Opcode] {
        var i = 0, j = 0
        var answer: [Opcode] = []
        for (ai, bj, size) in matchingBlocks() {
            let tag: Tag?
            if i < ai && j < bj { tag = .replace }
            else if i < ai { tag = .delete }
            else if j < bj { tag = .insert }
            else { tag = nil }
            if let tag { answer.append(Opcode(tag: tag, i1: i, i2: ai, j1: j, j2: bj)) }
            i = ai + size; j = bj + size
            if size > 0 { answer.append(Opcode(tag: .equal, i1: ai, i2: i, j1: bj, j2: j)) }
        }
        return answer
    }
}
