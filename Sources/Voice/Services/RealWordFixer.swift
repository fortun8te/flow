import Accelerate
import Foundation

/// Real-word autocorrect: "form" -> "from", "their" -> "there", "to" -> "too", when the words on both
/// sides make the intended word clear. A plain-Swift port of tinyfix (paperweight/tinyfix, MIT, 1.9M
/// parameters: two small GRUs, one reading the 16 words up to the word, one reading the 4 words after it
/// back to it) and the swap rules of its engine (cfahlgren1/tinyfix, src/engine/wrongWord.ts). No
/// generation: the model only scores a short list of candidate words, and a swap needs a clear margin;
/// a less likely slip needs a bigger one (about 1 wrong change in 2,000 words in the original bench).
///
/// - Dictation: only spelling homophones (their/there/they're, your/you're, its/it's, then/than, whose/who's,
///   affect/effect ...). A recogniser picks between sound-alike words from the audio, so the acoustic pairs
///   (to/too/two, buy/by, sale/sell, know/now, were/we're) stay as heard: on Jordan's dictations the model
///   got those wrong more often than right.
/// - Opt+1 (typed text): the whole known mix-up list (form/from, to/too ...), judged after non-word typos
///   are repaired. One-edit neighbours (the original engine's "slips" mode) were wrong 20 times and right 8
///   times on his typing, so they are off.
/// - A word with an unknown (probably misspelled) word within two words needs one more point of margin.
///
/// Never touched: names and capitalised words mid-sentence, ALL CAPS, words in the user's dictionary,
/// links, emails, paths, `code`, and any sentence that is not clearly English (Dutch stays as spoken).
///
/// Speed (21 Nov 2026): every judged word in a text is scored in one batch. Each GRU step is one BLAS
/// matrix multiply for the whole batch; the word-embedding part of every gate is computed once per
/// distinct word, not once per step; all element-wise maths runs in vDSP; the text side is a single
/// pass. About 1 ms for a typical dictation and under 15 ms for a 2,600-word one, also in the debug
/// build Flow ships. Missing weights or any failure leaves the text unchanged.
final class RealWordFixer: @unchecked Sendable {
    enum Mode: String, Sendable {
        case dictation, typed
        /// The original engine: known mix-ups and one-edit neighbours. Kept for comparison and tests.
        case slips
    }

    struct Fix: Equatable, Sendable {
        let original: String
        let replacement: String
        /// How much better the replacement fits than the typed word (model log-odds).
        let margin: Float
        /// The engine's decision value: margin minus the slip cost, plus the mix-up bonus. Fires at `threshold`.
        let value: Float
        /// UTF-16 offset of the word in the text that was checked.
        let location: Int
        /// The replacement is on the known mix-up list (their/there), not just one edit away.
        var knownMixup: Bool = false
        /// Unknown (likely misspelled) words within two words on either side.
        var unknownNearby: Int = 0

        /// Chance the swap is right. At the threshold the original bench measured about 94% of fixes
        /// right; every point of value above it is one more point of log-odds.
        var probability: Double {
            1 / (1 + exp(-(Double(value - RealWordFixer.threshold) + log(0.94 / 0.06))))
        }
    }

    static let shared = RealWordFixer()

    /// Settings key; default on. Off turns the real-word pass off for dictation and Opt+1.
    static let enabledKey = "voice.realWordFix"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Settings of the original engine ("careful": threshold 5, cost weight 0.5).
    static let threshold: Float = 5
    static let costWeight: Float = 0.5
    static let maxKnownMixupCost: Float = 1.5
    static let knownMixupBonus: Float = 1
    static let otherWordPenalty: Float = 1
    static let inflectionPenalty: Float = 1

    private let lock = NSLock()
    private var loaded: TinyFixModel?
    private var loadFailed = false
    private var loading = false

    /// Directory with tinyfix.bin, wrong-word-vocab.txt and wrong-word-confusions.txt.
    static func resourceDirectory() -> URL? {
        resourceDirectory(containing: "tinyfix.bin")
    }

