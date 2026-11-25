// AutoDictionary.swift
//
// Flow's self-learning dictionary (22 Nov 2026). It learns from what Jordan fixes, not from what he says.
//
// EVIDENCE
//   - A dictation he edits in the field after the paste (CorrectionLearner reads it back via Accessibility).
//   - An Opt+1 result he keeps (not undone within the keep window).
//   - A name he keeps writing across dictations (ProperNounVocabulary.learnFrom).
//   - History: his Wispr Flow edits and Flow's own saved edits (AutoDictionarySeed).
//   Negative evidence: Opt+1 Undo, and editing a learned fix back to what was heard.
//
// RULES (AutoDictionary.Rules)
//   - Each fix becomes heard -> written. Only small swaps count: 1-3 words for 1-3 words, never a rewrite.
//   - Never a common English word as the written side, never a change of meaning: two ordinary words
//     ("pale" -> "start"), a changed number, an added or dropped negation are all thrown away.
//   - Promotion: a clear name he typed himself goes live on first sight; everything else needs 2 sightings
//     (a recurring name 3). Growth is capped; pending entries decay after 60 days.
//   - Undo removes a live entry. It stays out for 30 days, and for good after a second undo.
//
// ROUTES (all read live; no restart)
//   - name / product  -> ProperNounVocabulary.customTerms() (ASR boost, polish vocabulary, casing), and a
//     heard-name fix when the heard form is not an ordinary word ("Freya" -> "Felix", not "trigger").
//   - misspelling     -> the user typo overlay (VOICE/typo_dictionary.user.json) on top of the bundled one.
//   - misheard phrase -> ProperNounVocabulary.applyHeardNameFixes ("acme max" -> "AcmeX").
//   - sound-alike     -> lowers the margin SoundAlikeCheck needs for that one direction (whether -> weather).
//
// REVIEW: the whole store is plain JSON at VOICE/auto-dictionary.json, each entry with its examples, count
// and dates. A short copy goes to Flow's settings (`voice.autoDictionary`) so Companion can show the list.

import Foundation

struct AutoDictionaryEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case name, spelling, phrase, soundAlike }
    enum Status: String, Codable, Sendable { case pending, live, removed }

    struct Example: Codable, Equatable, Sendable {
        var before: String
        var after: String
        var source: String
        var at: Date
    }

    var heard: String
    var written: String
    var kind: Kind
    var status: Status
    /// Independent sightings that counted.
    var count: Int
    var undos: Int
    var firstSeen: Date
    var lastSeen: Date
    var liveSince: Date?
    var removedAt: Date?
    /// Text replacement heard -> written is applied. False when the heard form is an ordinary word on its
    /// own ("trigger" -> "Illustrator"): then only the written name is boosted.
    var replaces: Bool
    var examples: [Example]
    var sources: [String: Int]

    var key: String { AutoDictionary.key(heard, written) }
}

final class AutoDictionary: @unchecked Sendable {
    enum Source: String, Sendable {
        case dictationEdit = "dictation edit"
        case opt1Kept = "Opt+1 kept"
        case recurringName = "recurring name"
        case wisprEdit = "Wispr edit"
        case wisprDictionary = "Wispr dictionary"
        case flowHistory = "Flow history"

        /// Jordan typed the fix himself.
        var isOwnEdit: Bool { self == .dictationEdit || self == .wisprEdit || self == .wisprDictionary || self == .flowHistory }
    }

    enum Rules {
        static let ownNameSightings = 1
        static let sightings = 2
        static let recurringNameSightings = 3
        static let maxLive = 300
        static let maxPending = 400
        static let maxExamples = 3
        static let maxPairsPerObservation = 3
        static let pendingDecaySeconds: TimeInterval = 60 * 86_400
        static let undoCooldownSeconds: TimeInterval = 30 * 86_400
        static let permanentUndos = 2
        /// words.txt count at or above this is an everyday word (about 5 per million): "pale", "trigger", "fig".
        static let commonCount: Double = 2_000_000
        /// Below this a lexicon word is rare enough to be a typo of a common one ("bette" is not).
        static let rareCount: Double = 50_000
        /// Share of tokens a fix may touch before it counts as a rewrite.
        static let maxChangedShare = 0.4
        static let exampleChars = 140
        /// Everyday words that are never learned, also when the word list is missing.
        static let everyday: Set<String> = [
            "the", "and", "but", "for", "are", "was", "were", "you", "your", "they", "them", "this", "that",
            "with", "from", "have", "has", "had", "not", "what", "when", "where", "who", "why", "how", "all",
            "any", "can", "could", "would", "should", "will", "just", "like", "about", "into", "than", "then",
            "there", "their", "here", "some", "more", "most", "much", "many", "want", "need", "make", "made",
            "take", "come", "going", "yes", "yeah", "okay", "well", "actually", "maybe", "really", "today",
            "now", "thing", "things", "stuff", "good", "great", "nice", "bad", "sure", "right", "left", "very",
            "also", "even", "still", "back", "over", "again", "kind", "sort", "look", "said", "tell", "think",
            "know", "feel", "work", "start", "empty", "smaller", "pale", "pill", "test", "better",
        ]
    }

