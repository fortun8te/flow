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
// The auto-learning step runs after each dictation is polished — it
// scans the FINAL text for capitalized words that appeared 2+ times
// across the user's last 50 dictations and weren't already known. This
// way the model "learns" the user's frequent proper nouns without
// requiring manual setup.

import Foundation

public enum ProperNounVocabulary {
    private static let key = "userProperNouns"
    private static let maxTerms = 600

    private static let seedTerms = [
        "Wispr Flow", "ChatGPT", "OpenAI", "Claude", "Claude Code",
        "Qwen", "GitHub", "SwiftUI", "macOS",
    ]

    static let excludedTermsKey = "voice.dictionaryExcludedTerms"

    static func excludedTerms(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: excludedTermsKey) ?? [])
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
    nonisolated(unsafe) private static var heardNameCache: (revision: Int, regex: NSRegularExpression?, map: [String: String])?

    /// The built-in fixes plus the misheard names and phrases Flow learned from the user's edits
    /// (AutoDictionary). Rebuilt when the learned list changes, so a new fix applies on the next dictation.
    private static func heardNameRules(learned: AutoDictionary = .shared) -> (regex: NSRegularExpression?, map: [String: String]) {
        let revision = learned.currentRevision
        heardNameLock.lock(); defer { heardNameLock.unlock() }
        if let cache = heardNameCache, cache.revision == revision { return (cache.regex, cache.map) }
        var map = Dictionary(heardNameFixes.map { ($0.heard, $0.written) }, uniquingKeysWith: { a, _ in a })
        for fix in learned.liveReplacements() where map[fix.heard] == nil { map[fix.heard] = fix.written }
        let alternatives = map.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "[ ]") }
            .joined(separator: "|")
        let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_./@-])(?:"# + alternatives + #")(?![\p{L}\p{N}_/@-])"#,
                                             options: .caseInsensitive)
        heardNameCache = (revision, regex, map)
        return (regex, map)
    }

    /// Short all-caps abbreviations Jordan says or types. Written in capitals, whatever the casing
    /// or spacing: "asap", "a s a p" and "A.S.A.P." all become "ASAP". "ngl" stays as he typed it.
    /// A dotted abbreviation loses its final dot only before a lowercase word ("A.S.A.P. today").
    static let capsAbbreviations: [String] = ["ASAP", "FYI", "ETA", "TBH", "IDK", "API", "UI", "MCP", "NAS", "PC",
                                              "GPU", "AI", "DM"]

    /// Writes each capsAbbreviations entry in capitals. A spaced or dotted run only counts when every
    /// letter is separated, so "a sap" is left alone.
    static func applyCapsAbbreviations(_ text: String, terms: [String] = capsAbbreviations) -> String {
        var result = text
        for term in terms {
            let spaced = term.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[ .]")
            let pattern = #"(?<![\p{L}\p{N}])(?:"# + NSRegularExpression.escapedPattern(for: term) + "|" + spaced
                + #"(?:\.(?=\s+(?-i:\p{Ll})))?)(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
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
        let heardNameMap = rules.map
        guard let regex = rules.regex else { return text }
        let ns = text as NSString
        guard regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil else { return text }
        let frozen = EntityFreezer.freeze(text, mode: .minimal)
        let result = NSMutableString(string: frozen.text)
        for match in regex.matches(in: frozen.text, range: NSRange(location: 0, length: result.length)).reversed() {
            let heard = result.substring(with: match.range)
            if let written = heardNameMap[heard.lowercased()], heard != written {
                result.replaceCharacters(in: match.range, with: written)
            }
        }
        let corrected = result as String
        return corrected == frozen.text ? text : EntityFreezer.unfreeze(corrected, entities: frozen.entities)
    }

    /// Restore the spelling already present. An entry never substitutes a different heard word.
    /// Misheard names (`heardNameFixes`) are written correctly first.
    static func applyPreferredSpelling(_ text: String, terms: [String]) -> String {
        let text = applyCapsAbbreviations(TypoRepair.applyLearnedSpelling(applyHeardNameFixes(text)))
        var spelling: [String: String] = [:]
        for term in terms {
            let key = term.lowercased()
            if !key.isEmpty, spelling[key] == nil { spelling[key] = term }
        }
        guard !spelling.isEmpty else { return text }
        let alternatives = spelling.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"(?<![\p{L}\p{N}_])(?:"# + alternatives + #")(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let frozen = EntityFreezer.freeze(text, mode: .minimal)
        let result = NSMutableString(string: frozen.text)
        let whole = NSRange(location: 0, length: result.length)
        for match in regex.matches(in: frozen.text, range: whole).reversed() {
            let heard = result.substring(with: match.range)
            if let preferred = spelling[heard.lowercased()], heard != preferred {
                result.replaceCharacters(in: match.range, with: preferred)
            }
        }
        let corrected = result as String
        return corrected == frozen.text ? text : EntityFreezer.unfreeze(corrected, entities: frozen.entities)
    }

    /// The user-learned / manually-added custom terms only — NOT the
    /// built-in seed dictionary. This is what the Settings UI manages and
    /// what gets STRONG priority in ASR vocabulary boosting. Sorted +
    /// deduped (case-insensitively); persisted in UserDefaults under `key`.
    public static func customTerms() -> [String] {
        // His own list first, then the names Flow learned from his fixes (AutoDictionary).
        let stored = (UserDefaults.standard.array(forKey: key) as? [String] ?? []) + AutoDictionary.shared.liveNames()
        // Case-insensitive dedupe, preserving first-seen casing.
        let excluded = excludedTerms()
        var seen = Set<String>()
        var unique: [String] = []
        for term in stored {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            if !excluded.contains(lower), seen.insert(lower).inserted {
                unique.append(trimmed)
            }
        }
        unique.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return unique
    }

    /// Get the current vocabulary (manual + learned + seed).
    public static func current() -> [String] {
        let stored = customTerms()
        let excluded = excludedTerms()
        // Merge seed terms in case fresh install / cleared defaults.
        // User terms are never cut by the cap; seeds fill what is left.
        let longestFirst: (String, String) -> Bool = { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        let user = Array(Set(stored)).sorted(by: longestFirst)
        let userSet = Set(user)
        let seeds = Set(seedTerms).subtracting(userSet).filter { !excluded.contains($0.lowercased()) }.sorted(by: longestFirst)
        var merged = user + seeds.prefix(max(0, maxTerms - user.count))
        merged.sort(by: longestFirst)   // longest first for prefix-match priority
        return merged
    }

    /// Add a manually-entered term.
    public static func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var stored = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        if !excludedTerms().contains(trimmed.lowercased()), !stored.contains(trimmed) {
            stored.append(trimmed)
            UserDefaults.standard.set(stored, forKey: key)
            print("[VOICE-VOCAB] added: \(trimmed)")
        }
    }

    /// Remove a learned/custom term and persist. Case-insensitive so it
    /// reliably removes whatever `customTerms()` surfaced to the UI.
    public static func remove(_ term: String) {
        let target = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return }
        // A learned word he removes stays out for good.
        AutoDictionary.shared.remove(written: target)
        var stored = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        let before = stored.count
        stored.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target }
        if stored.count != before {
            UserDefaults.standard.set(stored, forKey: key)
            print("[VOICE-VOCAB] removed: \(term)")
        }
    }

    /// Learn proper nouns from a polished dictation. Called after each
    /// successful polish. Heuristic: capitalized multi-letter words that
    /// aren't at sentence starts, aren't common English words, and
    /// appeared before.
    public static func learnFrom(_ polishedText: String, previousDictations: [String]) {
        let candidates = extractCandidates(from: polishedText)
        guard !candidates.isEmpty else { return }

        // Only promote terms that appeared in at least one prior dictation.
        // This avoids learning random one-off names from a single rant.
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
            AutoDictionary.shared.observeRecurringName(c, context: polishedText)
        }
    }

    /// Extract candidate proper nouns from text. A candidate is:
    ///   - 3+ letters
    ///   - first letter uppercase, rest mixed
    ///   - NOT a common English word at sentence start
    ///   - NOT all-uppercase (acronyms handled separately)
    private static func extractCandidates(from text: String) -> [String] {
        // Pattern: capitalized word, possibly multi-word (TitleCase chains).
        let pattern = #"\b[A-Z][a-z]{2,}(?:\s+[A-Z][a-z]+)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

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
