import Foundation

/// Conservative anchors for changes that are difficult to undo after polishing.
/// This is not a general semantic equivalence test. Uncertain cases fall back to input.
public enum MeaningIntegrity {
    public static func preservesMeaning(original: String, candidate: String) -> Bool {
        negationCount(original) == negationCount(candidate)
            && quantities(original) == quantities(candidate)
    }

    /// Same meaning check for a dictation with a spoken correction ("the 14th, no sorry the 15th",
    /// "it's not the evening, no wait, the morning"). A retracted negation or quantity may be
    /// dropped, because the correction replaces it. Nothing new may be added: a negation or
    /// quantity in the candidate must already be in the original.
    public static func preservesMeaningAfterCorrection(original: String, candidate: String) -> Bool {
        negationCount(candidate) <= negationCount(original)
            && Set(quantities(candidate)).isSubset(of: Set(quantities(original)))
    }

    /// Hard negation guard. Every negation the speaker said after their last correction marker
    /// must still be in the candidate. Negations before a marker may be retracted, because the
    /// correction replaces them. A filler "I mean" is a marker too, so it cannot unlock a dropped
    /// "don't": the rule is about where the negation sits, not about which marker was heard.
    public static func keepsNegations(original: String, candidate: String) -> Bool {
        let text = original.replacingOccurrences(of: "’", with: "'")
        let kept: String
        if let end = Sanitizer.lastCorrectionCueEnd(in: text) {
            kept = (text as NSString).substring(from: end)
        } else {
            kept = text
        }
        return negationCount(candidate) >= verbalNegationCount(kept)
    }