    /// One promotion or removal, for the toast and the tests.
    struct Event: Equatable, Sendable {
        enum Change: String, Sendable { case promoted, removed }
        let change: Change
        let heard: String
        let written: String
        let kind: AutoDictionaryEntry.Kind
    }

    /// A word-level swap found between two texts.
    struct Pair: Equatable, Sendable {
        let heard: String
        let written: String
        /// The written side opens a sentence, so its capital proves nothing.
        let writtenAtSentenceStart: Bool
    }

    /// What Flow knows about a word, from the bundled frequency list.
    struct WordJudge: Sendable {
        /// Count in words.txt; nil when the word is not listed.
        var count: @Sendable (String) -> Double?
        /// Listed, an inflection, a contraction or Flow's own slang.
        var isKnown: @Sendable (String) -> Bool

        static func lexicon(wait: Bool) -> WordJudge? {
            guard let lex = TypoRepair.shared.lexicon(wait: wait) else { return nil }
            let total = lex.totalCount
            return WordJudge(
                count: { w in lex.logFrequency[w.lowercased()].map { Double(exp($0)) * total } },
                isKnown: { w in TypoRepair.shared.isKnown(w, lexicon: lex, userKeys: [:]) })
        }
    }

    static let shared = AutoDictionary(directory: defaultDirectory)

