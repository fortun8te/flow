// ASRVocabularyBoost.swift
//
// Acoustic vocabulary boosting for the final (batch) Parakeet transcript.
// FluidAudio's VocabularyBoostingSession runs the small Parakeet CTC 110M
// encoder over the same audio and replaces a transcript span with one of the
// user's terms only when the CTC evidence for the term beats the evidence for
// the words Parakeet wrote.
//
// Only the user's trusted terms are boosted: the learned/added proper nouns
// (`userProperNouns`) and explicit dictionary entries (`voice.userDictionary`),
// filtered to short word-like names. The 1,000+ starter dictionary is never
// passed here: large lists make the rescorer insert near-sounding terms.
//
// Setting: `voice.asrVocabularyBoost` (Bool). On by default: on 200 of Jordan's
// clips it raised dictionary-term recall from 38% to 83% with no false
// insertions after the guard below (doc above). Turn off with
// `defaults write com.example.flow voice.asrVocabularyBoost -bool false`.
// Tuning keys for experiments: `voice.asrVocabularyBoostCbw` (default: FluidAudio's
// 4.5) and `voice.asrVocabularyBoostMinSimilarity` (default 0.6).

import FluidAudio
import Foundation

enum ASRVocabularyBoost {
    static let defaultsKey = "voice.asrVocabularyBoost"
    static let cbwKey = "voice.asrVocabularyBoostCbw"
    static let minSimilarityKey = "voice.asrVocabularyBoostMinSimilarity"
    /// Measured on 13 Nov 2026.
    static let enabledByDefault = true
    /// FluidAudio's size default is 0.55; 0.55 turned "workflow" into "Wispr Flow".
    static let defaultMinSimilarity: Float = 0.6

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? enabledByDefault
    }

    /// What one rescoring pass did, for the replay harness and logs.
    struct Report: Sendable, Equatable {
        var unboostedText: String
        var boostedText: String
        var replacements: [String]   // "original → term"
        var ctcRan: Bool
        var milliseconds: Double
        var rejected: [String] = []   // edits the guard reverted
    }

    /// The trusted terms: user proper nouns plus explicit dictionary entries,
    /// limited to name-like entries the rescorer can handle.
    static func trustedTerms(properNouns: [String] = ProperNounVocabulary.customTerms(),
                             dictionary: [String] = UserDictionary.terms()) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in properNouns + dictionary {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isBoostable(term), seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
        }
        // A multi-word term that starts with another listed term ("Jordan Example"
        // after "Jordan") lets the rescorer grow a correctly heard name into the
        // longer one ("Jordan, so" -> "Jordan Example"): measured, so left out.
        let lowered = Set(out.map { $0.lowercased() })
        return out.filter { term in
            let words = term.lowercased().split(separator: " ")
            guard words.count > 1 else { return true }
            return !(1..<words.count).contains { lowered.contains(words.prefix($0).joined(separator: " ")) }
        }
    }

    /// The term plus, for multi-word terms, its run-together spelling: Parakeet
    /// writes "Whisperflow" for "Wispr Flow", and without the one-word alias the
    /// rescorer pulls a neighbouring word into the span ("to Whisperflow").
    static func vocabularyTerm(_ text: String) -> CustomVocabularyTerm {
        let words = text.split(separator: " ")
        guard words.count > 1 else { return CustomVocabularyTerm(text: text) }
        return CustomVocabularyTerm(text: text, aliases: [words.joined()])
    }

    /// Phrases made only of everyday words ("I don't know", "by the way") are
    /// dictionary snippets, not names; Parakeet already hears them.
    private static let everydayWords: Set<String> = [
        "i", "don't", "dont", "know", "by", "the", "way", "a", "an", "and", "of", "to", "in", "on",
        "it", "is", "you", "me", "my", "we", "for", "with", "that", "this",
    ]

    static func isBoostable(_ term: String) -> Bool {
        guard term.count >= 4, term.count <= 32 else { return false }
        let words = term.split(separator: " ")
        guard words.count <= 3 else { return false }
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " -'’"))
        guard term.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let letters = term.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters * 2 > term.count else { return false }
        if words.allSatisfy({ everydayWords.contains($0.lowercased()) }) { return false }
        return true
    }

    // MARK: Replacement guard

    /// Lowercased letters and digits only ("acme x" -> "acmex").
    static func squash(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Other names Flow knows (starter dictionary, proper-noun seeds), squashed, minus the boosted terms.
    /// A transcript word within one edit of one of these is a different real name ("codex", "Xcode").
    static func knownOtherWords(terms: [String]) -> Set<String> {
        let boosted = Set(terms.map(squash))
        var known = Set<String>()
        for entry in StarterDictionary.terms + ProperNounVocabulary.current() {
            for word in entry.split(separator: " ") {
                let w = squash(String(word))
                if w.count >= 4, !boosted.contains(w) { known.insert(w) }
            }
        }
        return known
    }

    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return a.isEmpty ? b.count : (b.isEmpty ? a.count : previous[b.count])
    }

    /// Whether one rescorer edit (`original` words -> `replacement` words) is kept. Measured
    /// false insertions on 13 Nov 2026: "codex/codec/coded/Xcode" -> "ocodex", "TikToks" ->
    /// "tiktok", "redo" -> "Felix". Spacing/casing-only edits ("acme x" -> "AcmeX") are kept.
    static func keepsReplacement(original: [String], replacement: [String], knownOther: Set<String>) -> Bool {
        let old = squash(original.joined(separator: " ")), new = squash(replacement.joined(separator: " "))
        guard !old.isEmpty, !new.isEmpty, old != new else { return true }
        // Only letters added or cut at the edge of a real word (plural, prefix).
        if old.count >= 4, new.contains(old) || old.contains(new) { return false }
        // What was heard is at least as close to another name Flow knows as to the term.
        let toTerm = editDistance(old, new, limit: 3)
        if knownOther.contains(where: { editDistance($0, old, limit: 1) <= min(1, toTerm) }) { return false }
        return true
    }

    /// Re-applies the rescorer's output hunk by hunk, keeping only the edits
    /// `keepsReplacement` allows. Returns the text and the rejected edits.
    static func guardedText(unboosted: String, boosted: String,
                            knownOther: Set<String>) -> (text: String, rejected: [String]) {
        let a = unboosted.split(separator: " ").map(String.init)
        let b = boosted.split(separator: " ").map(String.init)
        guard !a.isEmpty, !b.isEmpty else { return (boosted, []) }
        // Longest common subsequence over exact tokens.
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [String] = [], rejected: [String] = []
        var i = 0, j = 0
        var oldHunk: [String] = [], newHunk: [String] = []
        func flush() {
            guard !oldHunk.isEmpty || !newHunk.isEmpty else { return }
            if keepsReplacement(original: oldHunk, replacement: newHunk, knownOther: knownOther) {
                out += newHunk
            } else {
                out += oldHunk
                rejected.append(oldHunk.joined(separator: " ") + " → " + newHunk.joined(separator: " "))
            }
            oldHunk = []; newHunk = []
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                flush(); out.append(a[i]); i += 1; j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                newHunk.append(b[j]); j += 1
            } else {
                oldHunk.append(a[i]); i += 1
            }
        }
        flush()
        return (out.joined(separator: " "), rejected)
    }

    static func thresholds(defaults: UserDefaults = .standard) -> VocabularyBoostingSession.Thresholds {
        let cbw = (defaults.object(forKey: cbwKey) as? NSNumber).map { Float(truncating: $0) }
        let sim = (defaults.object(forKey: minSimilarityKey) as? NSNumber).map { Float(truncating: $0) }
        return VocabularyBoostingSession.Thresholds(cbw: cbw, minSimilarity: sim ?? defaultMinSimilarity)
    }
}