    static func resourceDirectory(containing filename: String) -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["FLOW_TINYFIX_DIR"],
           fm.fileExists(atPath: URL(fileURLWithPath: override).appendingPathComponent(filename).path) { return URL(fileURLWithPath: override) }
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }
        roots.append(Bundle.main.bundleURL)
        if let e = Bundle.main.executableURL?.deletingLastPathComponent() { roots.append(e) }
        for b in Bundle.allBundles + Bundle.allFrameworks { roots.append(b.bundleURL.deletingLastPathComponent()) }
        for root in roots {
            for name in ["Voice_Voice.bundle", "Flow_Voice.bundle"] {
                let bundle = root.appendingPathComponent(name)
                for dir in [bundle.appendingPathComponent("TinyFix"),
                            bundle.appendingPathComponent("Contents/Resources/TinyFix")]
                where fm.fileExists(atPath: dir.appendingPathComponent(filename).path) {
                    return dir
                }
            }
            let direct = root.appendingPathComponent("TinyFix")
            if fm.fileExists(atPath: direct.appendingPathComponent(filename).path) { return direct }
        }
        return nil
    }

    /// Loads the weights once, off the main thread. Safe to call many times (for example at key down).
    func prewarm() {
        guard Self.isEnabled else { return }
        lock.lock()
        let start = loaded == nil && !loadFailed && !loading
        if start { loading = true }
        lock.unlock()
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { self.load() }
    }

    private func load() {
        let model = Self.resourceDirectory().flatMap { TinyFixModel(directory: $0) }
        lock.lock()
        loaded = model
        loadFailed = model == nil
        loading = false
        lock.unlock()
    }

    /// The model. With `wait`, loads it on this thread when nobody else is loading it (tests and tools).
    /// Without, nil until a background load has finished.
    func model(wait: Bool) -> TinyFixModel? {
        lock.lock()
        if let loaded { lock.unlock(); return loaded }
        if loadFailed { lock.unlock(); return nil }
        if loading {
            lock.unlock()
            guard wait else { return nil }
            // Another thread is loading: wait for it (tests only; the app never waits).
            while true {
                usleep(2_000)
                lock.lock()
                if !loading { let m = loaded; lock.unlock(); return m }
                lock.unlock()
            }
        }
        guard wait else { lock.unlock(); return nil }
        loading = true
        lock.unlock()
        load()
        lock.lock(); defer { lock.unlock() }
        return loaded
    }

    var isAvailable: Bool { model(wait: false) != nil }

    /// Dictation: known mix-ups only. `protectedTerms` are the user's dictionary words (never changed).
    /// When the model is not loaded yet the text comes back unchanged and loading starts.
    func fixDictation(_ text: String, protectedTerms: [String] = [], wait: Bool = false) -> String {
        fix(text, mode: .dictation, protectedTerms: protectedTerms, wait: wait).text
    }

    func fixTyped(_ text: String, protectedTerms: [String] = [], wait: Bool = false) -> String {
        fix(text, mode: .typed, protectedTerms: protectedTerms, wait: wait).text
    }

    func fix(_ text: String, mode: Mode, protectedTerms: [String] = [], wait: Bool = false) -> (text: String, fixes: [Fix]) {
        guard !text.isEmpty, text.utf16.count <= 24_000 else { return (text, []) }
        guard let model = model(wait: wait) else { prewarm(); return (text, []) }
        return Self.apply(model: model, text: text, mode: mode, protectedTerms: protectedTerms)
    }

    /// True when the text holds at least one word this mode could judge (cheap; no model run).
    func hasCandidates(_ text: String, mode: Mode) -> Bool {
        guard let model = model(wait: false) else { return false }
        let ns = text as NSString
        for m in Self.tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range)
            let lower = (t.utf16.contains(0x2019) ? t.replacingOccurrences(of: "’", with: "'") : t).lowercased()
            if let id = model.ids[lower], id >= TinyFixModel.specialTokens,
               mode == .slips || model.mixups(for: mode)[id] != nil { return true }
        }
        return false
    }

    // MARK: - Engine

    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z]+(?:['’][A-Za-z]+)?|\d+(?:[.,]\d+)*|\n|[^\sA-Za-z0-9_]"#)
    private static let protectedPattern = try! NSRegularExpression(pattern:
        #"`[^`\n]*`|https?://\S+|www\.\S+|[\w.+-]+@[\w-]+(?:\.[\w-]+)+|(?<![\w])[~/][\w.\-/]+|\b[\w-]+\.(?:swift|py|js|ts|json|md|txt|html|css|sh|yml|yaml|com|org|net|io|app|dev|ai|nl)\b"#,
        options: [.caseInsensitive])
    private static let sentencePattern = try! NSRegularExpression(pattern: #"[^.!?\n]+[.!?]*"#)
    private static let sentenceOpeners: Set<String> = [".", "!", "?", ":", "\""]

    private struct RawToken { let text: String; let range: NSRange; let lower: String }

    static func apply(model: TinyFixModel, text: String, mode: Mode, protectedTerms: [String]) -> (text: String, fixes: [Fix]) {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var raw: [RawToken] = []
        var anyCandidate = false
        for m in tokenPattern.matches(in: text, range: whole) {
            let t = ns.substring(with: m.range)
            let lower = (t.utf16.contains(0x2019) ? t.replacingOccurrences(of: "’", with: "'") : t).lowercased()
            if !anyCandidate, let id = model.ids[lower], id >= TinyFixModel.specialTokens,
               mode == .slips || model.mixups(for: mode)[id] != nil { anyCandidate = true }
            raw.append(RawToken(text: t, range: m.range, lower: lower))
        }
        guard anyCandidate else { return (text, []) }
        let units = Array(text.utf16)
        var protection = Protection(text: text, units: units)
        let skip = Set(protectedTerms.flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }) }.map(String.init))
        var language = LanguageGate(text: text, ns: ns, tokens: raw.map { ($0.lower, $0.range.location) })
        guard !language.mostlyDutch else { return (text, []) }

        // Model tokens of the whole text, as the engine's tokenize(textBefore, startsSentence: true) sees them.
        var ids: [Int] = []
        ids.reserveCapacity(raw.count)
        var lastToken: String?
        var positionOfRaw = [Int](repeating: -1, count: raw.count)
        for (i, t) in raw.enumerated() {
            if t.text == "\n" {
                if let last = lastToken, !sentenceOpeners.contains(last) { ids.append(model.tokenID(".")); lastToken = "." }
                continue
            }
            let atStart = lastToken.map(sentenceOpeners.contains) ?? true
            let token = isNameShaped(t.text) && !atStart ? "<name>" : t.lower
            positionOfRaw[i] = ids.count
            ids.append(model.tokenID(token))
            lastToken = token
        }

        struct Job { let rawIndex: Int; let typed: Int; let nearby: [Int] }
        var jobs: [Job] = []
        for (i, t) in raw.enumerated() {
            guard let typed = model.ids[t.lower], typed >= TinyFixModel.specialTokens, !skip.contains(t.lower) else { continue }
            let slips = mode == .slips
            let mixupList = model.mixups(for: mode)[typed]
            let hasMixups = mixupList != nil
            guard hasMixups || slips else { continue }
            if protection.covers(t.range) { continue }
            let sentenceStart = isSentenceStart(units, at: t.range.location)
            let previousAllows = previousTokenAllowsCheck(units, at: t.range.location)
            var nearby: [Int]?
            if slips, previousAllows, isCheckable(t.text, sentenceStart: sentenceStart) {
                nearby = model.nearbyIDs(typed)
            } else if hasMixups, previousAllows, hasKnownMixups(t.text, sentenceStart: sentenceStart) {
                nearby = mixupList
            }
            guard let nearby, !nearby.isEmpty, language.isEnglish(at: t.range.location) else { continue }
            jobs.append(Job(rawIndex: i, typed: typed, nearby: Array(nearby.prefix(TinyFixModel.maxNeighbors))))
        }
        guard !jobs.isEmpty else { return (text, []) }

        // One batched forward pass for every word that is judged.
        let L = TinyFixModel.leftWindow, R = TinyFixModel.rightWindow, C = TinyFixModel.candidates
        var left = [Int32](repeating: 0, count: jobs.count * L)
        var right = [Int32](repeating: 0, count: jobs.count * R)
        var cands = [Int32](repeating: 0, count: jobs.count * C)
        for (b, job) in jobs.enumerated() {
            let position = positionOfRaw[job.rawIndex]
            if position >= L {
                for k in 0..<L { left[b * L + k] = Int32(ids[position - L + k]) }
            } else {
                // zeros, then the start token, then every word before.
                left[b * L + (L - position - 1)] = Int32(TinyFixModel.start)
                for k in 0..<position { left[b * L + (L - position) + k] = Int32(ids[k]) }
            }
            // Right context: tokenize(textAfter, startsSentence: false), first 4, nearest word last.
            var after: [String] = []
            var r = job.rawIndex + 1
            while r < raw.count, after.count < R {
                let t = raw[r]; r += 1
                if t.text == "\n" {
                    if let last = after.last, !sentenceOpeners.contains(last) { after.append(".") }
                    continue
                }
                let atStart = after.last.map(sentenceOpeners.contains) ?? false
                after.append(isNameShaped(t.text) && !atStart ? "<name>" : t.lower)
            }
            for (k, token) in after.enumerated() { right[b * R + (R - 1 - k)] = Int32(model.tokenID(token)) }
            cands[b * C] = Int32(job.typed)
            for (k, id) in job.nearby.enumerated() { cands[b * C + 1 + k] = Int32(id) }
        }
        let scores = model.scores(left: left, right: right, candidates: cands, batch: jobs.count)

        var fixes: [(NSRange, String, Fix)] = []
        let curly = units.contains(0x2019) && !units.contains(39)
        var costs: [Int: Float] = [:]   // typed id * 20,000 + candidate id -> slip cost
        for (b, job) in jobs.enumerated() {
            let t = raw[job.rawIndex]
            let typedScore = scores[b * C]
            let mixups = model.knownMixups[job.typed] ?? []
            let typedHasMixups = job.nearby.contains(where: mixups.contains)
            var best: (word: String, value: Float, margin: Float, mixup: Bool)?
            for (k, id) in job.nearby.enumerated() {
                let word = model.vocabulary[id]
                let isMixup = mixups.contains(id)
                let key = job.typed * 20_000 + id
                var cost: Float
                if let known = costs[key] { cost = known } else { cost = typoCost(t.lower, word); costs[key] = cost }
                if isMixup { cost = min(cost, maxKnownMixupCost) }
                let margin = scores[b * C + k + 1] - typedScore
                var value = margin - costWeight * cost
                if isMixup {
                    value += knownMixupBonus
                } else {
                    if typedHasMixups { value -= otherWordPenalty }
                    if differsOnlyInEnding(t.lower, word) { value -= inflectionPenalty }
                }
                if best == nil || value > best!.value { best = (word, value, margin, isMixup) }
            }
            let p = positionOfRaw[job.rawIndex]
            let unknownNearby = (max(0, p - 2)...min(ids.count - 1, p + 2)).filter { $0 != p && ids[$0] == TinyFixModel.unknown }.count
            // A less certain context needs a bigger margin.
            guard let best, best.value >= threshold + (unknownNearby > 0 ? 1 : 0) else { continue }
            var replacement = matchCase(t.text, best.word)
            if t.text.contains("’") || (!t.text.contains("'") && curly) {
                replacement = replacement.replacingOccurrences(of: "'", with: "’")
            }
            guard replacement != t.text else { continue }
            fixes.append((t.range, replacement, Fix(original: t.text, replacement: replacement, margin: best.margin,
                                                   value: best.value, location: t.range.location,
                                                   knownMixup: best.mixup, unknownNearby: unknownNearby)))
        }
        guard !fixes.isEmpty else { return (text, []) }
        let out = NSMutableString(string: text)
        for (range, replacement, _) in fixes.reversed() { out.replaceCharacters(in: range, with: replacement) }
        return (out as String, fixes.map(\.2))
    }

    /// A capitalised word that is not "I"/"I'm": a name token mid-sentence.
    private static func isNameShaped(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        return !(word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’"))
    }

    // MARK: Language

    /// Which sentences are English. Dutch, German, mixed and other sentences are left alone. Apple's
    /// recogniser costs about 1 ms per sentence, so it only runs for sentences that hold a Dutch- or
    /// German-looking word and a word to judge; a sentence with none of those markers is English.
    struct LanguageGate {
        private let ns: NSString
        private let sentences: [NSRange]
        private var verdicts: [Bool?]
        private var cursor = 0
        let mostlyDutch: Bool

        /// Dutch marker words that are also everyday English words: no evidence at all.
        static let englishWords: Set<String> = ["we", "die", "of", "over", "even", "doe", "ben", "met", "heel", "want",
                                                "dank", "is", "door", "bent", "van"]
        /// Short Dutch words that turn up in English only now and then ("de Jong", "en route"): weak evidence.
        static let weakDutch: Set<String> = ["de", "en", "te", "op", "het", "dat", "dit", "om", "als", "ze", "je", "nu",
                                             "zo", "dan", "wie", "hoe", "er", "hier"]
        static let dutchOnly = DictationLanguage.dutchMarkers.subtracting(englishWords).subtracting(weakDutch)
        static let germanOnly = DictationLanguage.germanMarkers.subtracting(DictationLanguage.dutchMarkers)
            .subtracting(["die", "was", "also", "so", "hat", "bitte", "gut", "es", "mit", "wo", "der"])

        private let tokens: [(lower: String, location: Int)]
        private var tokenCursor = 0

        init(text: String, ns: NSString, tokens: [(String, Int)]) {
            self.ns = ns
            self.tokens = tokens.map { (lower: $0.0, location: $0.1) }
            sentences = RealWordFixer.sentencePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            verdicts = Array(repeating: nil, count: sentences.count)
            var words = 0, dutch = 0.0
            for t in tokens where t.0.first?.isLetter == true {
                words += 1
                if Self.dutchOnly.contains(t.0) { dutch += 1 } else if Self.weakDutch.contains(t.0) { dutch += 0.5 }
            }
            // A Dutch dictation has about half its words on the marker lists; English with one Dutch line far fewer.
            mostlyDutch = words >= 3 && dutch / Double(words) >= 0.3
        }

        /// Visit locations in increasing order.
        mutating func isEnglish(at location: Int) -> Bool {
            while cursor < sentences.count, NSMaxRange(sentences[cursor]) <= location { cursor += 1 }
            guard cursor < sentences.count, NSLocationInRange(location, sentences[cursor]) else { return false }
            if let known = verdicts[cursor] { return known }
            let range = sentences[cursor]
            while tokenCursor < tokens.count, tokens[tokenCursor].location < range.location { tokenCursor += 1 }
            var dutch = 0, weak = 0
            var k = tokenCursor
            while k < tokens.count, tokens[k].location < NSMaxRange(range) {
                let w = tokens[k].lower
                if Self.dutchOnly.contains(w) || Self.germanOnly.contains(w) { dutch += 1 } else if Self.weakDutch.contains(w) { weak += 1 }
                k += 1
            }
            let verdict: Bool
            if dutch == 0 && weak < 2 {
                // German words with umlauts or ß are not word tokens here: let the full check see them.
                let sentence = ns.substring(with: range)
                verdict = sentence.unicodeScalars.contains(where: { $0.value >= 0xC0 && $0.value < 0x250 })
                    ? DictationLanguage.sentenceLanguage(sentence) == .english : true
            } else if dutch >= 2 || dutch + weak >= 3 {
                verdict = false   // Dutch, German or a mix: leave as spoken.
            } else {
                verdict = DictationLanguage.sentenceLanguage(ns.substring(with: range)) == .english
            }
            verdicts[cursor] = verdict
            return verdict
        }

        /// The same rule on a sentence of its own.
        static func sentenceIsEnglish(_ sentence: String) -> Bool {
            let words = DictationLanguage.words(sentence)
            let dutch = words.filter { dutchOnly.contains($0) || germanOnly.contains($0) }.count + (sentence.contains("ß") ? 1 : 0)
            let weak = words.filter(weakDutch.contains).count
            if dutch == 0 && weak < 2 && !sentence.unicodeScalars.contains(where: { $0.value >= 0xC0 && $0.value < 0x250 }) { return true }
            if dutch >= 2 || dutch + weak >= 3 { return false }
            return DictationLanguage.sentenceLanguage(sentence) == .english
        }
    }

    // MARK: Protected spans

    /// Links, emails, paths, file names and `code`. Everything but code is one whitespace-free chunk, so
    /// the pattern only runs on the chunk around a word that is about to be judged (the whole-text regex
    /// cost about 8 ms on a 2,600-word dictation).
    struct Protection {
        private let text: NSString
        private let units: [UInt16]
        private var code: [NSRange] = []
        private var chunkCache: [Int: [NSRange]] = [:]

        init(text: String, units: [UInt16]) {
            self.text = text as NSString
            self.units = units
            guard units.contains(96) else { return }   // `
            var open: Int?
            for (i, u) in units.enumerated() {
                if u == 10 { open = nil; continue }
                guard u == 96 else { continue }
                if let start = open { code.append(NSRange(location: start, length: i - start + 1)); open = nil } else { open = i }
            }
        }

        mutating func covers(_ range: NSRange) -> Bool {
            if code.contains(where: { NSIntersectionRange($0, range).length > 0 }) { return true }
            var start = range.location, end = NSMaxRange(range)
            while start > 0, !RealWordFixer.isSpace(units[start - 1]) { start -= 1 }
            while end < units.count, !RealWordFixer.isSpace(units[end]) { end += 1 }
            // A plain word with at most one trailing or leading punctuation mark cannot be a link or path.
            if start == range.location, end - NSMaxRange(range) <= 1,
               end == NSMaxRange(range) || [44, 46, 59, 33, 63, 41].contains(units[end - 1]) { return false }
            let spans: [NSRange]
            if let cached = chunkCache[start] {
                spans = cached
            } else {
                spans = RealWordFixer.protectedPattern.matches(in: text as String, range: NSRange(location: start, length: end - start)).map(\.range)
                chunkCache[start] = spans
            }
            return spans.contains(where: { NSIntersectionRange($0, range).length > 0 })
        }
    }

    // MARK: Context rules (rules.ts), on UTF-16 units

    static func isSpace(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 || u == 11 || u == 12 || u == 0xA0 || u == 0x2028 }

    /// The text before `location` ends a sentence: nothing, ". ", "! ", "? ", ": ", a line break, or a
    /// list marker at the start of a line ("- ", "* ", "• ", "2) ").
    static func isSentenceStart(_ u: [UInt16], at location: Int) -> Bool {
        var i = location - 1
        var sawSpace = false
        while i >= 0, isSpace(u[i]) {
            if u[i] == 10 { return true }
            sawSpace = true
            i -= 1
        }
        if i < 0 { return location == 0 }
        let c = u[i]
        if c == 46 || c == 33 || c == 63 || c == 58 { return true }   // . ! ? :
        guard sawSpace else { return false }
        func lineStartBefore(_ index: Int) -> Bool {
            var j = index
            while j >= 0, u[j] == 32 || u[j] == 9 { j -= 1 }
            return j < 0 || u[j] == 10
        }
        if c == 45 || c == 42 || c == 0x2022 { return lineStartBefore(i - 1) }   // - * •
        if c == 41 {                                                            // "2)"
            var j = i - 1
            guard j >= 0, (48...57).contains(u[j]) else { return false }
            while j >= 0, (48...57).contains(u[j]) { j -= 1 }
            return lineStartBefore(j)
        }
        return false
    }

    /// The word just before is not part of a path, handle, tag or file name ("/", "@", "\", "_", "#", ".x").
    static func previousTokenAllowsCheck(_ u: [UInt16], at location: Int) -> Bool {
        var end = location - 1
        while end >= 0, isSpace(u[end]) { end -= 1 }
        guard end >= 0 else { return true }
        var start = end
        while start > 0, !isSpace(u[start - 1]) { start -= 1 }
        for k in start...end {
            let c = u[k]
            if c == 47 || c == 64 || c == 92 || c == 95 || c == 35 { return false }
            if c == 46, k < end, isWordUnit(u[k + 1]) { return false }
        }
        return true
    }

    private static func isWordUnit(_ c: UInt16) -> Bool {
        (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 95 || c >= 0xC0
    }

    static func isCheckable(_ word: String, sentenceStart: Bool) -> Bool {
        guard word.count >= 3, word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        if word == word.uppercased() { return false }
        if word.dropFirst().contains(where: \.isUppercase) { return false }
        if word.first!.isUppercase && !sentenceStart { return false }
        return true
    }

    private static func hasKnownMixups(_ word: String, sentenceStart: Bool) -> Bool {
        guard let first = word.first, first.isASCII, first.isLetter else { return false }
        if word.count > 1 && word == word.uppercased() { return false }
        if first.isUppercase { return sentenceStart && word != "I" }
        return true
    }

    static func matchCase(_ typed: String, _ replacement: String) -> String {
        guard let first = typed.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }

    static func differsOnlyInEnding(_ a: String, _ b: String) -> Bool {
        let endings: Set<String> = ["", "s", "es", "d", "ed", "ing", "r", "er", "ly"]
        let x = Array(a), y = Array(b)
        var shared = 0
        while shared < min(x.count, y.count) && x[shared] == y[shared] { shared += 1 }
        var stem = shared
        while stem >= 3 {
            if endings.contains(String(x[stem...])) && endings.contains(String(y[stem...])) { return true }
            stem -= 1
        }
        return false
    }

    // MARK: Keyboard typo cost (typoCost.ts)

    /// keyNear[a * 26 + b]: keys a and b touch on a QWERTY keyboard.
    private static let keyNear: [Bool] = {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0.utf8) }
        var near = [Bool](repeating: false, count: 26 * 26)
        for (r, row) in rows.enumerated() {
            for (k, key) in row.enumerated() {
                for (rr, shift) in [(r, -1), (r, 1), (r - 1, 0), (r - 1, 1), (r + 1, -1), (r + 1, 0)] {
                    guard rr >= 0, rr < rows.count else { continue }
                    let idx = k + shift
                    if idx >= 0, idx < rows[rr].count { near[Int(key - 97) * 26 + Int(rows[rr][idx] - 97)] = true }
                }
            }
        }
        return near
    }()

    /// How unlikely it is to type `typedWord` when meaning `intendedWord` (keyboard-aware edit cost, typoCost.ts).
    static func typoCost(_ typedWord: String, _ intendedWord: String) -> Float {
        let typed = Array(typedWord.utf8), intended = Array(intendedWord.utf8)
        func letter(_ c: UInt8) -> Bool { c >= 97 && c <= 122 }
        func nearby(_ a: UInt8?, _ b: UInt8?) -> Bool {
            guard let a, let b, letter(a), letter(b) else { return false }
            return keyNear[Int(a - 97) * 26 + Int(b - 97)]
        }
        func vowel(_ c: UInt8) -> Bool { c == 97 || c == 101 || c == 105 || c == 111 || c == 117 }
        func at(_ a: [UInt8], _ i: Int) -> UInt8? { i >= 0 && i < a.count ? a[i] : nil }
        func substitution(_ t: UInt8, _ i: UInt8) -> Float {
            if nearby(t, i) { return 1.6 }
            if vowel(t) && vowel(i) { return 2 }
            return 3.4
        }
        func extra(_ p: Int) -> Float {
            let key = typed[p]
            if key == at(typed, p - 1) || key == at(typed, p + 1) { return 1.2 }
            if nearby(key, at(typed, p - 1)) || nearby(key, at(typed, p + 1)) { return 1.8 }
            return 3
        }
        func missed(_ p: Int) -> Float { intended[p] == at(intended, p - 1) ? 1.2 : 2.4 }
        func start(_ p: Int) -> Float { p == 0 ? 1.5 : 0 }
        let rows = typed.count + 1, cols = intended.count + 1
        var table = [Float](repeating: 0, count: rows * cols)
        if rows > 1 { for r in 1..<rows { table[r * cols] = table[(r - 1) * cols] + extra(r - 1) + start(r - 1) } }
        if cols > 1 { for c in 1..<cols { table[c] = table[c - 1] + missed(c - 1) + start(c - 1) } }
        guard rows > 1, cols > 1 else { return table[rows * cols - 1] }
        for r in 1..<rows {
            for c in 1..<cols {
                let tk = typed[r - 1], ik = intended[c - 1]
                let first = start(min(r, c) - 1)
                let replace: Float = tk == ik ? 0 : substitution(tk, ik) + first
                var best = min(table[(r - 1) * cols + c] + extra(r - 1) + first,
                               table[r * cols + c - 1] + missed(c - 1) + first,
                               table[(r - 1) * cols + c - 1] + replace)
                if r > 1, c > 1, tk == intended[c - 2], typed[r - 2] == ik { best = min(best, table[(r - 2) * cols + c - 2] + 1.2) }
                table[r * cols + c] = best
            }
        }
        return table[rows * cols - 1]
    }
}