    static var defaultDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FLOW_AUTODICT_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        // Tests never read or write Jordan's real store.
        if env["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("flow-autodict-tests-\(getpid())", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VOICE", isDirectory: true)
    }

    static let settingsKey = "voice.autoDictionary"

    let storeURL: URL
    let overlayURL: URL
    /// Where the short review list goes. nil: not mirrored (CLI tools).
    private let settings: UserDefaults?
    private let lock = NSLock()
    private var entries: [String: AutoDictionaryEntry] = [:]
    private var loadedStamp: Date?
    private var checkedAt = Date.distantPast
    /// Bumped on every change; consumers cache on it.
    private(set) var revision = 0
    /// Opt+1 keeps, by operation, so an Undo after the keep can take the sighting back.
    private var keptKeys: [UUID: [String]] = [:]
    private var suspendSaves = false
    var judgeProvider: () -> WordJudge? = { WordJudge.lexicon(wait: false) }

    init(directory: URL, settings: UserDefaults? = AutoDictionary.defaultSettings) {
        storeURL = directory.appendingPathComponent("auto-dictionary.json")
        overlayURL = directory.appendingPathComponent("typo_dictionary.user.json")
        self.settings = settings
        lock.lock(); reloadIfChangedLocked(force: true); lock.unlock()
    }

    static var defaultSettings: UserDefaults? {
        Bundle.main.bundleIdentifier == "com.example.flow" ? .standard : nil
    }

    static func key(_ heard: String, _ written: String) -> String {
        heard.lowercased() + "\u{2192}" + written.lowercased()
    }

    // MARK: Reading (hot paths)

    /// Every entry, newest first: the plain review list.
    func allEntries() -> [AutoDictionaryEntry] {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        return entries.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    func entry(heard: String, written: String) -> AutoDictionaryEntry? {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        return entries[Self.key(heard, written)]
    }

    private func live(_ kinds: Set<AutoDictionaryEntry.Kind>) -> [AutoDictionaryEntry] {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        return entries.values.filter { $0.status == .live && kinds.contains($0.kind) }
    }

    /// Learned names and terms: the speech model boosts them and the polish keeps their spelling.
    func liveNames() -> [String] {
        var seen = Set<String>()
        return live([.name, .phrase]).map(\.written).sorted().filter { seen.insert($0.lowercased()).inserted }
    }

    /// Learned heard -> written replacements (names and phrases).
    func liveReplacements() -> [(heard: String, written: String)] {
        live([.name, .phrase]).filter { $0.replaces && $0.heard.lowercased() != $0.written.lowercased() }
            .sorted { $0.heard < $1.heard }.map { ($0.heard.lowercased(), $0.written) }
    }

    /// Learned misspellings, lowercase keys: the user overlay of the typo dictionary.
    func liveSpellings() -> [String: String] {
        var out: [String: String] = [:]
        for e in live([.spelling]) { out[e.heard.lowercased()] = e.written }
        return out
    }

    /// Learned sound-alike directions, "whether" -> "weather".
    func liveSoundAlikes() -> Set<String> {
        Set(live([.soundAlike]).map(\.key))
    }

    var currentRevision: Int {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        return revision
    }

    // MARK: Learning

    /// One piece of evidence: Flow wrote `before`, Jordan (or a kept Opt+1) made it `after`.
    @discardableResult
    func observe(before: String, after: String, source: Source, now: Date = Date(),
                 operation: UUID? = nil, judge: WordJudge? = nil) -> [Event] {
        guard before != after, let judge = judge ?? judgeProvider() else { return [] }
        let pairs = Self.substitutions(before: before, after: after)
        guard !pairs.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        var events: [Event] = []
        var touched: [String] = []
        for pair in pairs.prefix(Rules.maxPairsPerObservation) {
            // Editing a learned fix back is an undo of that fix, never a new fix the other way.
            // (Sound-alikes go both ways in different sentences, so they are only counted.)
            if let reverse = entries[Self.key(pair.written, pair.heard)], reverse.kind != .soundAlike {
                if reverse.status == .live, let e = undoLocked(key: reverse.key, now: now) { events.append(e) }
                continue
            }
            guard let classified = Self.classify(pair, judge: judge) else { continue }
            // A misspelling is stored lowercase: "Teh" at a sentence start teaches "teh" -> "the".
            let pair = classified.kind == .spelling
                ? Pair(heard: pair.heard.lowercased(), written: pair.written.lowercased(), writtenAtSentenceStart: false) : pair
            let example = AutoDictionaryEntry.Example(before: Self.clip(before, around: pair.heard),
                                                     after: Self.clip(after, around: pair.written),
                                                     source: source.rawValue, at: now)
            if let e = sightLocked(pair: pair, kind: classified.kind, replaces: classified.replaces,
                                   clearName: classified.clearName, source: source, example: example, now: now) {
                events.append(e)
            }
            touched.append(Self.key(pair.heard, pair.written))
        }
        if let operation, !touched.isEmpty { keptKeys[operation] = touched }
        pruneLocked(now: now)
        saveLocked()
        return events
    }

    /// A fix known only as the two words (Wispr's dictionary rows): no sentence around it.
    @discardableResult
    func observePair(heard: String, written: String, source: Source, now: Date = Date(), judge: WordJudge? = nil) -> [Event] {
        guard let judge = judge ?? judgeProvider() else { return [] }
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines), w = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !w.isEmpty, h != w, h.split(separator: " ").count <= 3, w.split(separator: " ").count <= 3 else { return [] }
        var pair = Pair(heard: h, written: w, writtenAtSentenceStart: false)
        guard let classified = Self.classify(pair, judge: judge) else { return [] }
        if classified.kind == .spelling { pair = Pair(heard: h.lowercased(), written: w.lowercased(), writtenAtSentenceStart: false) }
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        if let reverse = entries[Self.key(w, h)], reverse.kind != .soundAlike { return [] }
        let example = AutoDictionaryEntry.Example(before: h, after: w, source: source.rawValue, at: now)
        let event = sightLocked(pair: pair, kind: classified.kind, replaces: classified.replaces,
                                clearName: classified.clearName, source: source, example: example, now: now)
        pruneLocked(now: now)
        saveLocked()
        return event.map { [$0] } ?? []
    }

    /// Many observations, one save at the end (the history seed).
    func batch(_ body: () -> Void) {
        lock.lock(); suspendSaves = true; lock.unlock()
        body()
        lock.lock(); suspendSaves = false; saveLocked(); lock.unlock()
    }

    /// Empties the store (tests).
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
        keptKeys = [:]
        saveLocked()
    }

    /// A name seen again in his own dictations (no fix involved): vocabulary only, after 3 sightings.
    @discardableResult
    func observeRecurringName(_ name: String, context: String, now: Date = Date(), judge: WordJudge? = nil) -> [Event] {
        guard let judge = judge ?? judgeProvider() else { return [] }
        let word = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isNameLike(word, atSentenceStart: false, judge: judge) else { return [] }
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        let example = AutoDictionaryEntry.Example(before: Self.clip(context, around: word), after: Self.clip(context, around: word),
                                                 source: Source.recurringName.rawValue, at: now)
        let event = sightLocked(pair: Pair(heard: word, written: word, writtenAtSentenceStart: false), kind: .name,
                                replaces: false, clearName: false, source: .recurringName, example: example, now: now)
        pruneLocked(now: now)
        saveLocked()
        return event.map { [$0] } ?? []
    }

    /// Opt+1 Undo: every learned fix the undone edit made is taken out, and a keep it counted is taken back.
    @discardableResult
    func observeUndo(original: String, candidate: String, operation: UUID? = nil, now: Date = Date()) -> [Event] {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        var events: [Event] = []
        if let operation, let keys = keptKeys.removeValue(forKey: operation) {
            for key in keys {
                guard var e = entries[key] else { continue }
                e.count = max(0, e.count - 1)
                e.sources[Source.opt1Kept.rawValue] = max(0, (e.sources[Source.opt1Kept.rawValue] ?? 1) - 1)
                if e.count == 0 && e.status == .pending { entries[key] = nil } else { entries[key] = e }
            }
        }
        for pair in Self.substitutions(before: original, after: candidate) {
            let key = Self.key(pair.heard, pair.written)
            if entries[key]?.status == .live, let e = undoLocked(key: key, now: now) { events.append(e) }
        }
        saveLocked()
        return events
    }

    /// Jordan removes a learned word himself (Settings): out for good.
    func remove(written: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        let target = written.lowercased()
        var changed = false
        for (key, var e) in entries where e.written.lowercased() == target && e.status != .removed {
            e.status = .removed
            e.removedAt = now
            e.undos = max(e.undos, Rules.permanentUndos)
            entries[key] = e
            changed = true
        }
        if changed { saveLocked() }
    }

    // MARK: Evidence rules

    private func sightLocked(pair: Pair, kind: AutoDictionaryEntry.Kind, replaces: Bool, clearName: Bool,
                             source: Source, example: AutoDictionaryEntry.Example, now: Date) -> Event? {
        let key = Self.key(pair.heard, pair.written)
        var e = entries[key] ?? AutoDictionaryEntry(
            heard: pair.heard, written: pair.written, kind: kind, status: .pending, count: 0, undos: 0,
            firstSeen: now, lastSeen: now, liveSince: nil, removedAt: nil, replaces: replaces, examples: [], sources: [:])
        if e.status == .removed {
            // Out for good after two undos; otherwise back to pending only after the cooldown.
            guard e.undos < Rules.permanentUndos, let at = e.removedAt,
                  now.timeIntervalSince(at) >= Rules.undoCooldownSeconds else { return nil }
            e.status = .pending
            e.count = 0
            e.removedAt = nil
        }
        // His own casing wins: the latest written form is kept.
        if pair.written != e.written, pair.written.lowercased() == e.written.lowercased() { e.written = pair.written }
        e.count += 1
        e.lastSeen = now
        e.sources[source.rawValue, default: 0] += 1
        if !e.examples.contains(where: { $0.before == example.before && $0.after == example.after }) {
            e.examples.append(example)
            if e.examples.count > Rules.maxExamples { e.examples.removeFirst(e.examples.count - Rules.maxExamples) }
        }
        var event: Event?
        if e.status == .pending, e.count >= Self.needed(kind: e.kind, source: source, clearName: clearName) {
            let liveCount = entries.values.filter { $0.status == .live }.count
            if liveCount < Rules.maxLive {
                e.status = .live
                e.liveSince = now
                event = Event(change: .promoted, heard: e.heard, written: e.written, kind: e.kind)
            }
        }
        entries[key] = e
        return event
    }

    static func needed(kind: AutoDictionaryEntry.Kind, source: Source, clearName: Bool) -> Int {
        if source == .recurringName { return Rules.recurringNameSightings }
        if kind == .name, clearName, source.isOwnEdit { return Rules.ownNameSightings }
        return Rules.sightings
    }

    private func undoLocked(key: String, now: Date) -> Event? {
        guard var e = entries[key] else { return nil }
        let wasLive = e.status == .live
        e.undos += 1
        e.status = .removed
        e.removedAt = now
        e.count = 0
        entries[key] = e
        return wasLive ? Event(change: .removed, heard: e.heard, written: e.written, kind: e.kind) : nil
    }

    private func pruneLocked(now: Date) {
        for (key, e) in entries where e.status == .pending && now.timeIntervalSince(e.lastSeen) > Rules.pendingDecaySeconds {
            entries[key] = nil
        }
        let pending = entries.values.filter { $0.status == .pending }
        if pending.count > Rules.maxPending {
            let drop = pending.sorted { ($0.count, $0.lastSeen) < ($1.count, $1.lastSeen) }.prefix(pending.count - Rules.maxPending)
            for e in drop { entries[e.key] = nil }
        }
    }

    struct Classified: Equatable {
        let kind: AutoDictionaryEntry.Kind
        let replaces: Bool
        /// A name or product he clearly meant: capitals inside the word, or a capital mid-sentence.
        let clearName: Bool
    }

    /// The sound-alike groups Flow checks in context (SoundAlikeCheck).
    static let soundAlikeGroups: [[String]] = [
        ["whether", "weather"], ["their", "there", "they're"], ["your", "you're"], ["its", "it's"],
        ["to", "too", "two"], ["then", "than"], ["affect", "effect"], ["lose", "loose"]
    ]

    static func isSoundAlike(_ a: String, _ b: String) -> Bool {
        let x = normalized(a), y = normalized(b)
        return x != y && soundAlikeGroups.contains { $0.contains(x) && $0.contains(y) }
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static let negations: Set<String> = [
        "not", "no", "never", "none", "nothing", "nobody", "without", "cannot", "neither", "nor"
    ]

    /// Decides what a swap teaches, or nil when it teaches nothing safe.
    static func classify(_ pair: Pair, judge: WordJudge) -> Classified? {
        let heardWords = pair.heard.split(separator: " ").map(String.init)
        let writtenWords = pair.written.split(separator: " ").map(String.init)
        guard !heardWords.isEmpty, !writtenWords.isEmpty else { return nil }
        // Meaning guards: numbers and negations must not change.
        guard digits(pair.heard) == digits(pair.written) else { return nil }
        let negH = heardWords.filter { negations.contains(normalized($0)) || normalized($0).hasSuffix("n't") }.count
        let negW = writtenWords.filter { negations.contains(normalized($0)) || normalized($0).hasSuffix("n't") }.count
        guard negH == negW else { return nil }
        guard MeaningIntegrity.preservesQuantities(original: pair.heard, candidate: pair.written) else { return nil }

        if heardWords.count == 1, writtenWords.count == 1 {
            let h = heardWords[0], w = writtenWords[0]
            if isSoundAlike(h, w) { return Classified(kind: .soundAlike, replaces: false, clearName: false) }
            if h.lowercased() == w.lowercased() {
                // Casing only: a name or product he capitalises his own way ("figma" -> "Figma").
                guard isNameLike(w, atSentenceStart: pair.writtenAtSentenceStart, judge: judge) else { return nil }
                return Classified(kind: .name, replaces: false, clearName: hasInnerCapital(w) || !pair.writtenAtSentenceStart)
            }
            if isNameLike(w, atSentenceStart: pair.writtenAtSentenceStart, judge: judge) {
                // A name, not a changed ending or a slip of one letter ("Qwen" -> "Qwens").
                guard LearnedWordRules.isRealChange(from: h, to: w) || hasInnerCapital(w) else { return nil }
                let clear = hasInnerCapital(w) || (w.first?.isUppercase == true && !pair.writtenAtSentenceStart)
                return Classified(kind: .name, replaces: isSafeHeard(h, judge: judge), clearName: clear)
            }
            // A misspelling: the heard form is not a word, the written one is an everyday word close to it.
            let hl = h.lowercased(), wl = w.lowercased()
            let heardIsTypo = !judge.isKnown(hl) || (judge.count(hl) ?? 0) < Rules.rareCount
            guard heardIsTypo, h == hl || h == h.prefix(1).uppercased() + hl.dropFirst(),
                  judge.isKnown(wl), (judge.count(wl) ?? 0) >= Rules.rareCount,
                  hl.count >= 2, LearnedWordRules.editDistance(hl, wl) <= max(2, wl.count / 3),
                  !TypoRepair.slang.contains(hl) else { return nil }
            return Classified(kind: .spelling, replaces: true, clearName: false)
        }
        // Several words: only a misheard name or term ("acme max" -> "AcmeX", "trace appetite" -> "trizepatide").
        let writtenIsTerm = writtenWords.contains { isNameLike($0, atSentenceStart: false, judge: judge) }
            && writtenWords.count <= 2
        guard writtenIsTerm else { return nil }
        guard pair.heard.lowercased().filter(\.isLetter) != pair.written.lowercased().filter(\.isLetter)
                || hasInnerCapital(pair.written) else {
            // Only spacing or casing ("acme hub" -> "AcmeHub"): a name, kept as spelled.
            return Classified(kind: .phrase, replaces: true, clearName: true)
        }
        let replaces = heardWords.count > 1 || isSafeHeard(heardWords[0], judge: judge)
        return Classified(kind: .phrase, replaces: replaces, clearName: false)
    }

    /// A name, product or term: not an everyday word, and either capitalised his way or unknown to the list.
    static func isNameLike(_ word: String, atSentenceStart: Bool, judge: WordJudge) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        let lower = word.lowercased()
        guard !LearnedWordRules.functionWords.contains(lower), !Rules.everyday.contains(lower) else { return false }
        if let c = judge.count(lower), c >= Rules.commonCount { return false }
        if hasInnerCapital(word) { return true }
        if word.first?.isUppercase == true, !atSentenceStart { return true }
        // Lowercase or sentence-initial: only when the word list does not know it ("searxng", "lfm").
        return !judge.isKnown(lower) && letters.count >= 3
    }

    /// The heard form may be replaced everywhere: not an everyday word on its own.
    static func isSafeHeard(_ word: String, judge: WordJudge) -> Bool {
        let lower = word.lowercased()
        guard lower.filter(\.isLetter).count >= 3, !LearnedWordRules.functionWords.contains(lower),
              !Rules.everyday.contains(lower) else { return false }
        // "e-commerce": a hyphenated everyday word is an everyday word.
        let parts = lower.split(whereSeparator: { $0 == "-" || $0 == "'" }).map(String.init).filter { $0.count >= 3 }
        if parts.count > 1, parts.contains(where: { (judge.count($0) ?? 0) >= Rules.commonCount }) { return false }
        return (judge.count(lower) ?? 0) < Rules.commonCount
    }

    static func hasInnerCapital(_ word: String) -> Bool {
        let chars = Array(word)
        guard chars.count >= 2 else { return false }
        if chars.dropFirst().contains(where: \.isUppercase) { return true }
        return chars.contains(where: \.isNumber) && chars.contains(where: \.isLetter)
    }

    private static func digits(_ s: String) -> String { String(s.filter(\.isNumber)) }

    // MARK: Pair extraction

    private static let tokenPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*"#)
    private static let skipPattern = try! NSRegularExpression(pattern:
        #"`[^`\n]*`|https?://\S+|www\.\S+|[\w.+-]+@[\w-]+(?:\.[\w-]+)+|(?<![\w])[~/][\w.\-/]+"#)

    struct Token { let text: String; let sentenceStart: Bool }

    static func tokens(_ text: String) -> [Token] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let skip = skipPattern.matches(in: text, range: whole).map(\.range)
        var out: [Token] = []
        for m in tokenPattern.matches(in: text, range: whole) {
            if skip.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                out.append(Token(text: "\u{1}" + ns.substring(with: m.range), sentenceStart: false))
                continue
            }
            var j = m.range.location - 1
            while j >= 0, let c = Unicode.Scalar(ns.character(at: j)), c == " " || c == "\t" || c == "\"" || c == "(" { j -= 1 }
            let start = j < 0 || [".", "!", "?", "\n", ":", "-", "*", "•"].contains(ns.substring(with: NSRange(location: j, length: 1)))
            out.append(Token(text: ns.substring(with: m.range), sentenceStart: start))
        }
        return out
    }

    /// Word swaps between two texts: runs of 1-3 changed words on both sides. Insertions, deletions, links
    /// and code are ignored; a text where too much changed is a rewrite and gives nothing.
    static func substitutions(before: String, after: String) -> [Pair] {
        let a = tokens(before), b = tokens(after)
        let m = a.count, n = b.count
        guard m > 0, n > 0, m <= 600, n <= 600 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                dp[i][j] = a[i].text == b[j].text ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var blocks: [(ArraySlice<Token>, ArraySlice<Token>)] = []
        var i = 0, j = 0
        var bi = 0, bj = 0
        func close() {
            if i > bi || j > bj { blocks.append((a[bi..<i], b[bj..<j])) }
        }
        while i < m || j < n {
            if i < m, j < n, a[i].text == b[j].text {
                close(); i += 1; j += 1; bi = i; bj = j
            } else if j >= n || (i < m && dp[i + 1][j] >= dp[i][j + 1]) {
                i += 1
            } else {
                j += 1
            }
        }
        close()
        var changedWords = 0
        var pairs: [Pair] = []
        for (old, new) in blocks {
            let caseOnly = old.count == new.count && zip(old, new).allSatisfy { $0.text.lowercased() == $1.text.lowercased() }
            if !caseOnly { changedWords += max(old.count, new.count) }
            guard !old.isEmpty, !new.isEmpty, old.count <= 3, new.count <= 3 else { continue }
            if (old + new).contains(where: { $0.text.hasPrefix("\u{1}") }) { continue }
            if old.count == new.count, old.count > 1 {
                for (o, w) in zip(old, new) where o.text != w.text {
                    pairs.append(Pair(heard: o.text, written: w.text, writtenAtSentenceStart: w.sentenceStart))
                }
            } else {
                pairs.append(Pair(heard: old.map(\.text).joined(separator: " "), written: new.map(\.text).joined(separator: " "),
                                  writtenAtSentenceStart: new.first!.sentenceStart))
            }
        }
        guard Double(changedWords) <= max(3, Rules.maxChangedShare * Double(m)) else { return [] }
        return pairs
    }

    static func clip(_ text: String, around word: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > Rules.exampleChars else { return flat }
        guard let r = flat.range(of: word) else { return String(flat.prefix(Rules.exampleChars)) }
        let center = flat.distance(from: flat.startIndex, to: r.lowerBound)
        let start = max(0, min(center - Rules.exampleChars / 2, flat.count - Rules.exampleChars))
        let s = flat.index(flat.startIndex, offsetBy: start)
        return String(flat[s..<flat.index(s, offsetBy: Rules.exampleChars)])
    }

    // MARK: Storage

    private struct File: Codable {
        var version: Int
        var entries: [AutoDictionaryEntry]
    }

    private func reloadIfChangedLocked(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(checkedAt) > 1 else { return }
        checkedAt = now
        let stamp = (try? FileManager.default.attributesOfItem(atPath: storeURL.path))?[.modificationDate] as? Date
        guard force || stamp != loadedStamp else { return }
        loadedStamp = stamp
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: storeURL), let file = try? decoder.decode(File.self, from: data) {
            entries = Dictionary(file.entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        } else if !force {
            entries = [:]
        }
        revision += 1
        if force { mirrorLocked() }
    }

    private func saveLocked() {
        revision += 1
        if suspendSaves { return }
        do {
            let dir = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let list = entries.values.sorted { ($0.status.rawValue, $0.written.lowercased()) < ($1.status.rawValue, $1.written.lowercased()) }
            try encoder.encode(File(version: 1, entries: list)).write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
            var spellings: [String: String] = [:]
            for e in entries.values where e.status == .live && e.kind == .spelling { spellings[e.heard.lowercased()] = e.written }
            try encoder.encode(spellings).write(to: overlayURL, options: .atomic)
            loadedStamp = (try? FileManager.default.attributesOfItem(atPath: storeURL.path))?[.modificationDate] as? Date
        } catch {
            print("[VOICE-AUTODICT] could not save the learned dictionary: \(error.localizedDescription)")
        }
        mirrorLocked()
        if settings != nil { FlowBroadcast.changed("dictionary") }
    }

    /// The short review list in Flow's settings, for Companion: newest first, live and pending only.
    private func mirrorLocked() {
        guard let settings else { return }
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = entries.values.filter { $0.status != .removed }
            .sorted { $0.lastSeen > $1.lastSeen }.prefix(200).map { e in
                var row: [String: Any] = ["heard": e.heard, "written": e.written, "kind": e.kind.rawValue,
                                          "status": e.status.rawValue, "count": e.count, "lastSeen": iso.string(from: e.lastSeen)]
                if let ex = e.examples.last { row["example"] = ex.after; row["source"] = ex.source }
                return row
            }
        settings.set(rows, forKey: Self.settingsKey)
    }
}
