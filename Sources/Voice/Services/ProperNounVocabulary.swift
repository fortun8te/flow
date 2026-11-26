// ProperNounVocabulary.swift
//
// Builds and persists a user-specific proper-noun vocabulary that gets
// fed into the polish prompt and the EntityFreezer. Solves the "Wispr
// Flow → Whisperflo" class of bug where the LLM doesn't know a term is
// a fixed brand name and helpfully "corrects" it.
//
// Sources of vocabulary (in priority order):
//   1. Manually added terms (UserDefaults, future settings UI)
//   2. Frequently-appearing capitalized n-grams in past dictations
//   3. macOS Contacts first/last names (defer — needs permission)
//   4. A seed list of common brands/products (Wispr Flow, ChatGPT, Claude…)
//
// The auto-learning step uses raw recognition text and prior committed
// recognitions from other recordings. Capitalized terms seen in 2+ prior
// dictations become recurring-name observations, keyed by recording ID.
// AutoDictionary applies its independent-evidence rules before adding
// vocabulary; cleanup output never supplies these observations.

import Foundation

public enum ProperNounVocabulary {
    private static let key = "userProperNouns"
    private static let maxTerms = 600
    private static let mutationLock = NSRecursiveLock()

    private static let seedTerms = [
        "Wispr Flow", "ChatGPT", "OpenAI", "Claude", "Claude Code",
        "Qwen", "GitHub", "SwiftUI", "macOS",
    ]

    static let excludedTermsKey = "voice.dictionaryExcludedTerms"