/// tinyfix weights in plain Swift (Accelerate). Shapes: embedding 20,000 x 64, GRU hidden 256,
/// 16 words of left context, 4 of right context, 9 candidates.
///
/// GRU step, as the export defines it: r = σ(x·Wr + h·Ur + br), z = σ(x·Wz + h·Uz + bz),
/// n = tanh(x·Wn + bn + r ⊙ (h·Un + cn)), h' = (1 − z) ⊙ n + z ⊙ h. The x·W parts depend only on the
/// word, so they are computed once per distinct word in the batch; each step is then one h·[Ur Uz Un]
/// multiply for the whole batch.
final class TinyFixModel: @unchecked Sendable {
    static let leftWindow = 16, rightWindow = 4, maxNeighbors = 8, candidates = 9
    static let pad = 0, unknown = 1, number = 2, start = 3, name = 4, specialTokens = 5
    static let embed = 64, hidden = 256

    let vocabulary: [String]
    let ids: [String: Int]
    let knownMixups: [Int: [Int]]
    /// The spelling homophones dictation may fix (see RealWordFixer).
    let dictationMixups: [Int: [Int]]
    /// Deleting one letter from a listed word gives these keys (one-edit neighbour search, slips mode
    /// only, built on first use).
    private lazy var deletions: [String: [Int]] = {
        var index: [String: [Int]] = [:]
        for (w, i) in targets {
            var chars = Array(w)
            for k in chars.indices {
                let removed = chars.remove(at: k)
                index[String(chars), default: []].append(i)
                chars.insert(removed, at: k)
            }
        }
        return index
    }()
    private let targets: [String: Int]
    private var neighborCache: [Int: [Int]] = [:]
    private let cacheLock = NSLock()

