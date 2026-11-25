import Foundation

/// Opt+1's referee. A model edit is never taken or thrown away whole: it is aligned with what was typed
/// (word groups, so splits and joins line up: "figu rei tout" <-> "Figure it out") and each group is
/// judged on its own. Spelling, casing, apostrophes, split and joined words pass; a changed number,
/// link, name or negation, an added or dropped word, or a reworded phrase goes back to what was typed.
/// The deterministic repair then finishes what the model left ("Odenst" -> "doesn't").
enum OptOneReferee {
    struct Result: Equatable {
        let text: String
        /// Model groups taken back to the typed words, with a short reason each.
        let reverted: [String]
        let modelGroupsKept: Int
    }

    // MARK: Entry points

    /// The fast path on its own: deterministic repair of the typed text.
    static func deterministic(_ source: String, protectedTerms: [String], wait: Bool = false,
                              deadline: ContinuousClock.Instant? = nil) -> String {
        let repaired = TypoRepair.shared.repair(source, protectedTerms: protectedTerms, conservative: false,
                                                wait: wait, deadline: deadline).text
        return finalize(TypoRepair.capitalizeSentences(repaired), source: source) ?? source
    }

    /// The model's edit, judged group by group, then the conservative repair of what is left.
    static func finish(source: String, model: String, protectedTerms: [String], wait: Bool = false,
                       deadline: ContinuousClock.Instant? = nil) -> Result {
        let merged = merge(source: source, candidate: model, protectedTerms: protectedTerms)
        let post = TypoRepair.shared.repair(merged.text, protectedTerms: protectedTerms, conservative: true,
                                            wait: wait, deadline: deadline, typedText: source).text
        let text = finalize(TypoRepair.capitalizeSentences(post), source: source)
            ?? finalize(TypoRepair.capitalizeSentences(merged.text), source: source) ?? source
        return Result(text: text, reverted: merged.reverted, modelGroupsKept: merged.modelGroupsKept)
    }

