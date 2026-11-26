// AutoDictionary.swift
//
// Flow's self-learning dictionary (22 Nov 2026). It learns from what Jordan fixes, not from what he says.
//
// EVIDENCE
//   - A dictation he edits in the field after the paste (CorrectionLearner reads it back via Accessibility).
//   - An Opt+1 result left in the field (weak evidence, never sufficient on its own).
//   - A name he keeps writing across dictations (ProperNounVocabulary.learnFrom).
//   - History: his Wispr Flow edits and Flow's own saved edits (AutoDictionarySeed).
//   Negative evidence: Opt+1 Undo, and editing a learned fix back to what was heard.
//
// RULES (AutoDictionary.Rules)
//   - Each fix becomes heard -> written. Only small swaps count: 1-3 words for 1-3 words, never a rewrite.
//   - Never a common English word as the written side, never a change of meaning: two ordinary words
//     ("pale" -> "start"), a changed number, an added or dropped negation are all thrown away.
//   - Promotion: a clear name he typed himself goes live on first sight; everything else needs 2 independent
//     sightings and a user edit (a recurring name needs 3, vocabulary only). Pending entries decay after 60 days.
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
    /// Stable run IDs (or a context fingerprint for old callers) and their evidence source.
    /// Optional so version-one stores remain readable.
    var observations: [String: String]? = nil
    /// Weak model observations must not make an older imported spelling look newer.
    var lastOwnEditAt: Date? = nil

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
        static let maxEvidenceRecords = 128
        static let maxPassiveEvidence = 8
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
    static let persistenceSettingsKey = "voice.autoDictionaryPersistence"

    struct PersistenceState: Equatable, Sendable {
        enum Status: String, Sendable { case ready, readFailed, unsupportedVersion, writeFailed, overlayFailed, externalConflict, privacyPaused }
        let status: Status
        let unsavedChanges: Bool
    }

    // Separate readers/tools in this process must not overwrite one another's
    // newer observations. Weak entries keep temporary/test stores bounded.
    private final class LockReference {
        weak var value: NSRecursiveLock?
        init(_ value: NSRecursiveLock) { self.value = value }
    }
    private static let storeLocksLock = NSLock()
    nonisolated(unsafe) private static var storeLocks: [String: LockReference] = [:]
    private static func sharedLock(for url: URL) -> NSRecursiveLock {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        storeLocksLock.lock(); defer { storeLocksLock.unlock() }
        if let lock = storeLocks[path]?.value { return lock }
        storeLocks = storeLocks.filter { $0.value.value != nil }
        let lock = NSRecursiveLock()
        storeLocks[path] = LockReference(lock)
        return lock
    }

    let storeURL: URL
    let overlayURL: URL
    /// Where the short review list goes. nil: not mirrored (CLI tools).
    private let settings: UserDefaults?
    private let lock: NSRecursiveLock
    private let writeData: @Sendable (Data, URL) throws -> Void
    private var entries: [String: AutoDictionaryEntry] = [:]
    private var loadedStamp: PrivateDataFile.Identity?
    private var hasLoaded = false
    private var checkedAt = Date.distantPast
    /// Bumped on every change; consumers cache on it.
    private(set) var revision = 0
    private var cachedLiveSnapshot: LiveSnapshot?
    /// A delayed keep or replay must not revive an operation that was already undone.
    private var undoneOperations: Set<String> = []
    private var batchDepth = 0
    private var dirty = false
    private var overlayDirty = false
    private var storageReadable = true
    private var persistenceStatus: PersistenceState.Status = .ready
    var judgeProvider: () -> WordJudge? = { WordJudge.lexicon(wait: false) }

    init(directory: URL, settings: UserDefaults? = AutoDictionary.defaultSettings,
         writeData: @escaping @Sendable (Data, URL) throws -> Void = { try PrivateDataFile.replace($0, at: $1) }) {
        storeURL = directory.appendingPathComponent("auto-dictionary.json")
        overlayURL = directory.appendingPathComponent("typo_dictionary.user.json")
        lock = Self.sharedLock(for: storeURL)
        self.settings = settings
        self.writeData = writeData
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

    struct LiveSnapshot: Sendable {
        struct Replacement: Sendable {
            let heard: String
            let written: String
        }
        let revision: Int
        let names: [String]
        let replacements: [Replacement]
        let spellings: [String: String]
        let soundAlikes: Set<String>
        let conflictingAliases: Set<String>
    }

    /// An alias with more than one learned target needs context. Keep the terms
    /// as vocabulary, but never let dictionary iteration order choose a rewrite.
    /// Check across all kinds so a spelling cannot disagree with a learned name.
    private static func unambiguousLiveEntries(_ entries: [AutoDictionaryEntry]) -> [AutoDictionaryEntry] {
        let active = entries.filter { $0.status == .live }
        var targets: [String: Set<String>] = [:]
        for entry in active { targets[normalized(entry.heard), default: []].insert(normalized(entry.written)) }
        return active.filter { targets[normalized($0.heard)]?.count == 1 }
    }

    /// One atomic, cached view for consumers. Repeated reads do not regroup/sort the whole store.
    func liveSnapshot() -> LiveSnapshot {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        if let snapshot = cachedLiveSnapshot, snapshot.revision == revision { return snapshot }
        let active = entries.values.filter { $0.status == .live }.sorted {
            let aOwn = $0.sources.contains { Source(rawValue: $0.key)?.isOwnEdit == true && $0.value > 0 }
            let bOwn = $1.sources.contains { Source(rawValue: $0.key)?.isOwnEdit == true && $0.value > 0 }
            if aOwn != bOwn { return aOwn }
            let a = $0.lastOwnEditAt ?? $0.lastSeen, b = $1.lastOwnEditAt ?? $1.lastSeen
            return a == b ? $0.key < $1.key : a > b
        }
        let mappings = Self.unambiguousLiveEntries(active)
        let allowed = Set(mappings.map(\.key))
        let conflicts = Set(active.filter { !allowed.contains($0.key) }.map { Self.normalized($0.heard) })
        var names: [String: String] = [:]
        for entry in active where entry.kind == .name || entry.kind == .phrase {
            let key = Self.normalized(entry.written)
            if names[key] == nil { names[key] = entry.written }
        }
        let replacements = mappings.filter {
            ($0.kind == .name || $0.kind == .phrase) && $0.replaces && Self.normalized($0.heard) != Self.normalized($0.written)
        }.sorted { $0.heard < $1.heard }.map {
            LiveSnapshot.Replacement(heard: $0.heard.lowercased(), written: names[Self.normalized($0.written)] ?? $0.written)
        }
        var spellings: [String: String] = [:]
        for entry in mappings where entry.kind == .spelling { spellings[entry.heard.lowercased()] = entry.written }
        let snapshot = LiveSnapshot(revision: revision, names: names.values.sorted(), replacements: replacements,
            spellings: spellings, soundAlikes: Set(active.filter { $0.kind == .soundAlike }.map(\.key)),
            conflictingAliases: conflicts)
        cachedLiveSnapshot = snapshot
        return snapshot
    }

    /// Learned names and terms: the speech model boosts them and the polish keeps their spelling.
    func liveNames() -> [String] {
        liveSnapshot().names
    }

    /// Learned heard -> written replacements (names and phrases).
    func liveReplacements() -> [(heard: String, written: String)] {
        liveSnapshot().replacements.map { ($0.heard, $0.written) }
    }

    /// Learned misspellings, lowercase keys: the user overlay of the typo dictionary.
    func liveSpellings() -> [String: String] {
        liveSnapshot().spellings
    }

    /// Learned sound-alike directions, "whether" -> "weather".
    func liveSoundAlikes() -> Set<String> {
        liveSnapshot().soundAlikes
    }

    var currentRevision: Int {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        return revision
    }

    var persistenceState: PersistenceState {
        lock.lock(); defer { lock.unlock() }
        return PersistenceState(status: persistenceStatus, unsavedChanges: dirty || overlayDirty)
    }

    /// Retry a failed write without adding another observation. This never
    /// discards the in-memory correction or overwrites changed external data.
    @discardableResult
    func flush() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Self.learningEnabled else { return false }
        if !dirty { reloadIfChangedLocked(force: true) }
        saveLocked()
        return !dirty && !overlayDirty && storageReadable
    }

    // MARK: Learning

    /// One piece of evidence: Flow wrote `before`, Jordan (or a kept Opt+1) made it `after`.
    @discardableResult
    func observe(before: String, after: String, source: Source, now: Date = Date(),
                 operation: UUID? = nil, evidenceID: String? = nil, judge: WordJudge? = nil) -> [Event] {
        guard Self.learningEnabled, before != after, let judge = judge ?? judgeProvider() else { return [] }
        let pairs = Self.substitutions(before: before, after: after)
        guard !pairs.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard beginMutationLocked(), Self.learningEnabled else { return [] }
        let observation = Self.observationID(evidenceID ?? operation?.uuidString, source: source, before: before, after: after)
        guard !undoneOperations.contains(observation) else { return [] }
        var events: [Event] = []
        var seenPairs = Set<String>()
        let ambiguousHeard = Set(Dictionary(grouping: pairs, by: { $0.heard.lowercased() })
            .filter { Set($0.value.map { $0.written.lowercased() }).count > 1 }.keys)
        for pair in pairs.prefix(Rules.maxPairsPerObservation) {
            guard !ambiguousHeard.contains(pair.heard.lowercased()) else { continue }
            guard seenPairs.insert(Self.key(pair.heard, pair.written)).inserted else { continue }
            // Editing a learned fix back is an undo of that fix, never a new fix the other way.
            // (Sound-alikes go both ways in different sentences, so they are only counted.)
            if let reverse = entries[Self.key(pair.written, pair.heard)], reverse.kind != .soundAlike {
                // Replaying an older history edit must not veto newer user evidence.
                if source.isOwnEdit, reverse.status == .live, now >= (reverse.lastOwnEditAt ?? reverse.lastSeen),
                   let e = undoLocked(key: reverse.key, now: now) { events.append(e) }
                continue
            }
            guard let classified = Self.classify(pair, judge: judge) else { continue }
            // A misspelling is stored lowercase: "Teh" at a sentence start teaches "teh" -> "the".
            let pair = classified.kind == .spelling
                ? Pair(heard: pair.heard.lowercased(), written: pair.written.lowercased(), writtenAtSentenceStart: false) : pair
            if source.isOwnEdit {
                guard let retractions = retractEarlierSnapshotLocked(pair: pair, observation: observation, now: now) else { continue }
                events += retractions
            }
            let example = AutoDictionaryEntry.Example(before: Self.clip(before, around: pair.heard),
                                                     after: Self.clip(after, around: pair.written),
                                                     source: source.rawValue, at: now)
            if let e = sightLocked(pair: pair, kind: classified.kind, replaces: classified.replaces,
                                   clearName: classified.clearName, source: source, example: example,
                                   observation: observation, now: now) {
                events.append(e)
            }
        }
        pruneLocked(now: now)
        saveLocked()
        return events
    }

    /// A fix known only as the two words (Wispr's dictionary rows): no sentence around it.
    @discardableResult
    func observePair(heard: String, written: String, source: Source, now: Date = Date(),
                     evidenceID: String? = nil, judge: WordJudge? = nil) -> [Event] {
        guard Self.learningEnabled, let judge = judge ?? judgeProvider() else { return [] }
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines), w = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !w.isEmpty, h != w,
              h.split(whereSeparator: \.isWhitespace).count <= 3, w.split(whereSeparator: \.isWhitespace).count <= 3,
              !h.unicodeScalars.contains(where: CharacterSet.newlines.contains),
              !w.unicodeScalars.contains(where: CharacterSet.newlines.contains) else { return [] }
        var pair = Pair(heard: h, written: w, writtenAtSentenceStart: false)
        guard let classified = Self.classify(pair, judge: judge) else { return [] }
        if classified.kind == .spelling { pair = Pair(heard: h.lowercased(), written: w.lowercased(), writtenAtSentenceStart: false) }
        lock.lock(); defer { lock.unlock() }
        guard beginMutationLocked(), Self.learningEnabled else { return [] }
        let observation = Self.observationID(evidenceID, source: source, before: h, after: w)
        guard !undoneOperations.contains(observation) else { return [] }
        if let reverse = entries[Self.key(w, h)], reverse.kind != .soundAlike { return [] }
        var events: [Event] = []
        if source.isOwnEdit {
            guard let retractions = retractEarlierSnapshotLocked(pair: pair, observation: observation, now: now) else { return [] }
            events += retractions
        }
        let example = AutoDictionaryEntry.Example(before: h, after: w, source: source.rawValue, at: now)
        let event = sightLocked(pair: pair, kind: classified.kind, replaces: classified.replaces,
                                clearName: classified.clearName, source: source, example: example,
                                observation: observation, now: now)
        pruneLocked(now: now)
        saveLocked()
        if let event { events.append(event) }
        return events
    }

    /// Many observations, one save at the end (the history seed).
    func batch(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard beginMutationLocked() else { return }
        batchDepth += 1
        defer { batchDepth -= 1; saveLocked() }
        body()
    }

    /// Empties the store (tests).
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        guard beginMutationLocked(), !entries.isEmpty || !undoneOperations.isEmpty else { return }
        entries = [:]
        undoneOperations = []
        markChangedLocked()
        saveLocked(allowDuringPrivacy: true)
    }

    /// A name seen again in his own dictations (no fix involved): vocabulary only, after 3 sightings.
    @discardableResult
    func observeRecurringName(_ name: String, context: String, now: Date = Date(),
                              evidenceID: String? = nil, judge: WordJudge? = nil) -> [Event] {
        guard Self.learningEnabled, let judge = judge ?? judgeProvider() else { return [] }
        let word = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isNameLike(word, atSentenceStart: false, judge: judge) else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard beginMutationLocked(), Self.learningEnabled else { return [] }
        let example = AutoDictionaryEntry.Example(before: Self.clip(context, around: word), after: Self.clip(context, around: word),
                                                 source: Source.recurringName.rawValue, at: now)
        let event = sightLocked(pair: Pair(heard: word, written: word, writtenAtSentenceStart: false), kind: .name,
                                replaces: false, clearName: false, source: .recurringName, example: example,
                                observation: Self.observationID(evidenceID, source: .recurringName,
                                                                before: context, after: context), now: now)
        pruneLocked(now: now)
        saveLocked()
        return event.map { [$0] } ?? []
    }

    /// Opt+1 Undo: every learned fix the undone edit made is taken out, and a keep it counted is taken back.
    @discardableResult
    func observeUndo(original: String, candidate: String, operation: UUID? = nil, evidenceID: String? = nil,
                     now: Date = Date()) -> [Event] {
        lock.lock(); defer { lock.unlock() }
        guard beginMutationLocked() else { return [] }
        let observation = Self.observationID(evidenceID ?? operation?.uuidString, source: .opt1Kept, before: original, after: candidate)
        guard undoneOperations.insert(observation).inserted else { return [] }
        markChangedLocked()
        var events: [Event] = []
        let persisted = entries.values.filter { $0.observations?[observation] == Source.opt1Kept.rawValue }.map(\.key)
        for key in persisted {
            guard var e = entries[key] else { continue }
            guard e.observations?.removeValue(forKey: observation) == Source.opt1Kept.rawValue else { continue }
            e.count = max(0, e.count - 1)
            e.sources[Source.opt1Kept.rawValue] = max(0, (e.sources[Source.opt1Kept.rawValue] ?? 1) - 1)
            setEntryLocked(e.count == 0 && e.status == .pending ? nil : e, for: key)
        }
        for pair in Self.substitutions(before: original, after: candidate) {
            let key = Self.key(pair.heard, pair.written)
            // Importing an old Undo still revokes that operation's vote, but
            // must not veto a correction the user independently made later.
            if let entry = entries[key], entry.status == .live,
               now >= (entry.lastOwnEditAt ?? entry.lastSeen), let event = undoLocked(key: key, now: now) {
                events.append(event)
            }
        }
        saveLocked(allowDuringPrivacy: true)
        return events
    }

    /// Jordan removes a learned word himself (Settings): out for good.
    func remove(written: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard beginMutationLocked() else { return }
        let target = Self.normalized(written)
        var changed = false
        for (key, var e) in entries where Self.normalized(e.written) == target && e.status != .removed {
            e.status = .removed
            e.removedAt = now
            e.undos = max(e.undos, Rules.permanentUndos)
            setEntryLocked(e, for: key)
            changed = true
        }
        if changed { saveLocked(allowDuringPrivacy: true) }
    }

    // MARK: Evidence rules

    private func sightLocked(pair: Pair, kind: AutoDictionaryEntry.Kind, replaces: Bool, clearName: Bool,
                             source: Source, example: AutoDictionaryEntry.Example,
                             observation: String, now: Date) -> Event? {
        let key = Self.key(pair.heard, pair.written)
        var e = entries[key] ?? AutoDictionaryEntry(
            heard: pair.heard, written: pair.written, kind: kind, status: .pending, count: 0, undos: 0,
            firstSeen: now, lastSeen: now, liveSince: nil, removedAt: nil, replaces: replaces, examples: [], sources: [:])
        if e.status == .removed {
            // Out for good after two undos; otherwise back to pending only after the cooldown.
            guard source.isOwnEdit, e.undos < Rules.permanentUndos, let at = e.removedAt,
                  now.timeIntervalSince(at) >= Rules.undoCooldownSeconds else { return nil }
            e.status = .pending
            e.count = 0
            e.sources = [:]
            e.observations = [:]
            e.liveSince = nil
            e.lastOwnEditAt = nil
            e.removedAt = nil
        }
        let hasOwnEvidence = e.sources.contains { Source(rawValue: $0.key)?.isOwnEdit == true && $0.value > 0 }
        let previousOwnDate = e.lastOwnEditAt ?? (hasOwnEvidence ? e.lastSeen : .distantPast)
        func refreshOwnSpelling() {
            guard source.isOwnEdit, now >= previousOwnDate else { return }
            if pair.written.lowercased() == e.written.lowercased() { e.written = pair.written }
            e.lastOwnEditAt = now
            e.lastSeen = max(e.lastSeen, now)
        }
        var observations = e.observations ?? [:]
        if let previous = observations[observation] {
            // A user edit can strengthen evidence from the same run, but it
            // is still one observation. Repeated polling never adds a vote.
            guard source.isOwnEdit, Source(rawValue: previous)?.isOwnEdit != true else {
                if pair.written != e.written { refreshOwnSpelling(); setEntryLocked(e, for: key) }
                return nil
            }
            e.sources[previous] = max(0, (e.sources[previous] ?? 0) - 1)
        } else {
            // Keep the persisted evidence ledger bounded without forgetting
            // identities and then counting an old replay as new evidence.
            guard observations.count < Rules.maxEvidenceRecords else {
                refreshOwnSpelling()
                setEntryLocked(e, for: key)
                return nil
            }
            if source == .opt1Kept, (e.sources[source.rawValue] ?? 0) >= Rules.maxPassiveEvidence { return nil }
            e.count += 1
        }
        observations[observation] = source.rawValue
        e.observations = observations
        refreshOwnSpelling()
        e.lastSeen = max(e.lastSeen, now)
        e.sources[source.rawValue, default: 0] += 1
        if !e.examples.contains(where: { $0.before == example.before && $0.after == example.after }) {
            e.examples.append(example)
            if e.examples.count > Rules.maxExamples { e.examples.removeFirst(e.examples.count - Rules.maxExamples) }
        }
        var event: Event?
        if e.status == .pending, Self.hasPromotionEvidence(e),
           e.count >= Self.needed(kind: e.kind, source: source, clearName: clearName) {
            let liveCount = entries.values.filter { $0.status == .live }.count
            if liveCount < Rules.maxLive {
                e.status = .live
                e.liveSince = now
                event = Event(change: .promoted, heard: e.heard, written: e.written, kind: e.kind)
            }
        }
        setEntryLocked(e, for: key)
        return event
    }

    /// A later settled read of the same edit supersedes its earlier target.
    /// An old imported snapshot cannot restore that superseded vote.
    private func retractEarlierSnapshotLocked(pair: Pair, observation: String, now: Date) -> [Event]? {
        let conflicts = entries.values.filter {
            $0.heard.lowercased() == pair.heard.lowercased() && $0.written.lowercased() != pair.written.lowercased()
                && $0.observations?[observation] != nil
        }
        guard !conflicts.contains(where: { ($0.lastOwnEditAt ?? $0.lastSeen) > now }) else { return nil }
        var events: [Event] = []
        for var entry in conflicts {
            guard let previous = entry.observations?.removeValue(forKey: observation) else { continue }
            entry.count = max(0, entry.count - 1)
            entry.sources[previous] = max(0, (entry.sources[previous] ?? 1) - 1)
            let wasLive = entry.status == .live
            if entry.count == 0 || !Self.hasPromotionEvidence(entry) {
                entry.status = .pending
                entry.liveSince = nil
            }
            setEntryLocked(entry.count == 0 ? nil : entry, for: entry.key)
            if wasLive && entry.status != .live {
                events.append(Event(change: .removed, heard: entry.heard, written: entry.written, kind: entry.kind))
            }
        }
        return events
    }

    /// Model output left on screen is weak evidence. Only recurring names
    /// without text replacements may become vocabulary without a user edit.
    private static func hasPromotionEvidence(_ entry: AutoDictionaryEntry) -> Bool {
        if entry.sources.contains(where: { Source(rawValue: $0.key)?.isOwnEdit == true && $0.value > 0 }) { return true }
        return !entry.replaces && entry.heard.lowercased() == entry.written.lowercased()
            && (entry.sources[Source.recurringName.rawValue] ?? 0) >= Rules.recurringNameSightings
    }

    /// Stable across processes and imports. The fingerprint is only for
    /// duplicate detection, not authentication or privacy protection.
    static func observationID(_ id: String?, source: Source, before: String, after: String) -> String {
        if let id, !id.isEmpty { return "run:" + (UUID(uuidString: id)?.uuidString.lowercased() ?? id) }
        let text = source.rawValue + "\u{1F}" + before + "\u{1F}" + after
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return "context:" + String(hash, radix: 16)
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
        e.sources = [:]
        e.observations = [:]
        e.liveSince = nil
        e.lastOwnEditAt = nil
        setEntryLocked(e, for: key)
        return wasLive ? Event(change: .removed, heard: e.heard, written: e.written, kind: e.kind) : nil
    }

    private func pruneLocked(now: Date) {
        for (key, e) in entries where e.status == .pending && now.timeIntervalSince(e.lastSeen) > Rules.pendingDecaySeconds {
            setEntryLocked(nil, for: key)
        }
        let pending = entries.values.filter { $0.status == .pending }
        if pending.count > Rules.maxPending {
            let drop = pending.sorted { ($0.count, $0.lastSeen) < ($1.count, $1.lastSeen) }.prefix(pending.count - Rules.maxPending)
            for e in drop { setEntryLocked(nil, for: e.key) }
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
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
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

    private static var learningEnabled: Bool { !UserDefaults.standard.bool(forKey: "voice.privacyMode") }

    private func markChangedLocked() {
        dirty = true
        revision &+= 1
        cachedLiveSnapshot = nil
    }

    private func setEntryLocked(_ entry: AutoDictionaryEntry?, for key: String) {
        guard entries[key] != entry else { return }
        entries[key] = entry
        markChangedLocked()
    }

    private func beginMutationLocked() -> Bool {
        // Hot reads are throttled, but a writer must first see another writer's
        // committed state. Never replace local changes whose save failed.
        if batchDepth == 0 && !dirty { reloadIfChangedLocked(force: true) }
        return storageReadable
    }

    private func fileStamp() throws -> PrivateDataFile.Identity? { try PrivateDataFile.identity(at: storeURL) }

    private func setPersistenceStatus(_ status: PersistenceState.Status) {
        persistenceStatus = status
        settings?.set(["status": status.rawValue, "unsavedChanges": dirty || overlayDirty], forKey: Self.persistenceSettingsKey)
    }

    private struct File: Codable {
        var version: Int
        var entries: [AutoDictionaryEntry]
        var undoneOperations: [String]? = nil
    }

    private func reloadIfChangedLocked(force: Bool = false) {
        guard !dirty, batchDepth == 0 else { return }
        let now = Date()
        guard force || now.timeIntervalSince(checkedAt) > 1 else { return }
        checkedAt = now
        do {
            let stamp = try fileStamp()
            guard !hasLoaded || stamp != loadedStamp || !storageReadable else { return }
            var loaded: [String: AutoDictionaryEntry] = [:]
            var undone: Set<String> = []
            if stamp != nil {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let data = try PrivateDataFile.read(storeURL) else { throw CocoaError(.fileReadNoSuchFile) }
                let file = try decoder.decode(File.self, from: data)
                guard (1...2).contains(file.version) else {
                    storageReadable = false
                    setPersistenceStatus(.unsupportedVersion)
                    return
                }
                guard file.entries.allSatisfy({ $0.count >= 0 && $0.undos >= 0 && $0.sources.values.allSatisfy { $0 >= 0 } }),
                      stamp == (try fileStamp()) else { throw CocoaError(.fileReadCorruptFile) }
                loaded = Dictionary(file.entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                undone = Set(file.undoneOperations ?? [])
            }
            if !hasLoaded || entries != loaded || undoneOperations != undone {
                entries = loaded
                undoneOperations = undone
                revision &+= 1
                cachedLiveSnapshot = nil
            }
            loadedStamp = stamp
            hasLoaded = true
            storageReadable = true
            setPersistenceStatus(.ready)
        } catch {
            // A partial external write, permissions failure or corrupt JSON is
            // not a request to forget the user's words. Retry on the next read;
            // never mark the failed stamp loaded or overwrite those bytes.
            storageReadable = false
            setPersistenceStatus(.readFailed)
            return
        }
        // Older builds promoted passive model output by repeated keeps. Keep
        // those entries visible for review but stop applying them automatically.
        var repaired = false
        for (key, var e) in entries where e.status == .live && !Self.hasPromotionEvidence(e) {
            e.status = .pending
            e.liveSince = nil
            setEntryLocked(e, for: key)
            repaired = true
        }
        // The overlay is derived, never evidence. Repair an interrupted second
        // write (or an older build's conflicting alias) after a restart too.
        if loadedStamp != nil {
            let stored = (try? PrivateDataFile.read(overlayURL)).flatMap {
                try? JSONDecoder().decode([String: String].self, from: $0)
            }
            overlayDirty = stored != spellingOverlayLocked()
        }
        if repaired || overlayDirty { saveLocked() }
        else if force { mirrorLocked() }
    }

    private func spellingOverlayLocked() -> [String: String] {
        var spellings: [String: String] = [:]
        for e in Self.unambiguousLiveEntries(Array(entries.values)) where e.kind == .spelling {
            spellings[e.heard.lowercased()] = e.written
        }
        return spellings
    }

    private func acceptPublishedWriteLocked(_ data: Data) throws -> Bool {
        // A file editor need not take our advisory lock. Bind the cache to the
        // bytes we actually published, never to its intervening replacement.
        let stamp = try fileStamp()
        guard stamp != nil, try PrivateDataFile.read(storeURL) == data, try fileStamp() == stamp else {
            setPersistenceStatus(.externalConflict)
            return false
        }
        loadedStamp = stamp
        return true
    }

    private func saveLocked(allowDuringPrivacy: Bool = false) {
        guard batchDepth == 0, dirty || overlayDirty, storageReadable else { return }
        guard allowDuringPrivacy || Self.learningEnabled else { setPersistenceStatus(.privacyPaused); return }
        do {
            try PrivateDataFile.withExclusiveAccess(to: storeURL) {
                guard allowDuringPrivacy || Self.learningEnabled else { setPersistenceStatus(.privacyPaused); return }
                guard try fileStamp() == loadedStamp else {
                    setPersistenceStatus(.externalConflict)
                    return
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if dirty {
                    let list = entries.values.sorted {
                        ($0.status.rawValue, $0.written.lowercased(), $0.key) < ($1.status.rawValue, $1.written.lowercased(), $1.key)
                    }
                    let data = try encoder.encode(File(version: 2, entries: list, undoneOperations: undoneOperations.sorted()))
                    do {
                        try writeData(data, storeURL)
                    } catch PrivateDataFile.PersistenceError.synchronizationAfterPublishFailed {
                        // Rename completed, but the directory sync did not.
                        // Keep the write dirty and recognize our own published
                        // bytes so retry is not mistaken for an external edit.
                        guard try acceptPublishedWriteLocked(data) else { return }
                        throw PrivateDataFile.PersistenceError.synchronizationAfterPublishFailed
                    }
                    guard try acceptPublishedWriteLocked(data) else { return }
                    dirty = false
                    overlayDirty = true
                }
                do {
                    try writeData(encoder.encode(spellingOverlayLocked()), overlayURL)
                    overlayDirty = false
                    setPersistenceStatus(.ready)
                } catch {
                    setPersistenceStatus(.overlayFailed)
                }
            }
        } catch {
            setPersistenceStatus(.writeFailed)
            print("[VOICE-AUTODICT] could not persist the learned dictionary; in-memory corrections retained")
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