/// Holds the CTC models and one session for the current term list. Loading is
/// lazy (first boosted dictation) and failures leave the transcript untouched.
actor ASRVocabularyBooster {
    static let shared = ASRVocabularyBooster()

    private var ctcModels: CtcModels?
    private var session: VocabularyBoostingSession?
    private var sessionKey: String?
    private var unavailable = false
    private var knownOther: Set<String> = []

    /// Rescore one decode window. `tokenTimings` must be on the clock of `samples`.
    func rescore(text: String, tokenTimings: [TokenTiming]?, samples: [Float]) async -> ASRVocabularyBoost.Report {
        let started = CFAbsoluteTimeGetCurrent()
        func report(_ boosted: String, _ replacements: [String], ran: Bool,
                    rejected: [String] = []) -> ASRVocabularyBoost.Report {
            .init(unboostedText: text, boostedText: boosted, replacements: replacements, ctcRan: ran,
                  milliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1000, rejected: rejected)
        }
        guard let timings = tokenTimings, !timings.isEmpty, !samples.isEmpty,
              let session = await currentSession() else { return report(text, [], ran: false) }
        guard session.hasCTCRescoringCandidates(text: text, tokenTimings: timings) else {
            return report(text, [], ran: false)
        }
        guard let output = await session.rescore(text: text, tokenTimings: timings, audioSamples: samples),
              output.wasModified else { return report(text, [], ran: true) }
        let replacements = output.replacements.filter(\.shouldReplace).map {
            "\($0.originalWord) → \($0.replacementWord ?? "")"
        }
        let guarded = ASRVocabularyBoost.guardedText(unboosted: text, boosted: output.text, knownOther: knownOther)
        let kept = replacements.filter { r in !guarded.rejected.contains { $0.hasPrefix(r.components(separatedBy: " → ")[0]) } }
        return report(guarded.text, kept, ran: true, rejected: guarded.rejected)
    }

    /// Loads the CTC model and session ahead of the first dictation.
    func prewarm() async { _ = await currentSession() }

    private func currentSession() async -> VocabularyBoostingSession? {
        guard !unavailable else { return nil }
        let terms = ASRVocabularyBoost.trustedTerms()
        guard !terms.isEmpty else { return nil }
        let thresholds = ASRVocabularyBoost.thresholds()
        let key = terms.joined(separator: "\u{1F}") + "|\(thresholds.cbw ?? -99)|\(thresholds.minSimilarity ?? -99)"
        if key == sessionKey, let session { return session }
        do {
            if ctcModels == nil { ctcModels = try await CtcModels.downloadAndLoad() }
            guard let ctcModels else { return nil }
            let vocabulary = CustomVocabularyContext(terms: terms.map(ASRVocabularyBoost.vocabularyTerm))
            let made = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctcModels,
                                                           thresholds: thresholds)
            session = made
            sessionKey = key
            knownOther = ASRVocabularyBoost.knownOtherWords(terms: terms)
            print("[VOICE-VOCAB] batch boosting ready: \(terms.count) trusted terms")
            return made
        } catch {
            // Do not retry on every dictation; the next launch tries again.
            unavailable = true
            print("[VOICE-VOCAB] batch boosting unavailable: \(error.localizedDescription)")
            return nil
        }
    }
}
