import Foundation

/// Deterministic repair for fast typing: keyboard slips, swapped letters, words split apart or run
/// together ("figu rei tout" -> "figure it out", "likethepogoress" -> "like the progress"), missing
/// apostrophes and near-miss product names ("wisprflwo" -> "Wispr Flow").
///
/// Mirrors offlinepage.app's autocorrect: a keyboard-weighted edit distance over a frequency dictionary
/// (its words.txt), with tinynext scoring each candidate in context. Two additions for Flow: spaces are
/// keys too, so split and joined words fall out of the same distance, and a segmentation pass proposes
/// the word boundaries. URLs, code, numbers, names and Flow's dictionary are never rewritten.
final class TypoRepair: @unchecked Sendable {
    static let shared = TypoRepair()

    struct Weights {
        var cost: Float = 1.0
        var lm: Float = 0.6
        var frequency: Float = 0.15
        var keep: Float = 2.0
        /// Post-model pass: a change must beat keeping the word by this much.
        var conservativeMargin: Float = 3.0
    }
    static var weights: Weights = {
        var w = Weights()
        let env = ProcessInfo.processInfo.environment
        if let v = env["FLOW_TYPO_W_COST"].flatMap(Float.init) { w.cost = v }
        if let v = env["FLOW_TYPO_W_LM"].flatMap(Float.init) { w.lm = v }
        if let v = env["FLOW_TYPO_W_FREQ"].flatMap(Float.init) { w.frequency = v }
        if let v = env["FLOW_TYPO_W_KEEP"].flatMap(Float.init) { w.keep = v }
        if let v = env["FLOW_TYPO_W_MARGIN"].flatMap(Float.init) { w.conservativeMargin = v }
        return w
    }()

    // MARK: Vocabulary

    /// Product and app names: protected, but near misses snap to this spelling and casing.
    /// `snaps`: also fix the casing of an exact lowercase match ("computeruse" -> "COMPUTERUSE"). Entries that are
    /// ordinary words too (pure, flow, mode) only keep their spelling; they never take over a plain word.
    static let productVocabulary: [(term: String, snaps: Bool)] = [
        ("Wispr Flow", true), ("Wispr", true), ("COMPUTERUSE", true), ("Companion", false), ("Flow", false),
        ("T3 Code", true), ("AcmeX", true), ("ExampleCo", false), ("Claude", true),
        ("Codex", true), ("ChatGPT", true), ("CleanShot", true), ("iCloud", true), ("NAS", false),
        ("WhatsApp", true), ("Figma", true),
        // 22 Nov 2026, from his typed T3 messages: "qwen" 33x, "t3" 38x lowercase.
        ("Qwen", true), ("T3", true), ("ExampleModel", true), ("AcmeHub", true), ("AcmeAudio", true), ("LFM", true)
    ]