    private let embedding: [Float]   // [V, 64]
    private let wordBias: [Float]    // [V]
    private let typedBonus: [Float]  // [9]
    private struct Gru {
        let wx: [Float]    // [E, 3H]: reset | update | proposal input weights
        let bx: [Float]    // [3H]
        let wh: [Float]    // [H, 3H]: reset | update | proposal state weights
        let bState: [Float] // [H]: proposal state bias (inside the reset product)
    }
    private let leftGru: Gru, rightGru: Gru
    private let wMixLeft, wMixRight, bMix, wProj, bProj: [Float]

    init?(directory: URL) {
        guard let blob = try? Data(contentsOf: directory.appendingPathComponent("tinyfix.bin")),
              let vocabText = try? String(contentsOf: directory.appendingPathComponent("wrong-word-vocab.txt"), encoding: .utf8),
              let confusionText = try? String(contentsOf: directory.appendingPathComponent("wrong-word-confusions.txt"), encoding: .utf8),
              let tensors = Self.parse(blob) else { return nil }
        let vocab = vocabText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let vocabulary = vocab.last == "" ? Array(vocab.dropLast()) : vocab
        guard vocabulary.count == 20_000 else { return nil }
        self.vocabulary = vocabulary
        var ids: [String: Int] = [:]
        var targets: [String: Int] = [:]
        ids.reserveCapacity(vocabulary.count)
        for (i, w) in vocabulary.enumerated() {
            ids[w] = i
            guard i >= Self.specialTokens, Self.isTargetWord(w) else { continue }
            targets[w] = i
        }
        self.ids = ids
        self.targets = targets
        var mixups: [Int: [Int]] = [:]
        for line in confusionText.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard let first = parts.first, let typed = ids[first] else { continue }
            mixups[typed] = parts.dropFirst().compactMap { ids[$0] }
        }
        self.knownMixups = mixups
        var dictation: [Int: [Int]] = [:]
        for group in Self.dictationGroups {
            let members = group.compactMap { ids[$0] }
            for typed in members {
                let allowed = (mixups[typed] ?? []).filter { $0 != typed && members.contains($0) }
                if !allowed.isEmpty { dictation[typed] = allowed }
            }
        }
        self.dictationMixups = dictation
        func t(_ name: String, _ count: Int) -> [Float]? {
            guard let v = tensors[name], v.count == count else { return nil }
            return v
        }
        let V = 20_000, E = Self.embed, H = Self.hidden
        func gru(_ p: String) -> Gru? {
            guard let wr = t(p + ".reset_gate.w", (E + H) * H), let br = t(p + ".reset_gate.b", H),
                  let wz = t(p + ".update_gate.w", (E + H) * H), let bz = t(p + ".update_gate.b", H),
                  let wpi = t(p + ".proposal_input.w", E * H), let bpi = t(p + ".proposal_input.b", H),
                  let wps = t(p + ".proposal_state.w", H * H), let bps = t(p + ".proposal_state.b", H) else { return nil }
            // Rows of wr/wz: E input rows, then H state rows; each row has H columns.
            var wx = [Float](repeating: 0, count: E * 3 * H)
            var wh = [Float](repeating: 0, count: H * 3 * H)
            wx.withUnsafeMutableBufferPointer { x in
                for i in 0..<E {
                    let row = x.baseAddress! + i * 3 * H
                    wr.withUnsafeBufferPointer { _ = memcpy(row, $0.baseAddress! + i * H, H * 4) }
                    wz.withUnsafeBufferPointer { _ = memcpy(row + H, $0.baseAddress! + i * H, H * 4) }
                    wpi.withUnsafeBufferPointer { _ = memcpy(row + 2 * H, $0.baseAddress! + i * H, H * 4) }
                }
            }
            wh.withUnsafeMutableBufferPointer { h in
                for j in 0..<H {
                    let row = h.baseAddress! + j * 3 * H
                    wr.withUnsafeBufferPointer { _ = memcpy(row, $0.baseAddress! + (E + j) * H, H * 4) }
                    wz.withUnsafeBufferPointer { _ = memcpy(row + H, $0.baseAddress! + (E + j) * H, H * 4) }
                    wps.withUnsafeBufferPointer { _ = memcpy(row + 2 * H, $0.baseAddress! + j * H, H * 4) }
                }
            }
            return Gru(wx: wx, bx: br + bz + bpi, wh: wh, bState: bps)
        }
        guard let emb = t("embedding.w", V * E), let wb = t("word_bias.w", V), let tb = t("typed_bonus", 9),
              let l = gru("left"), let r = gru("right"),
              let wm = t("mix.w", 2 * H * H), let bm = t("mix.b", H),
              let wp = t("project.w", H * E), let bp = t("project.b", E) else { return nil }
        embedding = emb; wordBias = wb; typedBonus = tb; leftGru = l; rightGru = r
        wMixLeft = Array(wm[0..<(H * H)]); wMixRight = Array(wm[(H * H)...])
        bMix = bm; wProj = wp; bProj = bp
    }

    /// Spelling homophones: the same sound, a different spelling, and the wrong one is a writing error.
    static let dictationGroups: [[String]] = [
        ["their", "there", "they're"], ["your", "you're"], ["its", "it's"], ["whose", "who's"], ["then", "than"],
        ["affect", "effect"], ["lose", "loose", "loss"], ["weather", "whether"], ["principal", "principle"],
        ["complement", "compliment"], ["passed", "past"], ["advice", "advise"], ["accept", "except"], ["let's", "lets"],
        ["hear", "here"], ["breath", "breathe"], ["quiet", "quite"], ["peace", "piece"], ["waist", "waste"],
        ["brake", "break"], ["peak", "peek"], ["stationary", "stationery"], ["desert", "dessert"],
        ["council", "counsel"], ["chose", "choose"]
    ]

    func mixups(for mode: RealWordFixer.Mode) -> [Int: [Int]] {
        mode == .dictation ? dictationMixups : knownMixups
    }

    private static func isTargetWord(_ w: String) -> Bool {
        // ^[a-z]+(?:'[a-z]+)?$, at least two letters.
        let u = Array(w.utf8)
        guard u.count >= 2, let first = u.first, (97...122).contains(first), let last = u.last, (97...122).contains(last) else { return false }
        var apostrophes = 0
        for c in u {
            if c == 39 { apostrophes += 1; continue }
            if !(97...122).contains(c) { return false }
        }
        return apostrophes <= 1
    }

    /// TFX1: count, then per tensor: name, kind (0 float32, 1 uint8 with scale and zero point), dims, data.
    private static func parse(_ data: Data) -> [String: [Float]]? {
        var offset = 0
        func read<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            let value = data.subdata(in: offset..<(offset + size)).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            offset += size
            return value
        }
        guard data.count > 8, String(data: data.prefix(4), encoding: .ascii) == "TFX1" else { return nil }
        offset = 4
        guard let count = read(UInt32.self), count < 64 else { return nil }
        var out: [String: [Float]] = [:]
        for _ in 0..<count {
            guard let nameLength = read(UInt16.self), offset + Int(nameLength) <= data.count,
                  let name = String(data: data.subdata(in: offset..<(offset + Int(nameLength))), encoding: .utf8) else { return nil }
            offset += Int(nameLength)
            guard let kind = read(UInt8.self), let ndims = read(UInt8.self) else { return nil }
            var elements = 1
            for _ in 0..<ndims { guard let d = read(UInt32.self) else { return nil }; elements *= Int(d) }
            var scale: Float = 0, zero: UInt8 = 0
            if kind == 1 {
                guard let s = read(Float.self), let z = read(UInt8.self) else { return nil }
                scale = s; zero = z
            }
            guard let length = read(UInt32.self), offset + Int(length) <= data.count else { return nil }
            let bytes = data.subdata(in: offset..<(offset + Int(length)))
            offset += Int(length)
            if kind == 1 {
                guard bytes.count == elements else { return nil }
                // (byte - zero) * scale, vectorised: the debug build would take ~0.5 s per element loop.
                var values = [Float](repeating: 0, count: elements)
                bytes.withUnsafeBytes { raw in
                    values.withUnsafeMutableBufferPointer { v in
                        vDSP_vfltu8(raw.bindMemory(to: UInt8.self).baseAddress!, 1, v.baseAddress!, 1, vDSP_Length(elements))
                        var minusZero = -Float(zero), s = scale
                        vDSP_vsadd(v.baseAddress!, 1, &minusZero, v.baseAddress!, 1, vDSP_Length(elements))
                        vDSP_vsmul(v.baseAddress!, 1, &s, v.baseAddress!, 1, vDSP_Length(elements))
                    }
                }
                out[name] = values
            } else {
                guard bytes.count == elements * 4 else { return nil }
                out[name] = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
        return out
    }

    func tokenID(_ token: String) -> Int {
        if token == "<name>" { return Self.name }
        if token.first?.isNumber == true { return Self.number }
        return ids[token] ?? Self.unknown
    }

    /// Known mix-ups first, then words one edit away (insert, delete, substitute, swap), lowest id first.
    func nearbyIDs(_ id: Int) -> [Int] {
        cacheLock.lock()
        if let cached = neighborCache[id] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let word = vocabulary[id]
        let chars = Array(word)
        var found = Set<Int>()
        cacheLock.lock()
        let deletions = self.deletions
        cacheLock.unlock()
        // Our word with one letter more: listed words that lose a letter to become this word.
        for other in deletions[word] ?? [] { found.insert(other) }
        // One letter less, one letter changed or two letters swapped: share a deletion key.
        var keys: [String] = []
        var work = chars
        for k in chars.indices {
            let removed = work.remove(at: k)
            let key = String(work)
            keys.append(key)
            if let other = targets[key] { found.insert(other) }
            work.insert(removed, at: k)
        }
        for (k, key) in keys.enumerated() {
            for other in deletions[key] ?? [] where other != id && !found.contains(other) {
                let o = Array(vocabulary[other])
                guard o.count == chars.count else { continue }
                // Same length, same deletion key: a substitution at k, or a swap of k with a neighbour.
                if Self.oneSubstitutionOrSwap(chars, o, at: k) { found.insert(other) }
            }
        }
        found.remove(id)
        var result: [Int] = []
        for m in knownMixups[id] ?? [] where !result.contains(m) { result.append(m) }
        for n in found.sorted() where !result.contains(n) { result.append(n) }
        let capped = Array(result.prefix(Self.maxNeighbors))
        cacheLock.lock(); neighborCache[id] = capped; cacheLock.unlock()
        return capped
    }

    private static func oneSubstitutionOrSwap(_ a: [Character], _ b: [Character], at k: Int) -> Bool {
        var diffs: [Int] = []
        for i in a.indices where a[i] != b[i] {
            diffs.append(i)
            if diffs.count > 2 { return false }
        }
        if diffs.count == 1 { return true }
        if diffs.count == 2, diffs[1] == diffs[0] + 1, a[diffs[0]] == b[diffs[1]], a[diffs[1]] == b[diffs[0]] { return true }
        _ = k
        return false
    }

    /// Scores [batch, 9]. Inputs are row-major id arrays: left [batch, 16], right [batch, 4], candidates [batch, 9].
    func scores(left: [Int32], right: [Int32], candidates: [Int32], batch: Int) -> [Float] {
        guard batch > 0 else { return [] }
        // A long dictation has a few hundred judged words: split them over a few cores.
        let chunks = batch >= 96 ? min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)) : 1
        guard chunks > 1 else { return scoreChunk(left: left, right: right, candidates: candidates, batch: batch) }
        let L = Self.leftWindow, R = Self.rightWindow, C = Self.candidates
        let size = (batch + chunks - 1) / chunks
        var out = [Float](repeating: 0, count: batch * C)
        out.withUnsafeMutableBufferPointer { o in
            let base = o.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * size, hi = min(batch, lo + size)
                guard lo < hi else { return }
                let part = scoreChunk(left: Array(left[(lo * L)..<(hi * L)]), right: Array(right[(lo * R)..<(hi * R)]),
                                      candidates: Array(candidates[(lo * C)..<(hi * C)]), batch: hi - lo)
                part.withUnsafeBufferPointer { _ = memcpy(base + lo * C, $0.baseAddress!, (hi - lo) * C * 4) }
            }
        }
        return out
    }

    private func scoreChunk(left: [Int32], right: [Int32], candidates: [Int32], batch: Int) -> [Float] {
        let E = Self.embed, H = Self.hidden, C = Self.candidates
        let leftState = run(leftGru, ids: left, steps: Self.leftWindow, batch: batch)
        let rightState = run(rightGru, ids: right, steps: Self.rightWindow, batch: batch)
        var mixed = matmul(leftState, wMixLeft, m: batch, k: H, n: H)
        let fromRight = matmul(rightState, wMixRight, m: batch, k: H, n: H)
        mixed.withUnsafeMutableBufferPointer { m in
            fromRight.withUnsafeBufferPointer { r in
                vDSP_vadd(m.baseAddress!, 1, r.baseAddress!, 1, m.baseAddress!, 1, vDSP_Length(batch * H))
            }
            addRows(m.baseAddress!, bMix, rows: batch, n: H)
            var count = Int32(batch * H)
            vvtanhf(m.baseAddress!, m.baseAddress!, &count)
        }
        var summary = matmul(mixed, wProj, m: batch, k: H, n: E)
        summary.withUnsafeMutableBufferPointer { addRows($0.baseAddress!, bProj, rows: batch, n: E) }
        var out = [Float](repeating: 0, count: batch * C)
        embedding.withUnsafeBufferPointer { e in
            summary.withUnsafeBufferPointer { s in
                for b in 0..<batch {
                    for k in 0..<C {
                        let id = Int(candidates[b * C + k])
                        var dot: Float = 0
                        vDSP_dotpr(e.baseAddress! + id * E, 1, s.baseAddress! + b * E, 1, &dot, vDSP_Length(E))
                        out[b * C + k] = dot + wordBias[id] + typedBonus[k]
                    }
                }
            }
        }
        return out
    }

    private func run(_ g: Gru, ids: [Int32], steps: Int, batch B: Int) -> [Float] {
        let E = Self.embed, H = Self.hidden, G = 3 * H
        // Input part of every gate, once per distinct word: [U, 3H] = emb[U, E] · Wx + bx.
        var row: [Int32: Int] = [:]
        var distinct: [Int32] = []
        var slot = [Int](repeating: 0, count: ids.count)
        for (i, id) in ids.enumerated() {
            if let s = row[id] { slot[i] = s } else { row[id] = distinct.count; slot[i] = distinct.count; distinct.append(id) }
        }
        let U = distinct.count
        var gathered = [Float](repeating: 0, count: U * E)
        embedding.withUnsafeBufferPointer { e in
            gathered.withUnsafeMutableBufferPointer { gp in
                for (u, id) in distinct.enumerated() { memcpy(gp.baseAddress! + u * E, e.baseAddress! + Int(id) * E, E * 4) }
            }
        }
        var inputPart = matmul(gathered, g.wx, m: U, k: E, n: G)
        inputPart.withUnsafeMutableBufferPointer { addRows($0.baseAddress!, g.bx, rows: U, n: G) }

        let n = B * H
        let h = UnsafeMutablePointer<Float>.allocate(capacity: n); h.initialize(repeating: 0, count: n)
        let stateProduct = UnsafeMutablePointer<Float>.allocate(capacity: B * G)
        let reset = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let update = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let proposal = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let state = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let stateBias = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { [h, stateProduct, reset, update, proposal, state, stateBias].forEach { $0.deallocate() } }
        g.bState.withUnsafeBufferPointer { b in
            for r in 0..<B { memcpy(stateBias + r * H, b.baseAddress!, H * 4) }
        }
        let count = vDSP_Length(n)
        var countI = Int32(n)
        var one: Float = 1
        inputPart.withUnsafeBufferPointer { xp in
            g.wh.withUnsafeBufferPointer { wh in
                for step in 0..<steps {
                    // h · [Ur Uz Un] for the whole batch (zero at the first step).
                    if step == 0 {
                        stateProduct.initialize(repeating: 0, count: B * G)
                    } else {
                        vDSP_mmul(h, 1, wh.baseAddress!, 1, stateProduct, 1, vDSP_Length(B), vDSP_Length(G), vDSP_Length(H))
                    }
                    for b in 0..<B {
                        let x = xp.baseAddress! + slot[b * steps + step] * G
                        let s = stateProduct + b * G
                        vDSP_vadd(x, 1, s, 1, reset + b * H, 1, vDSP_Length(H))
                        vDSP_vadd(x + H, 1, s + H, 1, update + b * H, 1, vDSP_Length(H))
                        memcpy(proposal + b * H, x + 2 * H, H * 4)
                        memcpy(state + b * H, s + 2 * H, H * 4)
                    }
                    Self.sigmoid(reset, n, &countI, &one)
                    Self.sigmoid(update, n, &countI, &one)
                    // n = tanh(x·Wn + bn + r ⊙ (h·Un + cn))
                    vDSP_vadd(state, 1, stateBias, 1, state, 1, count)
                    vDSP_vma(reset, 1, state, 1, proposal, 1, proposal, 1, count)
                    vvtanhf(proposal, proposal, &countI)
                    // h' = n + z ⊙ (h − n)
                    vDSP_vsub(proposal, 1, h, 1, state, 1, count)      // state = h - n
                    vDSP_vma(update, 1, state, 1, proposal, 1, h, 1, count)
                }
            }
        }
        return Array(UnsafeBufferPointer(start: h, count: n))
    }

    private static func sigmoid(_ v: UnsafeMutablePointer<Float>, _ n: Int, _ count: inout Int32, _ one: inout Float) {
        vDSP_vneg(v, 1, v, 1, vDSP_Length(n))
        vvexpf(v, v, &count)
        vDSP_vsadd(v, 1, &one, v, 1, vDSP_Length(n))
        vvrecf(v, v, &count)
    }

    private func matmul(_ a: [Float], _ b: [Float], m: Int, k: Int, n: Int) -> [Float] {
        var c = [Float](repeating: 0, count: m * n)
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                c.withUnsafeMutableBufferPointer { cp in
                    vDSP_mmul(ap.baseAddress!, 1, bp.baseAddress!, 1, cp.baseAddress!, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(k))
                }
            }
        }
        return c
    }

    private func addRows(_ v: UnsafeMutablePointer<Float>, _ bias: [Float], rows: Int, n: Int) {
        bias.withUnsafeBufferPointer { b in
            for r in 0..<rows { vDSP_vadd(v + r * n, 1, b.baseAddress!, 1, v + r * n, 1, vDSP_Length(n)) }
        }
    }
}