    /// Negations that negate a verb or a clause. A contrastive "not" ("the morning one not the evening")
    /// has no auxiliary before it and a determiner after it, so it is a correction, not a negation to keep.
    private static func verbalNegationCount(_ text: String) -> Int {
        let normalized = text.replacingOccurrences(of: "’", with: "'")
        let ns = normalized as NSString
        let auxiliaries: Set<String> = ["do", "does", "did", "is", "are", "was", "were", "be", "will", "would", "can",
                                        "could", "should", "must", "have", "has", "had", "am", "may", "might", "shall"]
        let determiners: Set<String> = ["the", "a", "an", "this", "that", "my", "your", "his", "her", "its", "our", "their", "one", "ones"]
        var count = 0
        for match in negation.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: match.range.location).lowercased()
                .split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map(String.init) ?? ""
            let after = ns.substring(from: match.range.location + match.range.length).lowercased()
                .split(whereSeparator: { !$0.isLetter && $0 != "'" }).first.map(String.init) ?? ""
            if !auxiliaries.contains(before), determiners.contains(after) { continue }
            count += 1
        }
        return count
    }

    /// Selected (typed) text. The numbers and units must match exactly, as in dictation.
    public static func preservesQuantities(original: String, candidate: String) -> Bool {
        quantities(original) == quantities(candidate)
    }

    /// Typed shorthand and a small set of contextual typos carry the same negation as
    /// their expanded forms. Compare both sides equally, without borrowing polarity
    /// from uncertainty shorthand to negate an unrelated request.
    public static func selectedNegationsKept(original: String, candidate: String) -> Bool {
        let originalProse = withoutSelectedLiterals(original)
        let before = canonicalSelectedNegations(originalProse)
        let after = canonicalSelectedNegations(withoutSelectedLiterals(candidate))
        guard negationCount(before) == negationCount(after) else { return false }
        let containedShorthand = uncertaintyShorthand.firstMatch(
            in: originalProse, range: NSRange(originalProse.startIndex..., in: originalProse)) != nil
        return !containedShorthand || uncertaintyCount(after) >= uncertaintyCount(before)
    }

    /// Speech cleanup may remove a restart cue such as "no, sorry". A new
    /// negation can reverse a request and needs evidence from the transcript.
    static func introducesNegation(original: String, candidate: String) -> Bool {
        let before = canonicalSelectedNegations(withoutSelectedLiterals(original))
        let after = canonicalSelectedNegations(withoutSelectedLiterals(candidate))
        return negationCount(after) > negationCount(before)
    }

    /// The canonical form is for safety comparisons only. Leave names, links, and code
    /// as written so callers can still check their exact spelling.
    public static func canonicalSelectedNegations(_ text: String, keepShorthand: Bool = false) -> String {
        let literals = selectedLiterals.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        let normalized = NSMutableString(string: text)
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        for match in selectedNegationTypos.matches(in: text, range: range).reversed() {
            guard let tokenRange = (1..<match.numberOfRanges).map({ match.range(at: $0) })
                    .first(where: { $0.location != NSNotFound }) else { continue }
            guard !literals.contains(where: { NSIntersectionRange($0, tokenRange).length > 0 }),
                  let spelling = typedNegationSpellings[source.substring(with: tokenRange)] else { continue }
            if keepShorthand, ["idk", "idek", "dunno", "w/out", "w/o", "wout"].contains(source.substring(with: tokenRange)) {
                continue
            }
            normalized.replaceCharacters(in: tokenRange, with: spelling)
        }
        return normalized as String
    }

    private static let typedNegationSpellings = [
        "idk": "I don't know", "idek": "I don't even know", "dunno": "don't know",
        "w/out": "without", "w/o": "without", "wout": "without",
        "coesnt": "doesn't", "dosent": "doesn't", "doens't": "doesn't",
        "doens’t": "doesn't", "doesn t": "doesn't",
        "dnt": "don't", "don t": "don't", "didn t": "didn't", "no": "know",
        "isn t": "isn't", "can t": "can't", "wont": "won't",
        "neit": "niet", "nie": "niet"
    ]

    // Match exactly one replaceable token. Context distinguishes typos from
    // proper names, abbreviations, and dialect. The original case is intentional.
    private static let selectedNegationTypos = try! NSRegularExpression(pattern:
        #"(?<![\w./@-])(?:(idk|idek|dunno|w/out|w/o|wout)"#
        + #"|(?i:he|she|it|this|that)[ \t]+(coesnt|dosent|doens['’]t|doesn t|isn t)"#
        + #"|(?i:i|you|we|they)[ \t]+(dnt|don t)"#
        + #"|(?i:i|you|we|they|he|she|it)[ \t]+(didn t|can t|wont)"#
        + #"|(?i:i|you|we|they)[ \t]+(?i:don['’]?t)[ \t]+(no)(?=[ \t]+(?i:if|whether|what|when|where|who|why|how)\b|[.!?]?[ \t]*(?:\n|$))"#
        + #"|(?i:het|dit|dat|is|was|ben|wordt|kan|wil|weet)[ \t]+(neit|nie))(?![\w/@-])"#
    )

    private static let selectedLiterals = try! NSRegularExpression(
        pattern: #"`[^`]+`|(?i)\b(?:\w+://|www\.)\S+|[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}|(?<![\w.])(?:~/|/|\.\.?/)\S+"#
    )

    private static func withoutSelectedLiterals(_ text: String) -> String {
        selectedLiterals.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                   withTemplate: " ")
    }

    private static let uncertaintyShorthand = try! NSRegularExpression(
        pattern: #"(?<![\w./@-])(?:idk|idek|dunno)(?![\w/@-])"#
    )

    private static let uncertainty = try! NSRegularExpression(
        pattern: #"(?i)\b(?:(?:don'?t|do\s+not)\s+(?:even\s+)?know|not\s+(?:even\s+)?(?:sure|certain))\b"#
    )

    private static func uncertaintyCount(_ text: String) -> Int {
        let normalized = text.replacingOccurrences(of: "’", with: "'")
        return uncertainty.numberOfMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
    }

    private static let negation = try! NSRegularExpression(
        pattern: #"(?i)\b(?:not|no|never|none|neither|nor|cannot|can't|cant|won't|wont|don't|dont|doesn't|doesnt|didn't|didnt|isn't|isnt|aren't|arent|wasn't|wasnt|weren't|werent|couldn't|couldnt|shouldn't|shouldnt|wouldn't|wouldnt|haven't|havent|hasn't|hasnt|hadn't|hadnt|mustn't|mustnt|needn't|neednt|ain't|aint|nothing|nobody|nowhere|without|niet|geen|nooit|niets|niks|niemand|nergens|zonder)\b"#
    )

    private static func negationCount(_ text: String) -> Int {
        let normalized = text.replacingOccurrences(of: "’", with: "'")
        return negation.numberOfMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
    }

    private static let numberWords: [String: String] = [
        "zero":"0", "one":"1", "two":"2", "three":"3", "four":"4", "five":"5",
        "six":"6", "seven":"7", "eight":"8", "nine":"9", "ten":"10",
        "eleven":"11", "twelve":"12", "thirteen":"13", "fourteen":"14", "fifteen":"15",
        "sixteen":"16", "seventeen":"17", "eighteen":"18", "nineteen":"19", "twenty":"20",
        "thirty":"30", "forty":"40", "fifty":"50", "sixty":"60", "seventy":"70", "eighty":"80", "ninety":"90",
        "nul":"0", "een":"1", "één":"1", "twee":"2", "drie":"3", "vier":"4", "vijf":"5",
        "zes":"6", "zeven":"7", "acht":"8", "negen":"9", "tien":"10", "elf":"11", "twaalf":"12"
    ]
    private static let units: [String: String] = [
        "mg":"mg", "milligram":"mg", "milligrams":"mg",
        "g":"g", "gram":"g", "grams":"g", "grammen":"g",
        "kg":"kg", "kilo":"kg", "kilos":"kg", "kilogram":"kg", "kilograms":"kg",
        "ml":"ml", "milliliter":"ml", "milliliters":"ml", "millilitre":"ml", "millilitres":"ml",
        "l":"l", "liter":"l", "liters":"l", "litre":"l", "litres":"l",
        "%":"%", "percent":"%", "procent":"%",
        "seconds":"s", "second":"s", "seconden":"s", "seconde":"s", "sec":"s", "s":"s",
        "minutes":"min", "minute":"min", "minuten":"min", "minuut":"min", "min":"min",
        "hours":"h", "hour":"h", "uren":"h", "uur":"h", "h":"h",
        "days":"day", "day":"day", "dagen":"day", "dag":"day",
        "mm":"mm", "cm":"cm", "km":"km", "meter":"m", "meters":"m", "metre":"m", "metres":"m", "m":"m"
    ]
    // Match number tokens and their optional units together so 5 mg cannot become 5 g.
    private static let quantity = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}])(?:-?\d+(?:[.,]\d+)*(?![\p{N}])|(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|nul|één|een|twee|drie|vier|vijf|zes|zeven|acht|negen|tien|elf|twaalf)(?![\p{L}\p{N}]))(?:\s*(?:seconds|second|seconden|seconde|minutes|minute|minuten|minuut|hours|hour|uren|uur|days|day|dagen|dag|meters|meter|metres|metre|milligrams|milligram|kilograms|kilogram|milliliters|milliliter|millilitres|millilitre|liters|liter|litres|litre|grammen|grams|gram|kilos|kilo|percent|procent|sec|min|mm|cm|km|mg|kg|ml|g|l|s|h|m|%)(?![\p{L}]))?"#
    )
    private static let parts = try! NSRegularExpression(pattern: #"(?i)^(-?[\d.,]+|[\p{L}]+)\s*(.*)$"#)

    private static let spelledRunWords = #"(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand)"#
    private static let spelledRun = try! NSRegularExpression(
        pattern: #"(?i)\b"# + spelledRunWords + #"(?:(?:\s+|-)"# + spelledRunWords + #")*\b"#
    )
    private static let spelledDigits: Set<String> = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    /// Writes spelled-out English numbers as digits, so "twenty five" and "25" compare equal.
    /// A run of single digit words is read as digits in order ("one two five" becomes "125",
    /// as in "one two five degrees"). Anything else is added up ("twenty five" becomes "25",
    /// "two hundred" becomes "200"). Units and the words after the number are left alone.
    static func digitized(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in spelledRun.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let phrase = ns.substring(with: match.range).lowercased()
            let tokens = phrase.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\t" || $0 == "\n" }).map(String.init)
            out += digits(for: tokens) ?? phrase
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func digits(for tokens: [String]) -> String? {
        if tokens.count >= 2, tokens.allSatisfy({ spelledDigits.contains($0) }) {
            return tokens.compactMap { numberWords[$0] }.joined()
        }
        var total = 0
        var current = 0
        for token in tokens {
            if let value = numberWords[token], let n = Int(value) {
                current += n
            } else if let value = scaleWords[token] {
                if value == 100 {
                    current = (current == 0 ? 1 : current) * 100
                } else {
                    total += (current == 0 ? 1 : current) * value
                    current = 0
                }
            } else {
                return nil
            }
        }
        return String(total + current)
    }

    private static let scaleWords: [String: Int] = ["hundred": 100, "thousand": 1000]

    private static func quantities(_ text: String) -> [String] {
        // Typing glue ("of2", "5km") counts the same as the spaced form ("of 2", "5 km"): split letter/digit
        // boundaries on both sides before comparing, so fixing a missing space is not "changing a number".
        let lowered = digitized(text).lowercased()
            .replacingOccurrences(of: #"(?<=\p{L})(?=\d)|(?<=\d)(?=\p{L})"#, with: " ", options: .regularExpression)
        return quantity.matches(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)).compactMap { match in
            guard let range = Range(match.range, in: lowered) else { return nil }
            let token = String(lowered[range])
            guard let partsMatch = parts.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
                  let numberRange = Range(partsMatch.range(at: 1), in: token),
                  let unitRange = Range(partsMatch.range(at: 2), in: token) else { return nil }
            let number = String(token[numberRange])
            let unit = String(token[unitRange])
            // Bare Dutch "een" is usually an article, not the number one.
            if number == "een" && unit.isEmpty { return nil }
            let canonicalNumber = numberWords[number] ?? normalizeNumber(number)
            return canonicalNumber + ":" + (units[unit] ?? unit)
        }.sorted()
    }

    private static func normalizeNumber(_ number: String) -> String {
        // Three trailing digits can be a thousands group or a decimal. Keep
        // those and all multiple-separator forms literal instead of guessing.
        let separators = number.filter { $0 == "." || $0 == "," }
        if separators.count > 1 { return number }
        if separators.count == 1,
           let separator = number.firstIndex(where: { $0 == "." || $0 == "," }),
           number.distance(from: number.index(after: separator), to: number.endIndex) == 3 {
            return number
        }
        let decimal = number.replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: decimal, locale: Locale(identifier: "en_US_POSIX")) else { return number }
        return NSDecimalNumber(decimal: value).stringValue
    }
}