    /// Typed shorthand that is not a typo.
    static let slang: Set<String> = Set("""
    idk pls plz lol lmao ppl smth tmrw rn bc cuz bru bruh ngl tbh imo yk ikr omg wtf fr lowkey bla blah haha hahaha \
    hmm hm ok okay btw asap etc vs ui ux ai llm api app apps gonna wanna gotta sorta kinda dunno lemme gimme ya yeah \
    yep nah tho thru u ur pc mac ios json html css url urls github repo repos dev devs tf mb gb tb ms px fps hq bg \
    idc ig gg pov yo bro gpt rtx mlx gguf onnx cpu gpu ram ssd sdk cli vm os tts stt asr ocr rl ml nlp npm jsx tsx \
    svg png jpg mp4 mov wav pdf csv xml yaml toml zsh nas ipv dns ssh http https www lfm qwen llama mistral gemma \
    hillclimb hillclimbing subagent subagents finetune finetuned finetuning walkingpad dictations dictation tinyfix \
    tinynext whisper wispr opt cmd ctrl alt esc ux eta hmu wyd nvm ty thx ily gm gn
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// Unambiguous missing-apostrophe forms ("dont" is never a word; "ill", "well", "its" can be).
    static let contractions: [String: String] = [
        "arent": "aren't", "cant": "can't", "couldnt": "couldn't", "didnt": "didn't", "doesnt": "doesn't",
        "dont": "don't", "hadnt": "hadn't", "hasnt": "hasn't", "havent": "haven't", "im": "I'm", "isnt": "isn't",
        "ive": "I've", "shouldnt": "shouldn't", "thats": "that's", "theres": "there's", "theyre": "they're",
        "theyve": "they've", "wasnt": "wasn't", "werent": "weren't", "weve": "we've", "whats": "what's",
        "wont": "won't", "wouldnt": "wouldn't", "youre": "you're", "youve": "you've", "youll": "you'll",
        "itll": "it'll", "wouldve": "would've", "couldve": "could've", "shouldve": "should've", "aint": "ain't",
        "theyll": "they'll", "yall": "y'all", "hows": "how's", "whos": "who's", "wheres": "where's",
        "thatd": "that'd", "itd": "it'd", "theyd": "they'd", "youd": "you'd", "heres": "here's"
    ]
    /// Contractions whose letters spell another word too ("its", "were", "well"): only offered when the
    /// typed word already had an apostrophe somewhere ("wer'e" -> "we're").
    static let apostropheForms: [String: String] = [
        "its": "it's", "were": "we're", "well": "we'll", "ill": "I'll", "id": "I'd", "wed": "we'd",
        "hell": "he'll", "shell": "she'll", "lets": "let's", "hes": "he's", "shes": "she's", "whos": "who's"
    ]
    private static let functionWords: Set<String> = Set("""
    a an the to of in on at it is be and or but so if i you we he she they me my your our this that what how why \
    when who with for from by as not no do does did can will just like all any one are was get got go
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    private static let suffixes = ["izations", "ization", "ations", "ation", "ings", "ing", "ed", "ers", "er", "est",
                                   "ly", "ness", "able", "ants", "ant", "ies", "es", "s", "y", "o", "ish", "ify", "ified"]

    // MARK: Lexicon

    final class Lexicon: @unchecked Sendable {
        let logFrequency: [String: Float]
        let trie: Trie
        let floorLog: Float
        let slangLog: Float
        /// Sum of all counts in words.txt (count = exp(logFrequency) * totalCount).
        let totalCount: Double

        init?(words url: URL) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            var counts: [String: Double] = [:]
            var total: Double = 0
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard parts.count == 2, let c = Double(parts[1]) else { continue }
                counts[String(parts[0])] = c
                total += c
            }
            guard total > 0, counts.count > 1000 else { return nil }
            var logs: [String: Float] = [:]
            logs.reserveCapacity(counts.count)
            var search: [String] = []
            for (w, c) in counts {
                logs[w] = Float(log(c / total))
                if c >= 20_000, w.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) { search.append(w) }
            }
            logFrequency = logs
            totalCount = total
            slangLog = Float(log(2e6 / total))
            floorLog = -30
            search += TypoRepair.slang
            search += TypoRepair.contractions.keys
            for entry in TypoRepair.productVocabulary { search.append(TypoRepair.key(entry.term)) }
            trie = Trie(Set(search.filter { !$0.isEmpty && $0.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) } }))
        }

        func baseKnown(_ w: String) -> Bool {
            if let f = logFrequency[w], f > Float(log(20_000.0 / 1e12)) { return true }
            return TypoRepair.slang.contains(w)
        }
    }

    private let lock = NSLock()
    private var lexiconStorage: Lexicon?
    private var loading = false
    private var retryLexiconAfter = Date.distantPast
    private var userTerms: [String: String] = [:]   // key -> surface
    private var userTermsLoadedAt = Date.distantPast

    func prewarm() {
        lock.lock()
        let start = lexiconStorage == nil && !loading && Date() >= retryLexiconAfter
        if start { loading = true }
        lock.unlock()
        TinyNextScorer.shared.prewarm()
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { _ = self.loadLexicon() }
    }

    @discardableResult
    private func loadLexicon() -> Lexicon? {
        let url = RealWordFixer.resourceDirectory(containing: "words.txt")?.appendingPathComponent("words.txt")
        let lex = url.flatMap { Lexicon(words: $0) }
        lock.lock()
        lexiconStorage = lex
        // Public builds may not ship words.txt. Back off without disabling
        // TinyNext or permanently preventing a later installation.
        retryLexiconAfter = lex == nil ? Date().addingTimeInterval(60) : .distantPast
        loading = false
        lock.unlock()
        return lex
    }

    func lexicon(wait: Bool) -> Lexicon? {
        lock.lock()
        if let lex = lexiconStorage { lock.unlock(); return lex }
        let busy = loading
        if wait && !busy { loading = true }
        lock.unlock()
        if wait && !busy { return loadLexicon() }
        if wait {
            for _ in 0..<300 {
                usleep(10_000)
                lock.lock(); let l = lexiconStorage; let b = loading; lock.unlock()
                if let l { return l }
                if !b { return nil }
            }
            return nil
        }
        prewarm()
        return nil
    }

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return lexiconStorage != nil }

    var readiness: String {
        lock.lock(); defer { lock.unlock() }
        if lexiconStorage != nil { return "ready" }
        if loading { return "loading" }
        return Date() < retryLexiconAfter ? "retry-backoff" : "cold"
    }

    /// Letters and digits only, lowercased: "Wispr Flow" -> "wisprflow".
    static func key(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) }
            .map(Character.init))
    }

    // MARK: Known words

    func isKnown(_ word: String, lexicon lex: Lexicon, userKeys: [String: String]) -> Bool {
        let l = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if lex.logFrequency[l] != nil || Self.slang.contains(l) || userKeys[Self.key(l)] != nil { return true }
        if Self.productVocabulary.contains(where: { Self.key($0.term) == l }) { return true }
        if l.contains("'") {
            let base = String(l.split(separator: "'").first ?? "")
            let joined = l.replacingOccurrences(of: "'", with: "")
            if Self.contractions[joined] != nil || Self.apostropheForms[joined] != nil { return Self.contractions[joined].map { $0.lowercased() == l } ?? (Self.apostropheForms[joined]?.lowercased() == l) }
            return lex.baseKnown(base) && ["s", "d", "ll", "re", "ve", "t", "m"].contains(String(l.split(separator: "'").last ?? ""))
        }
        for suffix in Self.suffixes where l.hasSuffix(suffix) && l.count - suffix.count >= 4 {
            let stem = String(l.dropLast(suffix.count))
            if lex.baseKnown(stem) || lex.baseKnown(stem + "e") { return true }
            let chars = Array(stem)
            if chars.count > 4, chars[chars.count - 1] == chars[chars.count - 2], lex.baseKnown(String(chars.dropLast())) { return true }
            if stem.hasSuffix("i"), lex.baseKnown(String(stem.dropLast()) + "y") { return true }
        }
        // A zero-edit compound of two content words ("chargeback", "walkingpad") is a word, not a typo.
        let chars = Array(l)
        if chars.count >= 8 {
            for k in 4...(chars.count - 4) {
                let a = String(chars[..<k]), b = String(chars[k...])
                if lex.baseKnown(a), lex.baseKnown(b), !Self.functionWords.contains(a), !Self.functionWords.contains(b) { return true }
            }
        }
        return false
    }

    private func logF(_ w: String, _ lex: Lexicon) -> Float {
        let l = w.lowercased().replacingOccurrences(of: "’", with: "'")
        if let f = lex.logFrequency[l] { return l.contains("'") ? max(f, lex.slangLog) : f }
        let joined = l.replacingOccurrences(of: "'", with: "")
        if Self.contractions[joined] != nil || Self.apostropheForms[joined] != nil { return lex.slangLog + 1 }
        if Self.slang.contains(l) || Self.productVocabulary.contains(where: { Self.key($0.term) == joined }) { return lex.slangLog }
        return lex.floorLog
    }

    // MARK: Keyboard cost (spaces are keys)

    private static let keyboardRows: [[UInt8]] = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0.utf8) }
    private static let neighbours: [Set<UInt8>] = {
        var table = [Set<UInt8>](repeating: [], count: 128)
        for (r, row) in keyboardRows.enumerated() {
            for (c, ch) in row.enumerated() {
                for (dr, dc) in [(0, -1), (0, 1), (-1, 0), (-1, 1), (1, -1), (1, 0)] {
                    let rr = r + dr, cc = c + dc
                    if rr >= 0, rr < 3, cc >= 0, cc < keyboardRows[rr].count { table[Int(ch)].insert(keyboardRows[rr][cc]) }
                }
            }
        }
        for ch in "cvbnm".utf8 { table[Int(ch)].insert(32); table[32].insert(ch) }
        return table
    }()
    private static func near(_ a: UInt8, _ b: UInt8) -> Bool { a < 128 && neighbours[Int(a)].contains(b) }
    private static func vowel(_ c: UInt8) -> Bool { c == 97 || c == 101 || c == 105 || c == 111 || c == 117 }

    /// offlinepage.app's typo cost (swap 1.2, doubled 1.2, adjacent key 1.6, vowel 2, missed 2.4, extra 3,
    /// wrong key 3.4, +1.5 at the first letter), with a missing or extra space costing 1.
    static func typoCost(_ typed: [UInt8], _ intended: [UInt8]) -> Float {
        let n = typed.count + 1, m = intended.count + 1
        var d = [Float](repeating: 0, count: n * m)
        func start(_ k: Int) -> Float { k == 0 ? 1.5 : 0 }
        func extra(_ t: Int) -> Float {
            let c = typed[t]
            if c == 32 { return 1.0 }
            if (t > 0 && typed[t - 1] == c) || (t + 1 < typed.count && typed[t + 1] == c) { return 1.2 }
            if (t > 0 && near(c, typed[t - 1])) || (t + 1 < typed.count && near(c, typed[t + 1])) { return 1.8 }
            return 3.0
        }
        func missed(_ i: Int) -> Float {
            if intended[i] == 32 { return 1.0 }
            if i > 0 && intended[i] == intended[i - 1] { return 1.2 }
            return 2.4
        }
        func sub(_ a: UInt8, _ b: UInt8) -> Float {
            if a == 32 || b == 32 { return 3.0 }
            if near(a, b) { return 1.6 }
            if vowel(a) && vowel(b) { return 2.0 }
            return 3.4
        }
        for i in 1..<n { d[i * m] = d[(i - 1) * m] + extra(i - 1) + start(i - 1) }
        if m > 1 { for j in 1..<m { d[j] = d[j - 1] + missed(j - 1) + start(j - 1) } }
        guard n > 1, m > 1 else { return d[n * m - 1] }
        for i in 1..<n {
            for j in 1..<m {
                let a = typed[i - 1], b = intended[j - 1]
                let s = start(min(i, j) - 1)
                var v = min(d[(i - 1) * m + j] + extra(i - 1) + s, d[i * m + j - 1] + missed(j - 1) + s,
                            d[(i - 1) * m + j - 1] + (a == b ? 0 : sub(a, b) + s))
                if i > 1, j > 1, a == intended[j - 2], typed[i - 2] == b {
                    v = min(v, d[(i - 2) * m + j - 2] + ((a == 32 || b == 32) ? 1.0 : 1.2))
                }
                d[i * m + j] = v
            }
        }
        return d[n * m - 1]
    }

    static func typoCost(_ typed: String, _ intended: String) -> Float {
        typoCost(Array(typed.lowercased().utf8), Array(intended.lowercased().utf8))
    }

    // MARK: Trie search (Damerau distance <= k), as in offlinepage.app

    final class Trie: @unchecked Sendable {
        private var character: [UInt8] = [0]
        private var firstChild: [Int32] = [-1]
        private var nextSibling: [Int32] = [-1]
        private var wordIndex: [Int32] = [-1]
        let words: [String]

        init(_ set: Set<String>) {
            words = set.sorted()
            for (i, w) in words.enumerated() { insert(Array(w.utf8), Int32(i)) }
        }

        private func insert(_ w: [UInt8], _ index: Int32) {
            var node = 0
            for c in w {
                var child = Int(firstChild[node])
                var found = -1
                while child != -1 {
                    if character[child] == c { found = child; break }
                    child = Int(nextSibling[child])
                }
                if found == -1 {
                    found = character.count
                    character.append(c); firstChild.append(-1); nextSibling.append(firstChild[node]); wordIndex.append(-1)
                    firstChild[node] = Int32(found)
                }
                node = found
            }
            wordIndex[node] = index
        }

        func search(_ word: [UInt8], maxDistance k: Int) -> [String] {
            let n = word.count + 1
            var results: [String] = []
            func visit(_ node: Int, _ prevChar: UInt8, _ row: [UInt8], _ prevRow: [UInt8]?) {
                var child = Int(firstChild[node])
                while child != -1 {
                    let c = character[child]
                    var cur = [UInt8](repeating: 0, count: n)
                    cur[0] = row[0] &+ 1
                    var best = cur[0]
                    for t in 1..<n {
                        let replace = row[t - 1] &+ (word[t - 1] == c ? 0 : 1)
                        var v = min(row[t] &+ 1, cur[t - 1] &+ 1, replace)
                        if let prevRow, t > 1, word[t - 1] == prevChar, word[t - 2] == c { v = min(v, prevRow[t - 2] &+ 1) }
                        cur[t] = v
                        best = min(best, v)
                    }
                    if wordIndex[child] != -1, Int(cur[n - 1]) <= k { results.append(words[Int(wordIndex[child])]) }
                    if Int(best) <= k { visit(child, c, cur, row) }
                    child = Int(nextSibling[child])
                }
            }
            visit(0, 0, (0..<n).map { UInt8($0) }, nil)
            return results
        }
    }

    // MARK: Personal typo dictionary

    /// Invented misspelling and correction pairs shipped as examples.
    /// Lowercase keys and values, straight apostrophes. Loaded once from TinyFix/typo_dictionary.json.
    static let personalDictionary: [String: String] = {
        guard let dir = RealWordFixer.resourceDirectory(containing: "typo_dictionary.json"),
              let data = try? Data(contentsOf: dir.appendingPathComponent("typo_dictionary.json")),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in map {
            out[k.replacingOccurrences(of: "’", with: "'").lowercased()] = v.replacingOccurrences(of: "’", with: "'")
        }
        return out
    }()

    private static let wordToken = try! NSRegularExpression(pattern: #"[A-Za-z]+(?:['’][A-Za-z]+)?"#)

    private static let overlayLock = NSLock()
    nonisolated(unsafe) private static var overlayCache: (revision: Int, map: [String: String])?

    /// The bundled pairs plus the misspellings Flow learned from the user's fixes (AutoDictionary, user
    /// overlay file VOICE/typo_dictionary.user.json). Read live: a new entry applies on the next text.
    static func currentPersonalDictionary(learned: AutoDictionary = .shared) -> [String: String] {
        let revision = learned.currentRevision
        overlayLock.lock(); defer { overlayLock.unlock() }
        if let cache = overlayCache, cache.revision == revision { return cache.map }
        var map = personalDictionary
        for (k, v) in learned.liveSpellings() where map[k] == nil { map[k] = v }
        overlayCache = (revision, map)
        return map
    }

    /// Only the learned misspellings (dictation applies these; the bundled pairs are for typing).
    static func applyLearnedSpelling(_ text: String, learned: AutoDictionary = .shared) -> String {
        let map = learned.liveSpellings()
        return map.isEmpty ? text : applyPersonalDictionary(text, dictionary: map)
    }

    /// Exact, whole-word swaps from the personal dictionary. Links, code and other protected spans are left
    /// alone; the first letter keeps the typed capitalisation. Cheap: one regex pass over the text.
    static func applyPersonalDictionary(_ text: String, dictionary: [String: String] = currentPersonalDictionary()) -> String {
        guard !dictionary.isEmpty else { return text }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let protectedRanges = protectedPattern.matches(in: text, range: whole).map(\.range)
        let mutable = NSMutableString(string: text)
        for m in wordToken.matches(in: text, range: whole).reversed() {
            guard !protectedRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { continue }
            let word = ns.substring(with: m.range)
            guard let fix = dictionary[word.replacingOccurrences(of: "’", with: "'").lowercased()] else { continue }
            var replacement = fix
            if word.first?.isUppercase == true { replacement = replacement.prefix(1).uppercased() + replacement.dropFirst() }
            mutable.replaceCharacters(in: m.range, with: replacement)
        }
        return mutable as String
    }

    // MARK: Repair

    struct Change: Equatable {
        let from: String
        let to: String
        let cost: Float
    }

    private static let tokenPattern = try! NSRegularExpression(pattern:
        #"https?://\S+|www\.\S+|[\w.+-]+@[\w-]+\.[\w.]+|[A-Za-z]+(?:['’][A-Za-z]+)*|\d+(?:[.,:]\d+)*[A-Za-z]*|\s+|."#,
        options: [.dotMatchesLineSeparators])
    /// Spans never edited: URLs, emails, paths, code, `quoted code`, snake_case and dotted identifiers.
    private static let protectedPattern = try! NSRegularExpression(pattern:
        #"`[^`]*`|https?://\S+|www\.\S+|[\w.+-]+@[\w-]+\.[\w.]+|(?:~|\.{1,2})?/[\w.\-/~]+|\b\w+_\w+\b|\b\w+\.\w{1,5}\b|\b[a-z]+[A-Z]\w*\b|\b\w*\d\w*\b"#)

    private static let sentencePattern = try! NSRegularExpression(pattern: #"[^.!?\n]+[.!?]*"#)

    private struct Candidate {
        var start: Int, end: Int   // token indices, inclusive
        var text: String
        var cost: Float
        var frequency: Float
        var keep: Bool
        var fixed: Bool = false
        var lm: Float = 0
    }

    func userKeyMap(_ terms: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for t in terms where !t.isEmpty {
            let k = Self.key(t)
            if k.count >= 3, map[k] == nil { map[k] = t }
        }
        return map
    }

    /// Repairs `text`. `conservative` is the pass after a model edit: only words still unknown, and only
    /// clear wins. Returns the text and each change made.
    func repair(_ text: String, protectedTerms: [String] = [], conservative: Bool = false, useLM: Bool = true,
                wait: Bool = false, deadline: ContinuousClock.Instant? = nil,
                typedText: String? = nil) -> (text: String, changes: [Change]) {
        // Words the writer typed in lowercase: a model capitalising one ("Odenst") does not make it a name.
        let typedLowercase = Set((typedText ?? "").split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init).filter { $0 == $0.lowercased() })
        guard let lex = lexicon(wait: wait) else { return (text, []) }
        // User typo pairs first: exact and cheap, before the model and as the fallback after it.
        let text = Self.snapPhrases(Self.applyPersonalDictionary(text), userTerms: protectedTerms)
        let scorer = useLM ? TinyNextScorer.shared.ready(wait: wait) : nil
        let userKeys = userKeyMap(protectedTerms)
        let w = Self.weights
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var protectedRanges = Self.protectedPattern.matches(in: text, range: whole).map(\.range)
        // Only English sentences are repaired: a Dutch word is not an English typo.
        for m in Self.sentencePattern.matches(in: text, range: whole)
        where !RealWordFixer.LanguageGate.sentenceIsEnglish(ns.substring(with: m.range)) {
            protectedRanges.append(m.range)
        }
        var tokens: [String] = []
        var tokenRanges: [NSRange] = []
        for m in Self.tokenPattern.matches(in: text, range: whole) {
            tokens.append(ns.substring(with: m.range)); tokenRanges.append(m.range)
        }
        var out = tokens
        var done = Set<Int>()
        var changes: [Change] = []
        func isWord(_ t: String) -> Bool {
            !t.isEmpty && t.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || $0 == "'" || $0 == "’" }
                && t.unicodeScalars.allSatisfy { $0.isASCII || $0 == "’" } && t.first!.isLetter
        }
        func isProtected(_ i: Int) -> Bool {
            let r = tokenRanges[i]
            return protectedRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }
        func sentenceStart(_ i: Int) -> Bool {
            var j = i - 1
            while j >= 0 {
                let t = out[j]
                if t.trimmingCharacters(in: .whitespaces).isEmpty { if t.contains("\n") { return true }; j -= 1; continue }
                return t == "." || t == "!" || t == "?" || t == ":" || t == "\n"
            }
            return true
        }
        func neighbourWord(_ i: Int, _ step: Int) -> Int? {
            let j = i + step, k = i + 2 * step
            guard j >= 0, j < tokens.count, k >= 0, k < tokens.count, tokens[j] == " ", isWord(tokens[k]), !isProtected(k) else { return nil }
            return k
        }
        var memo: [String: [(String, Float)]] = [:]
        func nearWords(_ piece: [UInt8]) -> [(String, Float)] {
            let key = String(decoding: piece, as: UTF8.self)
            if let hit = memo[key] { return hit }
            let k = piece.count <= 2 ? 0 : piece.count <= 4 ? 1 : 2
            var found: [String]
            if k == 0 {
                found = ((lex.logFrequency[key] ?? -99) > -14 || Self.slang.contains(key)) ? [key] : []
            } else {
                found = lex.trie.search(piece, maxDistance: k)
            }
            var scored = found.map { ($0, Self.typoCost(piece, Array($0.utf8))) }
            scored.sort { ($0.1 - 0.3 * logF($0.0, lex)) < ($1.1 - 0.3 * logF($1.0, lex)) }
            let top = Array(scored.prefix(8))
            memo[key] = top
            return top
        }
        func surface(_ w: String, apostrophe: Bool) -> String {
            if let c = Self.contractions[w] { return c }
            if apostrophe, let c = Self.apostropheForms[w] { return c }
            if w == "i" { return "I" }
            if let entry = Self.productVocabulary.first(where: { Self.key($0.term) == w && $0.snaps }) { return entry.term }
            if let u = userKeys[w], u.lowercased() != u || u.contains(" ") { return u }
            return w
        }
        /// Word sequences for the letters of a window (boundaries ignored), best first.
        func segmentations(_ letters: [UInt8], beam: Int = 10) -> [[String]] {
            let n = letters.count
            guard n > 0, n <= 40 else { return [] }
            var best = [[(Float, [String])]](repeating: [], count: n + 1)
            best[0] = [(0, [])]
            for k in 1...n {
                var cands: [(Float, [String])] = []
                for j in max(0, k - 18)..<k where !best[j].isEmpty {
                    for (word, cost) in nearWords(Array(letters[j..<k])) {
                        let f = logF(word, lex)
                        for (score, words) in best[j] { cands.append((score + cost - 0.5 * f, words + [word])) }
                    }
                }
                cands.sort { $0.0 < $1.0 }
                best[k] = Array(cands.prefix(beam))
            }
            return best[n].map(\.1)
        }
        func suspicious(_ i: Int) -> Bool {
            let t = tokens[i]
            guard isWord(t), !isProtected(i) else { return false }
            let l = t.lowercased().replacingOccurrences(of: "’", with: "'")
            if conservative {
                if Self.contractions[l] != nil || l == "u" || l == "i" { return true }
            } else if Self.contractions[l] != nil || l == "u" || l == "i" {
                return true
            }
            if Self.snapTarget(for: Self.key(t), userKeys: userKeys) != nil { return Self.snapTarget(for: Self.key(t), userKeys: userKeys)! != t }
            if isKnown(t, lexicon: lex, userKeys: userKeys) { return false }
            let upper = t.filter(\.isUppercase).count
            if upper > 1 { return false }   // ALLCAPS, CamelCase: a name or an acronym
            if upper == 1, t.first!.isUppercase, !sentenceStart(i), !typedLowercase.contains(t.lowercased()) { return false }
            return t.count >= 2
        }
        for i in tokens.indices {
            if let deadline, ContinuousClock.now >= deadline { break }
            guard !done.contains(i), suspicious(i) else { continue }
            let t = tokens[i]
            let l = t.lowercased().replacingOccurrences(of: "’", with: "'")
            var candidates: [Candidate] = []
            if let c = Self.contractions[l] {
                candidates.append(Candidate(start: i, end: i, text: c, cost: 0, frequency: 0, keep: false, fixed: true))
            } else if l == "u" {
                candidates.append(Candidate(start: i, end: i, text: "you", cost: 0, frequency: 0, keep: false, fixed: true))
            } else if l == "i" {
                candidates.append(Candidate(start: i, end: i, text: "I", cost: 0, frequency: 0, keep: false, fixed: true))
            } else if let snap = Self.snapTarget(for: Self.key(t), userKeys: userKeys), snap != t {
                candidates.append(Candidate(start: i, end: i, text: snap, cost: 0, frequency: 0, keep: false, fixed: true))
            }
            if candidates.isEmpty {
                var windows: [(Int, Int)] = [(i, i)]
                let p = neighbourWord(i, -1).flatMap { done.contains($0) ? nil : $0 }
                let n = neighbourWord(i, 1)
                let n2 = n.flatMap { neighbourWord($0, 1) }
                if let p { windows.append((p, i)) }
                if let n { windows.append((i, n)) }
                if let n2 { windows.append((i, n2)) }
                if let p, let n { windows.append((p, n)) }
                if conservative { windows = windows.filter { $0.1 - $0.0 <= 2 } }
                for (a, b) in windows {
                    let original = tokens[a...b].joined()
                    let lower = original.lowercased().replacingOccurrences(of: "’", with: "'")
                    let hadApostrophe = lower.contains("'")
                    let letters = Array(lower.utf8.filter { ($0 >= 97 && $0 <= 122) })
                    let typed = Array(lower.utf8.filter { ($0 >= 97 && $0 <= 122) || $0 == 32 })
                    // Product names and dictionary entries, split or joined ("wispr flow", "wisprflwo").
                    if let snap = Self.nearestVocabulary(String(decoding: letters, as: UTF8.self), userKeys: userKeys) {
                        candidates.append(Candidate(start: a, end: b, text: snap.term, cost: snap.cost, frequency: lex.slangLog, keep: false))
                    }
                    for words in segmentations(letters) {
                        let text = words.map { surface($0, apostrophe: hadApostrophe) }.joined(separator: " ")
                        let cost = Self.typoCost(typed, Array(words.joined(separator: " ").utf8))
                        let f = words.reduce(Float(0)) { $0 + logF($1, lex) }
                        candidates.append(Candidate(start: a, end: b, text: text, cost: cost, frequency: f, keep: false))
                    }
                    let originalWords = original.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).map(String.init)
                    candidates.append(Candidate(start: a, end: b, text: original, cost: 0,
                                                frequency: originalWords.reduce(Float(0)) { $0 + logF($1, lex) }, keep: true))
                }
            }
            var best: Candidate
            if let fixed = candidates.first(where: \.fixed) {
                best = fixed
            } else {
                var seen = Set<String>()
                var ranked = candidates.sorted { (-$0.cost + 0.5 * $0.frequency + ($0.keep ? 1 : 0)) > (-$1.cost + 0.5 * $1.frequency + ($1.keep ? 1 : 0)) }
                ranked = ranked.filter { seen.insert("\($0.start):\($0.end):\($0.text.lowercased())").inserted }
                var top = Array(ranked.prefix(10))
                // Keep options for every window stay in the running.
                for c in ranked.dropFirst(10) where c.keep { top.append(c) }
                if let scorer, top.count > 1 {
                    let lo = top.map(\.start).min()!, hi = top.map(\.end).max()!
                    let left = out[max(0, lo - 20)..<lo].joined()
                    let right = tokens[(hi + 1)..<min(tokens.count, hi + 9)].joined()
                    let texts = top.map { c in left + out[lo..<c.start].joined() + c.text + tokens[(c.end + 1)..<(hi + 1)].joined() + right }
                    let scores = scorer.score(texts)
                    for k in top.indices { top[k].lm = scores[k] }
                    best = top.max { a, b in
                        (-w.cost * a.cost + w.lm * a.lm + w.frequency * a.frequency + (a.keep ? w.keep : 0)) <
                        (-w.cost * b.cost + w.lm * b.lm + w.frequency * b.frequency + (b.keep ? w.keep : 0))
                    }!
                    if conservative, !best.keep {
                        func total(_ c: Candidate) -> Float { -w.cost * c.cost + w.lm * c.lm + w.frequency * c.frequency + (c.keep ? w.keep : 0) }
                        let keepScore = top.filter(\.keep).map(total).max() ?? -.infinity
                        if total(best) - keepScore < w.conservativeMargin { continue }
                    }
                } else {
                    best = top.max { a, b in
                        (-a.cost + 0.5 * a.frequency + (a.keep ? 1 : 0)) < (-b.cost + 0.5 * b.frequency + (b.keep ? 1 : 0))
                    } ?? candidates[0]
                    if conservative { continue }   // without the scorer, a model's edit stands as it is
                }
            }
            let original = tokens[best.start...best.end].joined()
            guard !best.keep, best.text != original else { continue }
            // Too far from what was typed to be a slip.
            let span = original.filter(\.isLetter).count
            if !best.fixed, best.cost > 1.5 + 0.75 * Float(span) { continue }
            var replacement = best.text
            let typedLower = typedLowercase.contains(original.lowercased()) && !sentenceStart(best.start)
            if original.first?.isUppercase == true, replacement.first?.isLowercase == true, !typedLower {
                replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
            }
            out[best.start] = replacement
            if best.end > best.start { for k in (best.start + 1)...best.end { out[k] = "" } }
            for k in best.start...best.end { done.insert(k) }
            changes.append(Change(from: original, to: replacement, cost: best.cost))
        }
        return (out.joined(), changes)
    }

    /// "wispr flow", "wisprflow", "t3 code" -> the product's own spelling, outside URLs and code.
    static func snapPhrases(_ text: String, userTerms: [String] = []) -> String {
        var result = text
        let terms = productVocabulary.filter(\.snaps).map(\.term).filter { $0.contains(" ") || $0.contains(where: \.isNumber) }
            + userTerms.filter { $0.contains(" ") && $0.lowercased() != $0 }
        for term in terms.sorted(by: { $0.count > $1.count }) {
            let parts = term.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?<![\w/.@-])"# + parts.joined(separator: #"[ ]?"#) + #"(?![\w/@-])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ns = result as NSString
            let protectedRanges = protectedPattern.matches(in: result, range: NSRange(location: 0, length: ns.length))
                .map(\.range).filter { r in !(ns.substring(with: r).range(of: #"^\w+\d\w*$"#, options: .regularExpression) != nil) }
            let mutable = NSMutableString(string: result)
            for m in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
            where !protectedRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                mutable.replaceCharacters(in: m.range, with: term)
            }
            result = mutable as String
        }
        return result
    }

    /// Fast product-name pass for Opt+1: "wisprflwo" / "wispr flow" -> "Wispr Flow", "computeruse" -> "COMPUTERUSE".
    /// Only words that are not ordinary English words are snapped; links and code are left alone.
    func snapVocabulary(_ text: String, protectedTerms: [String] = []) -> String {
        let userKeys = userKeyMap(protectedTerms)
        let lex = lexicon(wait: true)
        var result = Self.snapPhrases(ProperNounVocabulary.applyCapsAbbreviations(ProperNounVocabulary.applyHeardNameFixes(text)),
                                      userTerms: protectedTerms)
        let ns = result as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let protectedRanges = Self.protectedPattern.matches(in: result, range: whole).map(\.range)
        let tokens = Self.tokenPattern.matches(in: result, range: whole).map(\.range)
        func isLetters(_ r: NSRange) -> Bool {
            let t = ns.substring(with: r)
            return !t.isEmpty && t.unicodeScalars.allSatisfy { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
        }
        func free(_ r: NSRange) -> Bool { !protectedRanges.contains { NSIntersectionRange($0, r).length > 0 } }
        func ordinary(_ t: String) -> Bool {
            guard let lex else { return true }
            let l = t.lowercased()
            return lex.logFrequency[l] != nil || Self.slang.contains(l)
        }
        var edits: [(NSRange, String)] = []
        var i = 0
        while i < tokens.count {
            let r = tokens[i]
            guard isLetters(r), free(r) else { i += 1; continue }
            let word = ns.substring(with: r)
            // Two words typed for one name: "wispr flwo".
            if i + 2 < tokens.count, ns.substring(with: tokens[i + 1]) == " ", isLetters(tokens[i + 2]), free(tokens[i + 2]) {
                let second = ns.substring(with: tokens[i + 2])
                if !(ordinary(word) && ordinary(second)),
                   let snap = Self.nearestVocabulary(Self.key(word + second), userKeys: userKeys), snap.term.contains(" ") {
                    edits.append((NSRange(location: r.location, length: NSMaxRange(tokens[i + 2]) - r.location), snap.term))
                    i += 3; continue
                }
            }
            if let exact = Self.snapTarget(for: Self.key(word), userKeys: userKeys) {
                if exact != word, !(word.first?.isUppercase == true && word.dropFirst().contains(where: \.isUppercase)) {
                    edits.append((r, exact))
                }
            } else if !ordinary(word), let snap = Self.nearestVocabulary(Self.key(word), userKeys: userKeys) {
                edits.append((r, snap.term))
            }
            i += 1
        }
        guard !edits.isEmpty else { return result }
        let mutable = NSMutableString(string: result)
        for (r, t) in edits.reversed() { mutable.replaceCharacters(in: r, with: t) }
        result = mutable as String
        return result
    }

    /// Exact-letter match with a product name or dictionary entry that should carry its own casing.
    static func snapTarget(for key: String, userKeys: [String: String]) -> String? {
        guard key.count >= 3 else { return nil }
        if let entry = productVocabulary.first(where: { Self.key($0.term) == key }), entry.snaps { return entry.term }
        if let u = userKeys[key], u.lowercased() != u { return u }
        return nil
    }

    /// The product name or dictionary entry this typed run of letters is a slip of, if any.
    static func nearestVocabulary(_ letters: String, userKeys: [String: String]) -> (term: String, cost: Float)? {
        let typed = Array(letters.utf8)
        guard typed.count >= 5 else { return nil }
        var best: (String, Float)?
        var terms = productVocabulary.filter(\.snaps).map(\.term)
        terms += userKeys.values.filter { $0.lowercased() != $0 || $0.contains(" ") }
        for term in terms {
            let k = Array(key(term).utf8)
            guard k.count >= 5, abs(k.count - typed.count) <= 2 else { continue }
            let cost = typoCost(typed, k)
            let limit = 1.0 + 0.45 * Float(k.count)
            if cost <= limit, best.map({ cost < $0.1 }) ?? true { best = (term, cost) }
        }
        return best
    }

    /// Capitalises the first letter of the text and of each sentence.
    static func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var atStart = true
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if atStart, c.isLetter {
                // Leave a URL, a handle or a code-like word alone.
                var j = i
                while j < chars.count, !chars[j].isWhitespace { j += 1 }
                let word = String(chars[i..<j])
                if !word.contains("://"), !word.contains("_"), !word.hasPrefix("www."), c.isLowercase,
                   !(word.count > 1 && word.dropFirst().contains(where: \.isUppercase)) {
                    chars[i] = Character(c.uppercased())
                }
                atStart = false
            } else if c == "." || c == "!" || c == "?" {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                atStart = next.isWhitespace
            } else if !c.isWhitespace {
                atStart = false
            }
            i += 1
        }
        return String(chars)
    }
}
