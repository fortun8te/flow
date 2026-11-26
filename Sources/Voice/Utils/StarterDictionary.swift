// VOICE — Starter + User Vocabulary
// ============================================================
// Two-tier dictionary surfaced to the ASR pipeline and the Qwen3
// polish prompt:
//
//   1. StarterDictionary.terms — built-in technical/
//      acronym terms.
//   2. UserDictionary.terms() — user-added entries persisted to
//      UserDefaults under "voice.userDictionary". Mutable.
//
// `combined()` merges them with the user list taking precedence on
// case-insensitive duplicates (so a user override of "Github" → "GitHub"
// wins over the canonical spelling we hardcoded).
//
// On the FluidAudio side: `SlidingWindowAsrManager.configureVocabularyBoosting`
// accepts a `CustomVocabularyContext` built from these terms. The batch
// `AsrManager` path used by TranscriptionService.transcribeFile does NOT
// currently expose a public vocabulary-boost API — so for batch we only
// inject the terms into the Qwen3 polish prompt. Live-partials path
// (which DOES use SlidingWindowAsrManager) would be a natural place to
// add CTC-level biasing, but it's not wired here yet.
// ============================================================

import Foundation
import FluidAudio

/// Hand-picked terms users of a developer/maker-oriented dictation app
/// dictate constantly — Parakeet often mis-spells these (e.g. "GitHub"
/// → "get hub", "Claude" → "clawed"). Surfaced verbatim into the
/// Qwen3 polish prompt and into FluidAudio's vocabulary biasing for
/// the streaming path.
enum StarterDictionary {
    static let terms = [
        "GitHub", "Xcode", "Swift", "SwiftUI", "macOS", "Core ML",
        "FluidAudio", "Parakeet", "Whisper", "Qwen", "MLX", "SQLite",
        "Markdown", "JSON", "API", "URL",
    ]
}

/// UserDefaults-backed user vocabulary. The UI for editing this is not
/// yet built — these accessors are the data layer the future settings
/// pane will read/write through.
enum UserDictionary {
    private static let defaultsKey = "voice.userDictionary"

    /// All user-added terms (de-duplicated, original casing preserved).
    static func terms(defaults: UserDefaults = .standard) -> [String] {
        let stored = defaults.stringArray(forKey: defaultsKey) ?? []
        // Defensive: trim, drop empties, de-dupe case-insensitively.
        let excluded = ProperNounVocabulary.excludedTerms(defaults: defaults)
        var seen = Set<String>()
        var out: [String] = []
        for raw in stored {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let key = VocabularyReplacementRules.key(t)
            if !excluded.contains(key), seen.insert(key).inserted {
                out.append(t)
            }
        }
        return out
    }

    /// Replace the user list. Caller is responsible for sanitization beyond
    /// trim+dedupe (which we do on read).
    static func setTerms(_ terms: [String]) {
        VocabularyPreferenceTransaction.withLock { UserDefaults.standard.set(terms, forKey: defaultsKey) }
        // Lets Companion refresh its copy; silent outside the running app.
        FlowBroadcast.changed("dictionary")
    }

    /// Add one term. Idempotent on case-insensitive match.
    static func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        VocabularyPreferenceTransaction.withLock {
            var existing = terms()
            let lower = VocabularyReplacementRules.key(trimmed)
            guard !existing.contains(where: { VocabularyReplacementRules.key($0) == lower }) else { return }
            existing.append(trimmed)
            setTerms(existing)
        }
    }

    /// Remove one term (case-insensitive).
    static func remove(_ term: String) {
        VocabularyPreferenceTransaction.withLock {
            let lower = VocabularyReplacementRules.key(term)
            let filtered = terms().filter { VocabularyReplacementRules.key($0) != lower }
            setTerms(filtered)
        }
    }
}

/// Merged starter + user terms. User entries take precedence on case-
/// insensitive duplicates so a user's preferred casing overrides ours.
enum CombinedDictionary {
    static func terms() -> [String] {
        let user = UserDictionary.terms()
        let userLower = Set(user.map(VocabularyReplacementRules.key))
        let exclusions = ProperNounVocabulary.excludedTerms().union(userLower)
        let starterUnique = StarterDictionary.terms.filter { !exclusions.contains(VocabularyReplacementRules.key($0)) }
        // User first so their casing wins downstream consumers that dedupe.
        return user + starterUnique
    }

    /// Build a FluidAudio `CustomVocabularyContext` from the merged list.
    /// Used by the streaming (SlidingWindowAsrManager) path.
    ///
    /// Weighting / ordering policy:
    ///   • User-learned + manually-added proper nouns
    ///     (`ProperNounVocabulary.customTerms()`) are placed FIRST and given
    ///     a STRONG weight so the user's own vocabulary out-competes the
    ///     3000+ generic starter terms during CTC rescoring.
    ///   • Explicit user dictionary entries (`UserDictionary`) come next at a
    ///     boosted weight (their casing still wins downstream dedupe).
    ///   • The static starter dictionary fills the tail at the baseline weight.
    /// Earlier entries also win ties under the keyword spotter, so ordering
    /// reinforces the weighting.
    static func vocabularyContext() -> CustomVocabularyContext {
        // STRONG boost for user-learned / custom proper nouns.
        let learnedWeight: Float = 30.0
        // Elevated boost for explicit user-dictionary entries.
        let userWeight: Float = 18.0
        // Baseline boost for the static starter dictionary.
        let starterWeight: Float = 10.0

        // Track which terms are already covered (case-insensitively) so the
        // same word isn't emitted twice with conflicting weights — the first
        // (highest-priority) occurrence wins.
        var seenLower = Set<String>()
        var entries: [CustomVocabularyTerm] = []

        func append(_ list: [String], weight: Float) {
            for term in list {
                let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let lower = VocabularyReplacementRules.key(trimmed)
                guard seenLower.insert(lower).inserted else { continue }
                entries.append(CustomVocabularyTerm(text: trimmed, weight: weight))
            }
        }

        // 1) User-learned / manually-added proper nouns — highest priority.
        append(ProperNounVocabulary.customTerms(), weight: learnedWeight)
        // 2) Explicit user-dictionary entries.
        append(UserDictionary.terms(), weight: userWeight)
        // 3) Static starter dictionary — baseline.
        let excluded = ProperNounVocabulary.excludedTerms()
        append(StarterDictionary.terms.filter { !excluded.contains(VocabularyReplacementRules.key($0)) }, weight: starterWeight)

        return CustomVocabularyContext(terms: entries)
    }
}