    /// Restores the typed outer whitespace and checks that no link or number went missing.
    static func finalize(_ text: String, source: String) -> String? {
        let lead = String(source.prefix { $0.isWhitespace })
        let trail = String(source.reversed().prefix { $0.isWhitespace }.reversed())
        let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return nil }
        let result = lead + core + trail
        for token in protectedTokens(source) where !result.contains(token) { return nil }
        return result
    }

    /// Links and anything with a digit, as typed. These must come through untouched.
    static func protectedTokens(_ text: String) -> [String] {
        let ns = text as NSString
        return protectedTokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:)\"'")) }
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isLetter) }
    }
    private static let protectedTokenPattern = try! NSRegularExpression(pattern: #"https?://\S+|www\.\S+|\d+(?:[.,:]\d+)*"#)

    // MARK: Alignment

    private static let wordPattern = try! NSRegularExpression(pattern: #"https?://\S+|www\.\S+|[\p{L}\p{N}]+(?:['’][\p{L}]+)*"#)

    private struct Word {
        let text: String
        let range: NSRange
        let letters: String
    }

    private static func words(_ s: String) -> [Word] {
        let ns = s as NSString
        return wordPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            let t = ns.substring(with: m.range)
            return Word(text: t, range: m.range,
                        letters: t.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: ""))
        }
    }

    /// Groups of (source a..<b, candidate c..<d): exact matches anchor, the gaps between are aligned with
    /// up to three words a side by keyboard cost.
    private static func align(_ s: [Word], _ t: [Word]) -> [(Int, Int, Int, Int)] {
        let n = s.count, m = t.count
        // Longest common subsequence of exact (case- and apostrophe-free) words.
        var lcs = [Int](repeating: 0, count: (n + 1) * (m + 1))
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i * (m + 1) + j] = s[i].letters == t[j].letters
                        ? lcs[(i + 1) * (m + 1) + j + 1] + 1
                        : max(lcs[(i + 1) * (m + 1) + j], lcs[i * (m + 1) + j + 1])
                }
            }
        }
        var anchors: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if s[i].letters == t[j].letters { anchors.append((i, j)); i += 1; j += 1 }
            else if lcs[(i + 1) * (m + 1) + j] >= lcs[i * (m + 1) + j + 1] { i += 1 } else { j += 1 }
        }
        var groups: [(Int, Int, Int, Int)] = []
        var si = 0, tj = 0
        for (ai, aj) in anchors + [(n, m)] {
            if ai > si || aj > tj { groups += alignGap(s, si, ai, t, tj, aj) }
            if ai < n { groups.append((ai, ai + 1, aj, aj + 1)) }
            si = ai + 1; tj = aj + 1
        }
        return groups
    }

    private static func alignGap(_ s: [Word], _ s0: Int, _ s1: Int, _ t: [Word], _ t0: Int, _ t1: Int) -> [(Int, Int, Int, Int)] {
        let n = s1 - s0, m = t1 - t0
        if n == 0 || m == 0 { return [(s0, s1, t0, t1)] }
        if n > 40 || m > 40 { return [(s0, s1, t0, t1)] }
        let inf = Float.greatestFiniteMagnitude
        var d = [Float](repeating: inf, count: (n + 1) * (m + 1))
        var back = [(Int, Int)](repeating: (0, 0), count: (n + 1) * (m + 1))
        d[0] = 0
        for i in 0...n {
            for j in 0...m {
                let here = d[i * (m + 1) + j]
                guard here < inf else { continue }
                for a in 0...3 {
                    for b in 0...3 {
                        guard a + b > 0, i + a <= n, j + b <= m, !((a == 0 || b == 0) && a + b > 1) else { continue }
                        let cost: Float
                        if a == 0 || b == 0 {
                            cost = 6
                        } else {
                            let src = s[(s0 + i)..<(s0 + i + a)], tgt = t[(t0 + j)..<(t0 + j + b)]
                            let ls = src.map(\.letters).joined(), lt = tgt.map(\.letters).joined()
                            cost = ls == lt ? 0 : min(TypoRepair.typoCost(src.map(\.letters).joined(separator: " "),
                                                                          tgt.map(\.letters).joined(separator: " ")), 9)
                                + Float(a + b - 2)
                        }
                        let k = (i + a) * (m + 1) + j + b
                        if here + cost < d[k] { d[k] = here + cost; back[k] = (i, j) }
                    }
                }
            }
        }
        var groups: [(Int, Int, Int, Int)] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            let (pi, pj) = back[i * (m + 1) + j]
            groups.append((s0 + pi, s0 + i, t0 + pj, t0 + j))
            i = pi; j = pj
        }
        return groups.reversed()
    }

    // MARK: Judging a group

    private static let negations: Set<String> = ["not", "no", "never", "nothing", "nobody", "none", "nor", "cannot", "without"]
    private static func isNegation(_ w: String) -> Bool {
        let l = w.lowercased().replacingOccurrences(of: "’", with: "'")
        return negations.contains(l) || l.hasSuffix("n't") || ["dont", "doesnt", "didnt", "cant", "wont", "isnt", "arent",
            "wasnt", "werent", "havent", "hasnt", "shouldnt", "wouldnt", "couldnt"].contains(l)
    }
    private static let expansions: [String: Set<String>] = ["u": ["you"], "ur": ["your", "you're"], "im": ["i'm"], "ive": ["i've"]]

    static func groupVerdict(_ src: [String], _ tgt: [String], protectedTerms: [String] = []) -> (ok: Bool, reason: String) {
        func letters(_ ws: [String]) -> String {
            ws.map { $0.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "") }.joined()
        }
        if src.isEmpty && tgt.isEmpty { return (true, "") }
        let ls = letters(src), lt = letters(tgt)
        if ls == lt { return (true, "case") }
        let sl = src.joined(separator: " ").lowercased().replacingOccurrences(of: "’", with: "'")
        let tl = tgt.joined(separator: " ").lowercased().replacingOccurrences(of: "’", with: "'")
        if let allowed = expansions[sl], allowed.contains(tl) { return (true, "expand") }
        func hasDigitOrLink(_ w: String) -> Bool { w.contains(where: \.isNumber) || w.hasPrefix("http") || w.hasPrefix("www.") }
        for w in src where hasDigitOrLink(w) && !tgt.contains(w) { return (false, "number or link") }
        for w in tgt where hasDigitOrLink(w) && !src.contains(w) { return (false, "new number") }
        if src.isEmpty { return (false, "added words") }
        if tgt.isEmpty {
            if src.count == 1, src[0].count == 1, !["a", "i"].contains(src[0].lowercased()) { return (true, "stray letter") }
            return (false, "dropped words")
        }
        let userKeys = TypoRepair.shared.userKeyMap(protectedTerms)
        // A name or dictionary entry typed right stays as typed.
        for w in src where w.count >= 3 {
            let k = TypoRepair.key(w)
            if userKeys[k] != nil, !tgt.contains(where: { TypoRepair.key($0) == k }) { return (false, "dictionary word") }
        }
        let cost = TypoRepair.typoCost(src.joined(separator: " "), tgt.joined(separator: " "))
        let length = Float(max(ls.count, 1))
        var garbled = false
        var targetKnown = true
        if let lex = TypoRepair.shared.lexicon(wait: false) {
            garbled = src.contains { !TypoRepair.shared.isKnown($0, lexicon: lex, userKeys: userKeys) }
            targetKnown = tgt.allSatisfy { TypoRepair.shared.isKnown($0, lexicon: lex, userKeys: userKeys) || $0.first?.isUppercase == true }
        }
        var limit = garbled && targetKnown ? 2.5 + 0.9 * length : 1.6 + 0.55 * length
        if !garbled, src.count == tgt.count { limit = min(limit, 3.5) }
        guard cost <= limit else { return (false, String(format: "reworded %.1f/%.1f", cost, limit)) }
        if src.filter(isNegation).count != tgt.filter(isNegation).count, cost > 2.5 + 0.25 * length {
            return (false, "negation")
        }
        return (true, String(format: "typo %.1f", cost))
    }

    // MARK: Merge

    static func merge(source: String, candidate raw: String, protectedTerms: [String] = []) -> Result {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let sw = words(source), tw = words(candidate)
        guard !tw.isEmpty, !sw.isEmpty else { return Result(text: source, reverted: ["empty"], modelGroupsKept: 0) }
        let src = source as NSString, cand = candidate as NSString
        let groups = align(sw, tw)
        var out = ""
        var reverted: [String] = []
        var kept = 0
        var candCursor = 0   // utf16 offset in candidate already emitted
        // Text before the first word: the candidate's, unless it added words there (it cannot: no words).
        if let first = tw.first { out += cand.substring(to: first.range.location); candCursor = first.range.location }
        for (i0, i1, j0, j1) in groups {
            let sWords = sw[i0..<i1].map(\.text), tWords = tw[j0..<j1].map(\.text)
            let verdict = groupVerdict(sWords, tWords, protectedTerms: protectedTerms)
            // Separator before this group: the candidate's, with the typed line breaks.
            var sep = ""
            if j1 > j0 { sep = cand.substring(with: NSRange(location: candCursor, length: tw[j0].range.location - candCursor)) }
            else { sep = " " }
            if i1 > i0, i0 > 0 {
                let gapStart = sw[i0 - 1].range.location + sw[i0 - 1].range.length
                let gap = src.substring(with: NSRange(location: gapStart, length: sw[i0].range.location - gapStart))
                let breaks = gap.filter { $0 == "\n" }.count
                if breaks > 0, !sep.contains("\n") {
                    sep = sep.trimmingCharacters(in: .whitespaces) + String(repeating: "\n", count: breaks)
                } else if breaks == 0, sep.contains("\n") {
                    sep = sep.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
                    if sep.trimmingCharacters(in: .whitespaces).isEmpty { sep = " " }
                }
            }
            if i0 == 0, j0 == 0 { sep = "" }
            var body: String
            if verdict.ok || (j1 > j0 && i1 == i0 && false) {
                body = j1 > j0 ? cand.substring(with: NSRange(location: tw[j0].range.location,
                    length: tw[j1 - 1].range.location + tw[j1 - 1].range.length - tw[j0].range.location)) : ""
                if j1 > j0 { kept += 1 }
                if j1 == j0 { sep = "" }   // a stray letter dropped
            } else if i1 - i0 == j1 - j0, i1 - i0 > 1 {
                // Same number of words: judge each pair on its own.
                var pieces: [String] = []
                for k in 0..<(i1 - i0) {
                    let pair = groupVerdict([sw[i0 + k].text], [tw[j0 + k].text], protectedTerms: protectedTerms)
                    pieces.append(pair.ok ? tw[j0 + k].text : sw[i0 + k].text)
                    if pair.ok { kept += 1 }
                }
                // Keep the candidate's separators between the pair words.
                body = ""
                for k in 0..<pieces.count {
                    if k > 0 {
                        let a = tw[j0 + k - 1].range, b = tw[j0 + k].range
                        body += cand.substring(with: NSRange(location: a.location + a.length, length: b.location - a.location - a.length))
                    }
                    body += pieces[k]
                }
                reverted.append(verdict.reason + ": " + sWords.joined(separator: " ") + " -> " + tWords.joined(separator: " ") + " (per word)")
            } else {
                body = i1 > i0 ? src.substring(with: NSRange(location: sw[i0].range.location,
                    length: sw[i1 - 1].range.location + sw[i1 - 1].range.length - sw[i0].range.location)) : ""
                if i1 == i0 { sep = "" }   // added words dropped
                reverted.append(verdict.reason + ": " + sWords.joined(separator: " ") + " -> " + tWords.joined(separator: " "))
            }
            out += sep + body
            if j1 > j0 { candCursor = tw[j1 - 1].range.location + tw[j1 - 1].range.length }
        }
        out += cand.substring(from: candCursor)
        out = out.replacingOccurrences(of: #"(?<=\S) {2,}(?=\S)"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: " \n", with: "\n").replacingOccurrences(of: " ,", with: ",")
        return Result(text: out, reverted: reverted, modelGroupsKept: kept)
    }
}