    static func excludedTerms(defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.stringArray(forKey: excludedTermsKey) ?? []).map(VocabularyReplacementRules.key).filter { !$0.isEmpty })
    }

    static func preferredSpellingTerms() -> [String] {
        customTerms() + UserDictionary.terms()
    }

    /// Public product spellings for a few common phonetic confusions.
    static let heardNameFixes: [(heard: String, written: String)] = [
        ("whisper flow", "Wispr Flow"), ("whisperflow", "Wispr Flow"),
        ("quen", "Qwen"), ("clod code", "Claude Code"),
    ]

    private static let heardNameLock = NSLock()
    nonisolated(unsafe) private static var heardNameCache: (owner: AutoDictionary, revision: Int, excluded: Set<String>, rules: VocabularyReplacementRules)?
    private static let preferredSpellingLock = NSLock()
    nonisolated(unsafe) private static var preferredSpellingCache: (terms: [Data], rules: VocabularyReplacementRules)?
    private static let vocabularyLock = NSLock()
    nonisolated(unsafe) private static var vocabularyCache: (owner: AutoDictionary, revision: Int, stored: [Data], excluded: Set<String>, view: VocabularyView)?

    struct VocabularyView {
        let custom: [String]
        let all: [String]
    }

    /// The built-in fixes plus the misheard names and phrases Flow learned from the user's edits
    /// (AutoDictionary). Rebuilt when the learned list changes, so a new fix applies on the next dictation.
    static func heardNameRules(learned: AutoDictionary = .shared, defaults: UserDefaults = .standard) -> VocabularyReplacementRules {
        let snapshot = learned.liveSnapshot()
        let excluded = excludedTerms(defaults: defaults)
        heardNameLock.lock(); defer { heardNameLock.unlock() }
        if let cache = heardNameCache, cache.owner === learned, cache.revision == snapshot.revision, cache.excluded == excluded {
            return cache.rules
        }
        let pairs = heardNameFixes + snapshot.replacements.map { ($0.heard, $0.written) }
        let rules = VocabularyReplacementRules(pairs, blockedAliases: snapshot.conflictingAliases, excludedTargets: excluded)
        heardNameCache = (learned, snapshot.revision, excluded, rules)
        return rules
    }

    /// Short all-caps abbreviations Jordan says or types. Written in capitals, whatever the casing
    /// or spacing: "asap", "a s a p" and "A.S.A.P." all become "ASAP". "ngl" stays as he typed it.
    /// A dotted abbreviation loses its final dot only before a lowercase word ("A.S.A.P. today").
    static let capsAbbreviations: [String] = ["ASAP", "FYI", "ETA", "TBH", "IDK", "API", "UI", "MCP", "NAS", "PC",
                                              "GPU", "AI", "DM"]
    private static let defaultAbbreviationRules = abbreviationRules(capsAbbreviations)

    private static func abbreviationRules(_ terms: [String]) -> [(String, NSRegularExpression)] {
        terms.compactMap { term in
            let spaced = term.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[ .]")
            let pattern = #"(?<![\p{L}\p{N}])(?:"# + NSRegularExpression.escapedPattern(for: term) + "|" + spaced
                + #"(?:\.(?=\s+(?-i:\p{Ll})))?)(?![\p{L}\p{N}])"#
            return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)).map { (term, $0) }
        }
    }

    /// Writes each capsAbbreviations entry in capitals. A spaced or dotted run only counts when every
    /// letter is separated, so "a sap" is left alone.
    static func applyCapsAbbreviations(_ text: String, terms: [String] = capsAbbreviations) -> String {
        let rules = terms == capsAbbreviations ? defaultAbbreviationRules : abbreviationRules(terms)
        let frozen = EntityFreezer.freeze(text, mode: .minimal)
        let corrected = applyAbbreviations(to: frozen.text, rules: rules)
        return corrected.utf16.elementsEqual(frozen.text.utf16) ? text : EntityFreezer.unfreeze(corrected, entities: frozen.entities)
    }

    private static func applyAbbreviations(to text: String, rules: [(String, NSRegularExpression)]) -> String {
        var result = text
        for (term, regex) in rules {
            let mutable = NSMutableString(string: result)
            for match in regex.matches(in: result, range: NSRange(location: 0, length: mutable.length)).reversed() {
                let found = mutable.substring(with: match.range)
                if found != term { mutable.replaceCharacters(in: match.range, with: term) }
            }
            result = mutable as String
        }
        return result
    }

    /// Writes each misheard name the way Jordan spells it. Links, emails and code stay as they are.
    static func applyHeardNameFixes(_ text: String) -> String {
        let rules = heardNameRules()
        guard let regex = rules.regex else { return text }
        let ns = text as NSString
        guard regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil else { return text }
        let frozen = EntityFreezer.freeze(text, mode: .minimal)
        let corrected = rules.apply(to: frozen.text)
        return corrected.utf16.elementsEqual(frozen.text.utf16) ? text : EntityFreezer.unfreeze(corrected, entities: frozen.entities)
    }

    /// Restore the spelling already present. An entry never substitutes a different heard word.
    /// Misheard names (`heardNameFixes`) are written correctly first.
    static func applyPreferredSpelling(_ text: String, terms: [String]) -> String {
        // One protected snapshot covers the whole pass, including abbreviation casing.
        let frozen = EntityFreezer.freeze(text, mode: .minimal)
        let heard = heardNameRules().apply(to: frozen.text)
        let typed = TypoRepair.applyLearnedSpelling(heard)
        let prepared = applyAbbreviations(to: typed, rules: defaultAbbreviationRules)
        let keys = terms.map { Data($0.utf8) }
        let rules = preferredSpellingLock.withLock { () -> VocabularyReplacementRules in
            if let cache = preferredSpellingCache, cache.terms == keys { return cache.rules }
            let rules = VocabularyReplacementRules(terms.map { ($0, $0) })
            preferredSpellingCache = (keys, rules)
            return rules
        }
        let corrected = rules.apply(to: prepared)
        return corrected.utf16.elementsEqual(frozen.text.utf16) ? text : EntityFreezer.unfreeze(corrected, entities: frozen.entities)
    }

    /// The user-learned / manually-added custom terms only — NOT the
    /// built-in seed dictionary. This is what the Settings UI manages and
    /// what gets STRONG priority in ASR vocabulary boosting. Sorted +
    /// deduped (case-insensitively); persisted in UserDefaults under `key`.
    public static func customTerms() -> [String] {
        vocabularyView().custom
    }

    /// Get the current vocabulary (manual + learned + seed).
    public static func current() -> [String] {
        vocabularyView().all
    }

    /// Cache the sorted view by exact user preferences and one atomic learned snapshot.
    /// External settings edits invalidate it without waiting for a dictionary file reload.
    static func vocabularyView(defaults: UserDefaults = .standard, learned: AutoDictionary = .shared) -> VocabularyView {
        let manual = defaults.stringArray(forKey: key) ?? []
        let storedKey = manual.map { Data($0.utf8) }
        let excluded = excludedTerms(defaults: defaults)
        let snapshot = learned.liveSnapshot()
        vocabularyLock.lock(); defer { vocabularyLock.unlock() }
        if let cache = vocabularyCache, cache.owner === learned, cache.revision == snapshot.revision,
           cache.stored == storedKey, cache.excluded == excluded { return cache.view }
        var seen = Set<String>()
        var custom: [String] = []
        for term in manual + snapshot.names {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = VocabularyReplacementRules.key(trimmed)
            if !key.isEmpty, !excluded.contains(key), seen.insert(key).inserted { custom.append(trimmed) }
        }
        custom.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let longestFirst: (String, String) -> Bool = { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        let seeds = seedTerms.filter {
            let key = VocabularyReplacementRules.key($0)
            return !seen.contains(key) && !excluded.contains(key)
        }.sorted(by: longestFirst)
        let all = (custom + seeds.prefix(max(0, maxTerms - custom.count))).sorted(by: longestFirst)
        let view = VocabularyView(custom: custom, all: all)
        vocabularyCache = (learned, snapshot.revision, storedKey, excluded, view)
        return view
    }

    /// Add a manually-entered term.
    public static func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutationLock.lock(); defer { mutationLock.unlock() }
        var stored = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        let normalized = VocabularyReplacementRules.key(trimmed)
        if !excludedTerms().contains(normalized), !stored.contains(where: { VocabularyReplacementRules.key($0) == normalized }) {
            stored.append(trimmed)
            UserDefaults.standard.set(stored, forKey: key)
            print("[VOICE-VOCAB] added: \(trimmed)")
        }
    }

    /// Remove a learned/custom term and persist. Case-insensitive so it
    /// reliably removes whatever `customTerms()` surfaced to the UI.
    public static func remove(_ term: String) {
        let target = VocabularyReplacementRules.key(term)
        guard !target.isEmpty else { return }
        // A learned word he removes stays out for good.
        // Do not hold a preference-mutation lock while entering the learned store.
        AutoDictionary.shared.remove(written: target)
        mutationLock.lock(); defer { mutationLock.unlock() }
        var stored = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        let before = stored.count
        stored.removeAll { VocabularyReplacementRules.key($0) == target }
        if stored.count != before {
            UserDefaults.standard.set(stored, forKey: key)
            print("[VOICE-VOCAB] removed: \(term)")
        }
    }

    /// Observe recurring terms in raw recognition, using prior recognitions
    /// from other committed recordings. A stable ID prevents a rerun from
    /// counting the same recording twice. These are vocabulary hints only.
    public static func learnFrom(_ recognizedText: String, previousDictations: [String], evidenceID: String? = nil) {
        let candidates = extractCandidates(from: recognizedText)
        guard !candidates.isEmpty else { return }

        // Count appearances across prior recordings, not repeated words within one.
        var counter: [String: Int] = [:]
        for prior in previousDictations {
            let priorCandidates = extractCandidates(from: prior)
            for c in priorCandidates {
                counter[c, default: 0] += 1
            }
        }

        // A recurring name is evidence for the learned dictionary (AutoDictionary), which keeps the
        // examples and dates and skips everyday words; his own list (`userProperNouns`) is left as he made it.
        let stored = Set(customTerms().map { $0.lowercased() })
        let excluded = excludedTerms()
        let seeds = Set(seedTerms.map { $0.lowercased() })
        for c in candidates where !excluded.contains(c.lowercased()) {
            // Need ≥2 prior appearances to qualify as a recurring term.
            guard (counter[c] ?? 0) >= 2 else { continue }
            guard !stored.contains(c.lowercased()), !seeds.contains(c.lowercased()) else { continue }
            AutoDictionary.shared.observeRecurringName(c, context: recognizedText, evidenceID: evidenceID)
        }
    }

    private static let candidatePattern = try! NSRegularExpression(pattern: #"\b[A-Z][a-z]{2,}(?:\s+[A-Z][a-z]+)?\b"#)

    /// Extract candidate proper nouns from text. A candidate is:
    ///   - 3+ letters
    ///   - first letter uppercase, rest mixed
    ///   - NOT a common English word at sentence start
    ///   - NOT all-uppercase (acronyms handled separately)
    private static func extractCandidates(from text: String) -> [String] {
        let ns = text as NSString
        let matches = candidatePattern.matches(in: text, range: NSRange(location: 0, length: ns.length))

        // Filter out words that appear immediately after a sentence boundary
        // (".", "!", "?", or start of string) — they may just be sentence
        // starts, not proper nouns.
        var candidates: [String] = []
        for match in matches {
            let r = match.range
            let word = ns.substring(with: r)
            // Skip if this is sentence-initial.
            if r.location == 0 { continue }
            let prevChar = ns.substring(with: NSRange(location: r.location - 1, length: 1))
            if prevChar == " " {
                if r.location >= 2 {
                    let prev2 = ns.substring(with: NSRange(location: r.location - 2, length: 1))
                    if [".", "!", "?", "\n"].contains(prev2) { continue }
                }
            } else if [".", "!", "?", "\n"].contains(prevChar) {
                continue
            }
            if commonWords.contains(word.lowercased()) { continue }
            candidates.append(word)
        }
        return Array(Set(candidates))
    }

    /// Conservative stoplist — words that are commonly capitalized at
    /// sentence start but aren't proper nouns. Keeps the learning step
    /// from polluting the vocabulary with "The", "However", etc.
    private static let commonWords: Set<String> = [
        "the", "and", "but", "also", "however", "yes", "no", "okay",
        "hey", "well", "actually", "maybe", "probably", "definitely",
        "today", "tomorrow", "yesterday", "now", "then", "this", "that",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]
}
