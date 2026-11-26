import Foundation

/// The last, deterministic word pass on every dictation, after the cleanup model (DOSE1, WhisperNow,
/// S1-mini, rules). Models sometimes leave hesitations in, or fail and fall back to the transcript
/// ("cleanup.whispernow trip failure:cancelled" on 21 Nov 2026 pasted "Uh meetings tab can be ...").
/// This pass makes the result fail-proof:
///
/// - um / uh / uhm / erm / ah, and Dutch eh / ehm / euh, always go, except when the words are being
///   talked about ("remove the ums and uhs", "the word um", "talking about ums and uh's").
/// - Comma-framed "like" and "you know" fillers go; "I like it", "you know what I mean" stay.
/// - Stutters go: "Why why is it" -> "Why is it", "I I'd" -> "I'd", a phrase said twice in a row.
/// - Model list markup (<ul><li>) becomes plain lines.
///
/// URLs, emails, paths and `code` are never touched. Numbers, names and negations are never removed:
/// only the listed filler tokens and exact repeats are dropped.
enum DictationFinalPass {

    /// The one shared final pass. Every path that produces dictated or polished text calls this, last:
    /// the cleanup model, the WhisperNow and rules fallbacks, the raw/rules-only text, the deadline partial,
    /// Option+1 and undo-after-cancel. Dictation that is only hesitations returns "" (nothing to paste, so
    /// the caller reports no speech); a hesitation is never pasted (22 Nov 2026).
    static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return outsideCode(in: text, applying: applyToProse)
    }

    private static func applyToProse(_ text: String) -> String {
        var result = plainLists(text)
        // A line ending ",." / ",!" (a greeting line "Hey Noor," that a later pass gave a full stop) keeps its comma.
        result = result.replacingOccurrences(of: #"(?m),[.!](?=[ \t]*$)"#, with: ",", options: .regularExpression)
        result = removeHesitations(result)
        result = removeFramedFillers(result)
        result = removeStutters(result)
        if result != text { result = tidy(result) }
        if !result.contains(where: { $0.isLetter || $0.isNumber }) {
            // Only hesitations (and the punctuation they left behind, "Uh, um." -> ".") were said: nothing to paste.
            // Text with no hesitation at all is kept as it was.
            return hasHesitation(text) ? "" : text
        }
        return result
    }

    /// True when the text has at least one hesitation token that is not a mention ("um" said as a hesitation).
    static func hasHesitation(_ text: String) -> Bool {
        classifiedFillers(text)?.contains { !$0.mention } ?? false
    }

    // MARK: - Protected spans

    private static let protectedPattern = try! NSRegularExpression(pattern:
        #"https?://\S+|www\.\S+|[\w.+-]+@[\w-]+(?:\.[\w-]+)+|(?<![\w])[~/][\w.\-/]+|\b[\w-]+\.(?:swift|py|js|ts|json|md|txt|html|css|sh|yml|yaml)\b"#,
        options: [.caseInsensitive])

    private static func protectedRanges(_ ns: NSString) -> [NSRange] {
        let text = ns as String
        return protectedPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            + codeSpan.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            + fencedCodeRanges(in: text).map { NSRange($0, in: text) }
    }

    private static func overlaps(_ range: NSRange, _ protected: [NSRange]) -> Bool {
        protected.contains { NSIntersectionRange($0, range).length > 0 }
    }

    /// A closing fence needs the same marker and at least the opening run's
    /// length. Keep an unfinished code block too; cleanup must not edit its
    /// contents while the user is still writing it.
    static func fencedCodeRanges(in text: String) -> [Range<String.Index>] {
        guard text.contains("```") || text.contains("~~~") else { return [] }
        var ranges: [Range<String.Index>] = []
        var fence: (start: String.Index, marker: Character, count: Int)?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let marker = trimmed.first, marker == "`" || marker == "~" else { continue }
            let count = trimmed.prefix(while: { $0 == marker }).count
            guard count >= 3 else { continue }
            let rest = trimmed.dropFirst(count)
            if let open = fence {
                if marker == open.marker && count >= open.count && rest.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    ranges.append(open.start..<line.endIndex)
                    fence = nil
                }
            } else if marker != "`" || !rest.contains("`") {
                fence = (line.startIndex, marker, count)
            }
        }
        if let fence { ranges.append(fence.start..<text.endIndex) }
        return ranges
    }

    /// Transform only prose, without placeholders that could collide with
    /// literal user text. This protects code from every pass, including HTML
    /// list conversion and capitalization after a filler was removed.
    private static func outsideCode(in text: String, applying transform: (String) -> String) -> String {
        var ranges = fencedCodeRanges(in: text)
        let ns = text as NSString
        for match in codeSpan.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text),
                  !ranges.contains(where: { $0.overlaps(range) }) else { continue }
            ranges.append(range)
        }
        guard !ranges.isEmpty else { return transform(text) }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var result = ""
        var cursor = text.startIndex
        for range in ranges {
            result += transform(String(text[cursor..<range.lowerBound]))
            result += text[range]
            cursor = range.upperBound
        }
        result += transform(String(text[cursor...]))
        return result
    }

    // MARK: - Hesitations

    /// Hesitation sounds only. Dutch "er" ("er is") and English "hmm"/"mhm" (they can answer) are not here.
    private static let hesitation = try! NSRegularExpression(pattern:
        #"(?<![\w'’-])(u+m+|u+h+m*|e+r+m+|a+h+m*|e+h+m*|e+u+h+|uhh?m+)(?![\w'’-])"#, options: [.caseInsensitive])

    /// Plural or possessive filler words are always a mention, never a hesitation.
    private static let mentionForm = try! NSRegularExpression(pattern:
        #"(?<![\w-])(?:u+m+s|u+h+s|u+h+m+s|e+h+m+s|a+h+s|u+m+['’]s|u+h+['’]s|e+r+s)(?![\w-])"#, options: [.caseInsensitive])

    /// "the word um", "say uh": always a mention.
    private static let strongLead: Set<String> = ["word", "words", "say", "says", "saying", "said", "woord", "zeg"]
    /// After "say/said/saying", a filler followed by a new clause is a hesitation: "I'm just saying um I already
    /// have it" (22 Nov 2026 replay), unlike "when I say um on purpose".
    private static let sayLead: Set<String> = ["say", "says", "saying", "said", "zeg"]
    private static let clauseStart: Set<String> = [
        "i", "i'm", "i’m", "i've", "i’ve", "i'd", "i’d", "we", "you", "he", "she", "they", "it", "it's", "it’s",
        "so", "and", "but", "like", "well", "yeah", "okay", "ok", "that", "this", "there", "ik", "je", "dat"
    ]
    /// "remove the um", "talking about uh": a mention only when no ordinary word follows
    /// ("the uh dictation history" is a hesitation).
    private static let weakLead: Set<String> = [
        "the", "an", "a", "no", "any", "those", "these", "remove", "removes", "removing", "drop", "strip",
        "keep", "filler", "fillers", "about", "de", "het", "geen"
    ]

    private struct Token { let range: NSRange; var mention: Bool; let isForm: Bool }

    static func removeHesitations(_ text: String) -> String {
        let ns = text as NSString
        guard let tokens = classifiedFillers(text) else { return text }
        let protected = protectedRanges(ns)
        let output = NSMutableString(string: text)
        for token in tokens.reversed() where !token.isForm && !token.mention && !overlaps(token.range, protected) {
            removeToken(token.range, in: output)
        }
        return output as String
    }

    /// Filler words that are being talked about ("the word um", "remove the ums"), lower-cased, in order.
    /// A cleanup that drops or changes one of these has changed what was said.
    static func fillerMentions(_ text: String) -> [String] {
        let ns = text as NSString
        return (classifiedFillers(text) ?? []).filter(\.mention).map { ns.substring(with: $0.range).lowercased() }
    }

    /// Every filler-shaped word, mention or not, lower-cased.
    static func fillerWords(_ text: String) -> [String] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        return (hesitation.matches(in: text, range: whole) + mentionForm.matches(in: text, range: whole))
            .map { ns.substring(with: $0.range).lowercased() }
    }

    /// True when `output` lost or changed a filler word that `source` talks about.
    static func dropsFillerMention(source: String, output: String) -> Bool {
        let mentioned = fillerMentions(source)
        guard !mentioned.isEmpty else { return false }
        var available = Dictionary(fillerWords(output).map { ($0, 1) }, uniquingKeysWith: +)
        for word in mentioned {
            guard let count = available[word], count > 0 else { return true }
            available[word] = count - 1
        }
        return false
    }

    /// Hesitation tokens and their mention flags, or nil when the text has no hesitation-shaped word.
    private static func classifiedFillers(_ text: String) -> [Token]? {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let hes = hesitation.matches(in: text, range: whole).map(\.range)
        let forms = mentionForm.matches(in: text, range: whole).map(\.range)
        guard !hes.isEmpty || !forms.isEmpty else { return nil }

        // Every filler-shaped word in order; plural/possessive forms are mentions from the start.
        var tokens = (hes.map { Token(range: $0, mention: false, isForm: false) }
                      + forms.map { Token(range: $0, mention: true, isForm: true) })
            .sorted { $0.range.location < $1.range.location }

        func previousWord(before location: Int) -> String? {
            let head = ns.substring(to: location)
            let trimmed = head.replacingOccurrences(of: #"[\s"“'‘]+$"#, with: "", options: .regularExpression)
            guard let word = trimmed.range(of: #"[\p{L}'’]+$"#, options: .regularExpression) else { return nil }
            return String(trimmed[word]).lowercased()
        }
        func quoted(_ r: NSRange) -> Bool {
            guard r.location > 0, r.location + r.length < ns.length else { return false }
            return "\"“'‘".contains(ns.substring(with: NSRange(location: r.location - 1, length: 1)))
                && "\"”'’".contains(ns.substring(with: NSRange(location: r.location + r.length, length: 1)))
        }
        func endsPhrase(_ r: NSRange) -> Bool {
            let tail = ns.substring(from: r.location + r.length)
            if tail.range(of: #"^[ \t]*(?:$|[.,!?;:)"”'’\n])"#, options: .regularExpression) != nil { return true }
            return tail.range(of: #"^[ \t]*(?:,[ \t]*)?(?:and|or|en|of)[ \t]+(?:u+m+|u+h+m*|e+h+m*|a+h+|e+r+m+)"#,
                              options: [.regularExpression, .caseInsensitive]) != nil
        }
        func nextWord(after r: NSRange) -> String? {
            let tail = ns.substring(from: r.location + r.length)
            guard let word = tail.range(of: #"^[ \t]*,?[ \t]*[\p{L}'’]+"#, options: .regularExpression) else { return nil }
            return String(tail[word]).trimmingCharacters(in: CharacterSet(charactersIn: " \t,")).lowercased()
        }
        for i in tokens.indices where !tokens[i].mention {
            let lead = previousWord(before: tokens[i].range.location) ?? ""
            if sayLead.contains(lead), !quoted(tokens[i].range),
               let next = nextWord(after: tokens[i].range), clauseStart.contains(next) { continue }
            if quoted(tokens[i].range) || strongLead.contains(lead)
                || (weakLead.contains(lead) && endsPhrase(tokens[i].range)) {
                tokens[i].mention = true
            }
        }
        // "the um and uh", "ums, uhs and ehms": a filler joined to a mentioned one is a mention too.
        let connector = try! NSRegularExpression(pattern: #"^[ \t]*(?:,[ \t]*)?(?:(?:and|or|en|of|plus)[ \t]+)?$"#,
                                                 options: [.caseInsensitive])
        func joined(_ a: NSRange, _ b: NSRange) -> Bool {
            let start = a.location + a.length
            guard b.location >= start else { return false }
            let gap = ns.substring(with: NSRange(location: start, length: b.location - start))
            guard !gap.isEmpty, gap.contains(where: { $0 == "," || $0.isLetter }) else { return false }
            return connector.firstMatch(in: gap, range: NSRange(location: 0, length: (gap as NSString).length)) != nil
        }
        var changed = true
        while changed {
            changed = false
            for i in tokens.indices.dropLast() where tokens[i].mention != tokens[i + 1].mention
                && joined(tokens[i].range, tokens[i + 1].range) {
                tokens[i].mention = true
                tokens[i + 1].mention = true
                changed = true
            }
        }

        return tokens
    }

    /// Removes the word at `r` with the punctuation and spacing it carried, keeping the sentence intact:
    /// "Uh, the slider" -> "The slider", "so, um, we" -> "so, we", "okay um the" -> "okay the".
    private static func removeToken(_ r: NSRange, in s: NSMutableString) {
        let length = s.length
        func char(_ i: Int) -> String { i >= 0 && i < length ? s.substring(with: NSRange(location: i, length: 1)) : "" }
        let tokenWasCapital = char(r.location).rangeOfCharacter(from: .uppercaseLetters) != nil
        // Trailing: commas, ellipsis and a following space.
        var end = r.location + r.length
        var trailingComma = false
        while end < length, ",…".contains(char(end)) || (char(end) == "." && char(end + 1) == "." ) {
            if char(end) == "," { trailingComma = true }
            end += 1
        }
        // A lone "Uh." or "Um?" as a whole sentence.
        if !trailingComma, end < length, ".?!".contains(char(end)) {
            var j = r.location - 1
            while j >= 0, char(j) == " " { j -= 1 }
            if j < 0 || ".!?\n\r\u{0085}\u{2028}\u{2029}".contains(char(j)) { end += 1 }
        }
        // Leading: the space before, and a comma before when the token also had one after.
        var start = r.location
        while start > 0, char(start - 1) == " " || char(start - 1) == "\t" { start -= 1 }
        let atSentenceStart = start == 0 || ".!?\n\r\u{0085}\u{2028}\u{2029}:;\"“(".contains(char(start - 1))
        if atSentenceStart {
            // Drop following spaces instead, so the next word moves into place.
            start = r.location
            while end < length, char(end) == " " { end += 1 }
        } else if trailingComma, char(start - 1) == "," {
            // "so, um, we" -> "so, we": keep the first comma, drop " um,".
        } else if trailingComma {
            // "and um, we" -> "and we"
        } else if end < length, ".!?".contains(char(end)) {
            // "then um." -> "then."
        }
        s.replaceCharacters(in: NSRange(location: start, length: end - start), with: "")
        // Capitalise the word that now starts the sentence.
        if atSentenceStart, start < s.length, tokenWasCapital {
            let first = s.substring(with: NSRange(location: start, length: 1))
            if first.rangeOfCharacter(from: .lowercaseLetters) != nil {
                s.replaceCharacters(in: NSRange(location: start, length: 1), with: first.uppercased())
            }
        }
    }

    // MARK: - Comma-framed fillers

    /// Only the forms that cannot carry meaning: ", like," / "Like, " at a sentence start /
    /// ", you know," / ", you know." / "You know, " at a sentence start.
    private static let framed: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #",[ \t]+(?:like|you know)[ \t]*,[ \t]+"#, options: [.caseInsensitive]), " "),
        (try! NSRegularExpression(pattern: #"[ \t]*,[ \t]+(?:you know|yk)(?=[.!?]|$)"#, options: [.caseInsensitive]), ""),
        (try! NSRegularExpression(pattern: #"(?m)(^|[.!?][ \t]+)(?:Like|You know|So like)[ \t]*,[ \t]+(\p{Ll})"#, options: []), "$1$2")
    ]

    static func removeFramedFillers(_ text: String) -> String {
        var result = text
        for (rx, template) in framed {
            let ns = result as NSString
            let protected = protectedRanges(ns)
            let out = NSMutableString(string: result)
            for m in rx.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
            where !overlaps(m.range, protected) {
                let replacement = rx.replacementString(for: m, in: result, offset: 0, template: template)
                out.replaceCharacters(in: m.range, with: replacement)
            }
            result = out as String
        }
        // Sentence-start forms leave the next word lowercase: capitalise it.
        return capitaliseSentenceStarts(result, onlyAfterEdit: text)
    }

    private static func capitaliseSentenceStarts(_ text: String, onlyAfterEdit original: String) -> String {
        guard text != original else { return text }
        let rx = try! NSRegularExpression(pattern: #"(?m)(^|[.!?][ \t]+)(\p{Ll})"#)
        let ns = text as NSString
        let out = NSMutableString(string: text)
        // Only capitalise starts that were not lowercase in the original (some styles keep lowercase).
        let originalLowerStarts = Set(rx.matches(in: original, range: NSRange(location: 0, length: (original as NSString).length))
            .map { (original as NSString).substring(from: $0.range(at: 2).location).prefix(24) })
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let tail = ns.substring(from: m.range(at: 2).location).prefix(24)
            guard !originalLowerStarts.contains(tail) else { continue }
            out.replaceCharacters(in: m.range(at: 2), with: ns.substring(with: m.range(at: 2)).uppercased())
        }
        return out as String
    }

    // MARK: - Stutters and repeated words

    /// Doubles that are real English or Dutch: "that that", "had had", "is is", "bye bye", "very very",
    /// "no no", number words, negations.
    private static let keepDoubles: Set<String> = [
        "that", "had", "is", "bye", "yada", "blah", "no", "nee", "yes", "ja", "yeah", "very", "really", "so",
        "ha", "haha", "la", "knock", "chop", "now", "well", "many", "more", "far", "again", "over", "round",
        "on", "out", "through", "go", "hey", "hi", "ok", "okay", "wow", "oh", "not", "never", "dont", "don't",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "hundred", "thousand",
        "tick", "tock", "boom", "bang", "beep", "ding", "dong", "goody", "pretty", "super", "too", "heel",
        "tegen", "de", "die", "dat", "wee", "poo", "pee", "boo", "oui", "choo", "tsk", "mm", "ooh", "aww", "yum",
        "he", "hee", "ho", "na", "nah", "mama", "papa", "dada", "baba", "bla", "night", "aye", "cha", "tut", "fully",
        "much", "big", "best", "great", "please", "same", "little", "bit", "long", "way", "step", "side", "back", "wait"
    ]

    private static let doubledWord = try! NSRegularExpression(pattern:
        #"(?<![\w'’-])([\p{L}]+)([ \t]+)\1(?![\w'’-])"#, options: [.caseInsensitive])
    /// "I I'd", "we we're", "it it's": a pronoun said, then said again as a contraction.
    private static let pronounRestart = try! NSRegularExpression(pattern:
        #"(?<![\w'’-])(i|you|we|they|he|she|it|there)[ \t]+(\1['’][\p{L}]+)(?![\w'’-])"#, options: [.caseInsensitive])

    static func removeStutters(_ text: String) -> String {
        var result = text
        // Pronoun restarts first.
        do {
            let ns = result as NSString
            let protected = protectedRanges(ns)
            let out = NSMutableString(string: result)
            for m in pronounRestart.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
            where !overlaps(m.range, protected) {
                var contraction = ns.substring(with: m.range(at: 2))
                let first = ns.substring(with: m.range(at: 1))
                if first.first?.isUppercase == true { contraction = contraction.prefix(1).uppercased() + contraction.dropFirst() }
                out.replaceCharacters(in: m.range, with: contraction)
            }
            result = out as String
        }
        // Single repeated words; run twice for "the the the".
        for _ in 0..<2 {
            let ns = result as NSString
            let protected = protectedRanges(ns)
            let out = NSMutableString(string: result)
            for m in doubledWord.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
            where !overlaps(m.range, protected) {
                let word = ns.substring(with: m.range(at: 1))
                guard !keepDoubles.contains(word.lowercased()) else { continue }
                // Both capitalised is a name or a title ("Bora Bora", "Sam Sam"): keep it.
                let second = ns.substring(with: NSRange(location: m.range.location + m.range.length - m.range(at: 1).length,
                                                        length: m.range(at: 1).length))
                if word != "I", word.first?.isUppercase == true, second.first?.isUppercase == true { continue }
                out.replaceCharacters(in: m.range, with: word)
            }
            result = out as String
        }
        return removeRepeatedPhrases(result)
    }

    /// "when should we paint when should we paint fences" -> "when should we paint fences".
    /// Only an exact phrase of 3-6 different words said twice in a row inside one sentence, with no
    /// pause mark between ("this and this and this" and "those icons: those icons" stay).
    static func removeRepeatedPhrases(_ text: String) -> String {
        outsideCode(in: text, applying: removeRepeatedProsePhrases)
    }

    private static func removeRepeatedProsePhrases(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for line in text.split(whereSeparator: \.isNewline) {
            result += text[cursor..<line.startIndex]
            var words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            func key(_ w: String) -> String {
                w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
            }
            var changed = true
            var guardCount = 0
            while changed && guardCount < 8 {
                changed = false
                guardCount += 1
                outer: for k in stride(from: 6, through: 3, by: -1) where words.count >= 2 * k {
                    for i in 0...(words.count - 2 * k) {
                        let a = words[i..<(i + k)], b = words[(i + k)..<(i + 2 * k)]
                        // Inside one sentence: no sentence end inside the first copy.
                        guard !a.dropLast().contains(where: { $0.last.map { ".!?".contains($0) } ?? false }),
                              !(a.last?.last.map { ".!?".contains($0) } ?? false),
                              a.allSatisfy({ !$0.isEmpty }),
                              !a.allSatisfy({ $0.first?.isUppercase == true }),
                              Set(a.map(key)).count > 1,
                              !(a.last?.last.map { ",:;".contains($0) } ?? false),
                              zip(a, b).allSatisfy({ key($0) == key($1) }),
                              a.contains(where: { $0.rangeOfCharacter(from: .decimalDigits) == nil }) else { continue }
                        var replacement = Array(b)
                        if let firstA = a.first, firstA.first?.isUppercase == true, var firstB = replacement.first {
                            firstB = firstB.prefix(1).uppercased() + firstB.dropFirst()
                            replacement[0] = firstB
                        }
                        words.replaceSubrange(i..<(i + 2 * k), with: replacement)
                        changed = true
                        break outer
                    }
                }
            }
            result += words.joined(separator: " ")
            cursor = line.endIndex
        }
        result += text[cursor...]
        return result
    }

    // MARK: - Lists from model markup

    private static let listBlock = try! NSRegularExpression(pattern: #"(?is)<(ul|ol)\b[^>]*>(.*?)</\1>"#)
    private static let listItem = try! NSRegularExpression(pattern: #"(?is)<li\b[^>]*>(.*?)</li>"#)

    /// `<ul><li>a</li><li>b</li></ul>` -> "- a\n- b"; `<ol>` -> "1. a\n2. b". Text pasted into a plain
    /// field must never show tags.
    static func plainLists(_ text: String) -> String {
        guard text.range(of: "<li", options: .caseInsensitive) != nil
            || text.range(of: "<br", options: .caseInsensitive) != nil else { return text }
        var result = text
        let ns = result as NSString
        let out = NSMutableString(string: result)
        for block in listBlock.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
            let ordered = ns.substring(with: block.range(at: 1)).lowercased() == "ol"
            let body = ns.substring(with: block.range(at: 2)) as NSString
            let items = listItem.matches(in: body as String, range: NSRange(location: 0, length: body.length))
                .map { body.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { continue }
            let lines = items.enumerated().map { ordered ? "\($0.offset + 1). \($0.element)" : "- \($0.element)" }
            var replacement = lines.joined(separator: "\n")
            // Keep the list on its own lines.
            let before = block.range.location > 0 ? ns.substring(to: block.range.location) : ""
            let after = ns.substring(from: block.range.location + block.range.length)
            if !before.isEmpty && !before.hasSuffix("\n") { replacement = "\n" + replacement }
            if !after.isEmpty && !after.hasPrefix("\n") { replacement += "\n" }
            out.replaceCharacters(in: block.range, with: replacement)
        }
        result = out as String
        result = result.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        return result
    }

    // MARK: - Tidy

    private static let codeSpan = try! NSRegularExpression(pattern: #"(?s)(?<!`)(`+)(?!`)(.*?)(?<!`)\1(?!`)"#)

    /// Spacing rules never touch code spans. Found 21 Nov 2026: "`ls  -la`" lost a space.
    private static func tidy(_ text: String) -> String {
        outsideCode(in: text, applying: tidySpacing)
    }

    private static func tidySpacing(_ text: String) -> String {
        var r = text
        // Only interior prose spaces are normalized. Trailing spaces may be
        // Markdown hard breaks; indentation and whitespace-only lines belong
        // to the user's layout, even when a filler elsewhere was removed.
        r = r.replacingOccurrences(of: #"(?<=\S)[ \t]{2,}(?=\S)"#, with: " ", options: .regularExpression)
        r = r.replacingOccurrences(of: #"(?<=\S)[ \t]+([,.!?;:])"#, with: "$1", options: .regularExpression)
        r = r.replacingOccurrences(of: #",{2,}"#, with: ",", options: .regularExpression)
        r = r.replacingOccurrences(of: #",([.!?])"#, with: "$1", options: .regularExpression)
        r = r.replacingOccurrences(of: #"(?m)^([ \t]*),[ \t]*"#, with: "$1", options: .regularExpression)
        return r
    }

    // MARK: - Broken sentence ends from the recogniser

    private static let brokenStop = try! NSRegularExpression(pattern:
        #"(?<![\d.]|\b(?:etc|vs|e\.g|i\.e|mr|mrs|ms|dr|st|no|approx|a\.m|p\.m|inc|ltd|jr|sr))\.[ \t]+(?=\p{Ll})"#)

    /// Parakeet sometimes puts a full stop inside a phrase ("four experiments. at once",
    /// "the dictation thing. perfected"). A stop followed by a lowercase function word is joined
    /// back before the formatter capitalises it. Runs on the raw transcript.
    static func joinBrokenSentences(_ raw: String) -> String {
        let ns = raw as NSString
        let protected = protectedRanges(ns)
        let out = NSMutableString(string: raw)
        for m in brokenStop.matches(in: raw, range: NSRange(location: 0, length: ns.length)).reversed()
        where !overlaps(m.range, protected) {
            out.replaceCharacters(in: m.range, with: " ")
        }
        return out as String
    }
}
