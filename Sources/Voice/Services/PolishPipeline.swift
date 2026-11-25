// PolishPipeline.swift
//
// Relaxed-cloud sanitizer for polish validation.
//
// The single sanitize() in Qwen3Polisher.swift was originally written for
// the LOCAL 1.7B model — small, error-prone, needed tight word/length
// budgets and a long list of injection guards. The CLOUD path
// (Cerebras gpt-oss-120b / Groq llama3.1-8b) is far stronger and
// legitimately produces:
//   - long restructuring rewrites that drop filler words wholesale
//     (fails strict word-preservation)
//   - email/letter reformatting that adds "\n\nBest,\nName"
//     (fails strict word-count budget)
//   - bullet expansion with colons added ("groceries: a, b, c, d")
//     (fails strict sentence-count budget)
//   - number normalization ("twenty three percent" → "23%")
//     (fails strict char-length budget)
// Run through the legacy strict sanitizer, every one of those polishes
// was being SILENTLY rejected and the raw transcript shipped instead —
// the "Voice quality is bad" experience.
//
// The Sanitizer here exposes a public API the polisher can call on the
// cloud path. Two modes:
//   .strict  — legacy behavior (kept verbatim for the local 1.7B path)
//   .relaxed — trust the cloud model, only block absolute-rule
//              violations: em-dashes, emojis, vulgarity injection,
//              proper-noun/number/email/URL preservation, semantic flips,
//              prompt echo / preamble residue.
//
// Visible logging:
//   Every rejection prints `[VOICE-SANITIZE] rejected: rule=<name> ...`
//   so reviewers can grep the dev console for false-positives.
//
// Emergency override:
//   UserDefaults bool `voice.disableSanitizer` (read here, can be set by
//   a SwiftUI `@AppStorage("voice.disableSanitizer")` toggle in Settings).
//   When true, Sanitizer.run() ALWAYS accepts the model output. Lets the
//   user A/B test "is the sanitizer the problem?" with one toggle.

import Foundation

// MARK: - Sanitizer (the relaxed-cloud validator)

/// Public validator that decides whether to accept a polish or fall back
/// to the raw input. Two modes — STRICT for the local 1.7B (legacy
/// behavior) and RELAXED for the cloud (Cerebras / Groq).
///
/// Usage from the polisher (cloud branch):
/// ```
/// let accepted = Sanitizer.run(
///     polish: cloudOut,
///     original: frozenInput,
///     mode: .relaxed,
///     cleanupLevel: cleanupLevel,
///     userVocabulary: userVocabulary
/// )
/// if accepted == nil {
///     // Sanitizer rejected — fall back to raw input.
///     polishedFrozen = frozenInput
/// } else {
///     polishedFrozen = accepted!
/// }
/// ```
///
/// `run` ALWAYS returns the polish unchanged when the user has toggled
/// `voice.disableSanitizer` on, so the user can A/B test whether the
/// sanitizer is the source of bad output.
public enum Sanitizer {

    /// How strictly the sanitizer should validate the model output.
    public enum Mode: Sendable {
        /// Legacy strict mode: tight word/length budgets, contraction +
        /// filler caps, every input word must roughly appear in output.
        /// Use for the local 1.7B polish path — that model is too small
        /// to trust with aggressive restructuring.
        case strict

        /// Relaxed cloud mode: trust the model. Only block ABSOLUTE-RULE
        /// violations:
        ///   - em-dashes / en-dashes (Voice never ships them)
        ///   - emojis (banned by spec)
        ///   - vulgarity injection (introduced words not in original)
        ///   - proper-noun loss (>2 names dropped)
        ///   - number/email/URL loss (substring preservation)
        ///   - semantic flips (don't think → think, etc.)
        ///   - prompt echo / preamble residue ("Here's the polish: …")
        ///   - prompt-injection markers (<|, [INST], As an AI, </think>)
        /// Sentence count, word count, contraction count, filler count
        /// are NOT checked — the cloud is allowed to restructure freely.
        case relaxed
    }

    /// UserDefaults key for the emergency override. When true (matching
    /// `@AppStorage("voice.disableSanitizer")` in a SwiftUI toggle), the
    /// sanitizer always accepts the model output untouched.
    public static let disableKey = "voice.disableSanitizer"

    /// Validate `polish` against `original`. Returns the polish on accept,
    /// nil on reject. Every rejection logs `[VOICE-SANITIZE] rejected:
    /// rule=<name> input="..." polish="..."` so the dev console makes it
    /// obvious which rule fired.
    public static func run(
        polish: String,
        original: String,
        mode: Mode,
        cleanupLevel: String? = "medium",
        userVocabulary: [String]? = nil
    ) -> String? {
        // Emergency override — user-toggleable. Pass through unconditionally.
        if UserDefaults.standard.bool(forKey: disableKey) {
            print("[VOICE-SANITIZE] DISABLED via \(disableKey) — accepting polish unconditionally")
            return polish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : polish
        }

        var cleaned = polish.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            logReject(rule: "empty-polish", input: original, polish: polish)
            return nil
        }

        // --- ABSOLUTE RULES — apply to every mode ---

        // 1. Em-dash / en-dash / horizontal-bar. The user HATES these.
        //    These chars are absolute-banned per the app spec. We reject
        //    rather than strip so a polish that LEANS on dashes for
        //    structure (a common Claude/GPT habit) loses its winning
        //    bid and a better candidate (next draft / raw input) takes
        //    over. The downstream `stripDashes` pass is the secondary
        //    safety net for any dashes that slip through.
        if cleaned.contains("\u{2014}") || cleaned.contains("\u{2013}") || cleaned.contains("\u{2015}") {
            logReject(rule: "em-dash", input: original, polish: polish)
            return nil
        }

        // 2. Emojis. Also banned by spec. Reject if any extended-pictographic
        //    char appears that was NOT in the original (so a user dictating
        //    "tell me about 🚀 launches" still works).
        if containsEmojiNotInOriginal(polish: cleaned, original: original) {
            logReject(rule: "emoji", input: original, polish: polish)
            return nil
        }

        // 3. Prompt-injection / chat-template residue. The model leaked
        //    its system frame — always wrong.
        let residueMarkers = ["<|im_start|>", "<|im_end|>", "<|", "|>",
                              "[INST]", "[/INST]", "</think>", "<think>",
                              "As an AI", "As a language model"]
        for marker in residueMarkers {
            if cleaned.contains(marker) {
                logReject(rule: "prompt-residue:\(marker)", input: original, polish: polish)
                return nil
            }
        }

        // 4. Preamble residue. "Here's the polish:", "Output:", "Polished:"…
        let lowerHead = cleaned.lowercased()
        let preambles = ["here is the polish", "here's the polish",
                         "here is the polished", "here's the polished",
                         "here is the cleaned", "here's the cleaned",
                         "polished:", "output:", "cleaned:",
                         "i fixed", "corrected:"]
        for pre in preambles {
            if lowerHead.hasPrefix(pre) {
                logReject(rule: "preamble:\(pre)", input: original, polish: polish)
                return nil
            }
        }

        // 5. Trailing "Output:" / "Input:" continuation residue.
        if cleaned.range(of: #"\n\s*(Input|Output):"#, options: .regularExpression) != nil {
            logReject(rule: "trailing-turn-marker", input: original, polish: polish)
            return nil
        }

        // 5b. Meta-commentary: the model describing the task ("The user wants me to clean this up")
        //     instead of returning the cleaned text. Only fires when the speaker did not say it.
        if let meta = metaCommentary(polish: cleaned, original: original) {
            logReject(rule: "meta-commentary:\(meta)", input: original, polish: polish)
            return nil
        }

        // 6. Vulgarity injection. Word-boundary match: any word in the
        //    blocklist that's in the polish but NOT the original is a
        //    polish-induced corruption.
        if let bad = injectedVulgarity(polish: cleaned, original: original) {
            logReject(rule: "vulgarity:\(bad)", input: original, polish: polish)
            return nil
        }

        // 7. Semantic flip detection — negation lost. Catastrophic, all modes.
        let correcting = containsCorrectionCue(original)
        let meaningKept = correcting
            ? MeaningIntegrity.preservesMeaningAfterCorrection(original: original, candidate: cleaned)
            : MeaningIntegrity.preservesMeaning(original: original, candidate: cleaned)
        if !meaningKept {
            logReject(rule: "semantic-flip", input: original, polish: polish)
            return nil
        }

        // Hard negation guard. A "not", "never", "don't" or "no" the speaker said after their last
        // correction marker must survive. Dropping one flips the meaning, and the correction path
        // must not let a filler like "I mean" excuse it.
        if !MeaningIntegrity.keepsNegations(original: original, candidate: cleaned) {
            logReject(rule: "negation-dropped", input: original, polish: polish)
            return nil
        }

        // --- PROPER NOUN / NUMBER / EMAIL / URL preservation ---
        // Required in both modes; relaxed mode is identical here — these
        // are anchors the cloud model still must preserve even when it
        // restructures everything around them.

        if let missing = missingProperNouns(polish: cleaned, original: original) {
            logReject(rule: "lost-proper-noun:\(missing)", input: original, polish: polish)
            return nil
        }

        if let lostNum = missingSignificantNumber(polish: cleaned, original: original) {
            logReject(rule: "lost-number:\(lostNum)", input: original, polish: polish)
            return nil
        }

        // A number or name swapped for a near-identical one ("4500" to "4050", "Priya" to "Pria").
        // Deleting a token is tolerated above; replacing it with a similar wrong fact is not.
        if let swapped = PolishNormalizer.substitutedFact(polish: cleaned, original: original) {
            logReject(rule: "substituted-fact:\(swapped)", input: original, polish: polish)
            return nil
        }

        if let lostEmail = missingEmail(polish: cleaned, original: original) {
            logReject(rule: "lost-email:\(lostEmail)", input: original, polish: polish)
            return nil
        }

        if let lostURL = missingURL(polish: cleaned, original: original) {
            logReject(rule: "lost-url:\(lostURL)", input: original, polish: polish)
            return nil
        }

        // --- STRICT-MODE-ONLY BUDGETS ---
        // Tight word/length/contraction/filler caps that legitimately
        // catch the local 1.7B but starve cloud restructuring. Skipped
        // entirely in .relaxed.
        if mode == .strict {
            if let reason = strictBudgetCheck(
                polish: cleaned,
                original: original,
                cleanupLevel: cleanupLevel,
                userVocabulary: userVocabulary
            ) {
                logReject(rule: "strict:\(reason)", input: original, polish: polish)
                return nil
            }
        } else {
            let isHighPre = (cleanupLevel?.lowercased() == "high")

            // Speaker wording: a polish may not swap the speaker's units or date order, and on the
            // light and medium paths may not add or drop words or cut a sentence short. Falls back
            // to the cleaned original. See the SPEAKER WORDING section below.
            if let problem = speakerWordingProblem(polish: cleaned, original: original, highLevel: isHighPre, correcting: correcting) {
                logReject(rule: "speaker-wording:\(problem)", input: original, polish: polish)
                return nil
            }

            // LIGHT-TOUCH WORD FIDELITY. For none/light/medium the brief is
            // voice-PRESERVING: the model must not substitute one word for a
            // different word. The proper-noun / number / email / URL guards
            // above tolerate a couple of losses (typo collapse) and only catch
            // ≥4-char Capitalized words. That's too loose for the light path:
            // the failure the user reports is the model "helpfully" changing a
            // distinctive token ("Diatype" → "Diatribe", "veCRV" → "recurve",
            // "GPT-4" → "GPT four") into a different word. So on the light path
            // we additionally require every DISTINCTIVE input token to survive
            // verbatim:
            //   - any Capitalized token (e.g. "Diatype", "Slack", names)
            //   - any token with internal capitals or digits (e.g. "veCRV",
            //     "GPT-4", "S3", "iOS", "k8s")
            //   - any user-vocabulary term present in the input
            // If such a token is in the input but its exact form is absent from
            // the polish, that's word drift → reject to the safer near-verbatim
            // fallback. Skipped entirely on "high" (aggressive rewrite is
            // allowed to recase/restructure these).
            if !isHighPre,
               let drifted = driftedDistinctiveToken(
                   polish: cleaned,
                   original: original,
                   userVocabulary: userVocabulary
               ) {
                logReject(rule: "light-word-drift:\(drifted)", input: original, polish: polish)
                return nil
            }

            // Relaxed: block degenerate drift. The bounds TIGHTEN for the
            // light-touch path (none/light/medium) because, post-
            // rearchitecture, those levels run a voice-PRESERVING brief —
            // the output is expected to stay close to the input length.
            // Only "high" (the explicit aggressive-rewrite brief) keeps the
            // old generous 10%-to-4x window for legitimate restructuring.
            //
            // NOTE: any conversational lead-in ("Here's a cleaner version:")
            // and wrapping quotes are stripped UPSTREAM in
            // PolishPostprocessor.validateAndProcess BEFORE this runs, so
            // `cleaned` here is already the real content. That means:
            //   - the shrink floor compares against the true polish (a stripped
            //     preamble can't drag the count under the floor — it only moves
            //     the polish CLOSER to the original length), and
            //   - the expansion ceiling won't false-trip on a preamble that
            //     would otherwise have inflated the char count.
            // The light-touch floor (origCount/2) leaves ample headroom for the
            // handful of chars a preamble strip removes.
            let origCount = original.count
            let isHigh = isHighPre

            // Shrink floor: high allows down to 10% of input; light-touch
            // levels should not lose more than ~half the characters (filler
            // strip + punctuation is the most that legitimately shrinks).
            // A spoken correction ("no wait, scratch that") can legitimately remove most of the input.
            // A bulleted list keeps its items and drops the spoken lead-in ("make a quick list, um"),
            // so it can be shorter than half the input without losing words.
            let shrinkFloor = isHigh ? (origCount / 10)
                : (correcting ? origCount / 4
                : (isBulletedList(cleaned) ? origCount / 3 : origCount / 2))
            if origCount > 40, cleaned.count < max(8, shrinkFloor) {
                logReject(rule: "relaxed:catastrophic-shrink", input: original, polish: polish)
                return nil
            }
            // Expansion ceiling: high allows up to 4x (email reformat +
            // signature + bullets); light-touch should stay within ~1.8x
            // (punctuation, list bullets, salutation newlines add chars but
            // not whole new content).
            let expandMultiplier = isHigh ? 4 : 2
            let expandFloor = isHigh ? 80 : 60
            let expandCeil = isHigh
                ? origCount * expandMultiplier
                : (origCount * 9 / 5) // 1.8x
            if origCount > 0, cleaned.count > max(expandFloor, expandCeil) {
                logReject(rule: "relaxed:runaway-expansion", input: original, polish: polish)
                return nil
            }
        }

        return cleaned
    }

    /// Phrases a model writes when it narrates the job rather than doing it. A phrase the
    /// speaker actually said (in the original, any case) does not count.
    static let metaPhrases: [String] = [
        "the user wants", "the user asked", "the user is asking", "the user says", "the user's request",
        "i need to clean", "let me clean", "my task is", "cleaned-up version", "cleaned up version",
        "here is the cleaned", "here's the cleaned", "here is a cleaned", "here's a cleaned"
    ]

    static func metaCommentary(polish: String, original: String) -> String? {
        let lowerPolish = polish.lowercased()
        let lowerOriginal = original.lowercased()
        return metaPhrases.first { lowerPolish.contains($0) && !lowerOriginal.contains($0) }
    }

    /// Explicit corrections ("no wait", "scratch that") legitimately delete a lot of words:
    /// the retracted phrase and the cue go, and only the replacement stays.
    static func containsCorrectionCue(_ original: String) -> Bool {
        lastCorrectionCueEnd(in: original) != nil
    }

    /// Spoken self-correction markers. "I mean" only counts as a correction in this list; the
    /// negation guard below still protects any negation that comes after the marker.
    private static let correctionCues: [NSRegularExpression] = [
        #"\bno\s+wait\b"#, #"\bno\s+sorry\b"#, #"\bscratch\s+that\b"#, #"\bor\s+rather\b"#,
        #"\bi\s+mean\b"#, #"\bi\s+meant\b"#, #"\bno\s+no\b"#, #"\bcorrection\b"#,
        #"\bactually\s+no\b"#, #"\bno\s+actually\b"#, #"\bnever\s*mind\b"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// UTF-16 offset just past the last correction marker in `text`, or nil when there is none.
    static func lastCorrectionCueEnd(in text: String) -> Int? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var end: Int? = nil
        for rx in correctionCues {
            for match in rx.matches(in: text, range: full) {
                end = max(end ?? 0, match.range.location + match.range.length)
            }
        }
        return end
    }

    // MARK: - Internals

    private static func logReject(rule: String, input: String, polish: String) {
        print("[VOICE-SANITIZE] rejected: rule=\(rule) inputChars=\(input.count) outputChars=\(polish.count)")
    }

    /// Extended-pictographic chars in `polish` that aren't in `original`.
    private static func containsEmojiNotInOriginal(polish: String, original: String) -> Bool {
        var origEmojis = Set<UnicodeScalar>()
        for s in original.unicodeScalars where s.properties.isEmojiPresentation || s.properties.isEmoji {
            origEmojis.insert(s)
        }
        for s in polish.unicodeScalars {
            // Properties.isEmoji matches digit/asterisk/# too (keycap chars).
            // Require Extended_Pictographic for true emoji-only test.
            guard s.properties.isEmojiPresentation || isExtendedPictographic(s) else { continue }
            if !origEmojis.contains(s) { return true }
        }
        return false
    }

    /// True for Unicode "Extended_Pictographic" — covers all emoji ranges
    /// without false-positives on digits / # / *. Approximated by the
    /// dominant emoji blocks; conservative on the side of allowing.
    private static func isExtendedPictographic(_ s: UnicodeScalar) -> Bool {
        let v = s.value
        return (0x1F300...0x1FAFF).contains(v)   // misc symbols & pictographs, extended ranges
            || (0x2600...0x27BF).contains(v)     // misc symbols, dingbats
            || (0x1F1E6...0x1F1FF).contains(v)   // regional indicator (flags)
    }

    /// Returns the first vulgar word introduced by polish, or nil.
    private static let vulgarWords: Set<String> = [
        "cuck", "fuck", "fucking", "fucked", "fucker",
        "shit", "shitty", "shitting",
        "cunt", "bitch", "bastard",
        "nigger", "nigga", "faggot", "fag", "retard", "retarded",
        "asshole", "dick", "cock", "pussy", "twat", "whore", "slut"
    ]

    private static func injectedVulgarity(polish: String, original: String) -> String? {
        let origSet = wordSet(original)
        let polSet = wordSet(polish)
        for v in vulgarWords {
            if polSet.contains(v) && !origSet.contains(v) { return v }
        }
        return nil
    }

    private static func wordSet(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    }

    /// Detect catastrophic semantic flip: original had a negation
    /// ("don't think") that's flipped to its positive ("think") in polish.
    private static let criticalFlips: [(neg: String, pos: String)] = [
        ("don't think", "think"),
        ("do not think", "think"),
        ("shouldn't", "should"),
        ("should not", "should"),
        ("won't", "will"),
        ("will not", "will"),
        ("can't", "can"),
        ("cannot", "can"),
    ]

    private static func hasSemanticFlip(polish: String, original: String) -> Bool {
        let o = original.lowercased()
        let p = polish.lowercased()
        for flip in criticalFlips {
            let origHasNeg = containsWord(flip.neg, in: o)
            let polLostNeg = !containsWord(flip.neg, in: p) && containsWord(flip.pos, in: p)
            if origHasNeg && polLostNeg { return true }
        }
        return false
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Returns the first proper noun (≥4 chars, capitalized) present in
    /// original but not in polish. Allows up to 2 losses (typo collapse,
    /// pronoun replacement) — only fires when ≥3 names disappear.
    private static func missingProperNouns(polish: String, original: String) -> String? {
        let origWords = original.components(separatedBy: .whitespacesAndNewlines)
        let nouns = origWords.compactMap { w -> String? in
            let stripped = w.trimmingCharacters(in: .punctuationCharacters)
            guard stripped.count >= 4,
                  stripped.first?.isUppercase == true,
                  stripped.dropFirst().contains(where: { $0.isLowercase })
            else { return nil }
            return stripped
        }
        guard nouns.count >= 2 else { return nil }
        let polLower = polish.lowercased()
        let lost = nouns.filter { !polLower.contains($0.lowercased()) }
        if lost.count > 2 { return lost.first }
        return nil
    }

    /// Extract all multi-digit numbers (≥2 digits) from original. If more
    /// than 1 is missing from polish AND wasn't replaced by a normalized
    /// form ("twenty three" → "23", "$4.7M"), reject. Single-digit drops
    /// are tolerated (filler counts).
    private static func missingSignificantNumber(polish: String, original: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: #"\b\d{2,}\b"#) else { return nil }
        let ns = original as NSString
        let matches = rx.matches(in: original, range: NSRange(location: 0, length: ns.length))
        let nums = matches.map { ns.substring(with: $0.range) }
        guard !nums.isEmpty else { return nil }
        let polDigits = polish.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            .map { Character($0) }
            .reduce("") { $0 + String($1) }
        let lost = nums.filter { !polDigits.contains($0) && !polish.contains($0) }
        // Allow up to 1 loss (e.g. "year 2025" → "this year" is fine if
        // it was the ONLY number). 2+ lost numbers = the model deleted
        // material content.
        if lost.count > 1 { return lost.first }
        return nil
    }

    private static func missingEmail(polish: String, original: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#) else { return nil }
        let ns = original as NSString
        let matches = rx.matches(in: original, range: NSRange(location: 0, length: ns.length))
        let polLower = polish.lowercased()
        for m in matches {
            let email = ns.substring(with: m.range)
            if !polLower.contains(email.lowercased()) { return email }
        }
        return nil
    }

    private static func missingURL(polish: String, original: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: #"https?://[^\s)\]\}>,]+"#) else { return nil }
        let ns = original as NSString
        let matches = rx.matches(in: original, range: NSRange(location: 0, length: ns.length))
        let polLower = polish.lowercased()
        for m in matches {
            let url = ns.substring(with: m.range)
            if !polLower.contains(url.lowercased()) { return url }
        }
        return nil
    }

    // MARK: - Light-path distinctive-token preservation
    //
    // The light-touch brief (none/light/medium) must not substitute one word
    // for another. This guard enforces it deterministically: every DISTINCTIVE
    // token in the input must reappear verbatim (case-insensitively for the
    // body, but the EXACT spelling must be present) in the polish. A token is
    // "distinctive" when losing or altering it would change the speaker's
    // actual words:
    //
    //   - Capitalized tokens (≥2 chars, first letter uppercase) — names,
    //     brands, products ("Diatype", "Slack").
    //   - Internal-caps / digit-bearing tokens ("veCRV", "GPT-4", "iOS", "S3",
    //     "k8s", "H100") — never ordinary prose, always a deliberate identifier.
    //   - User-vocabulary terms present in the input.
    //
    // Conservatism (so normal cleanup is never false-rejected):
    //   - We compare TOKENS the SPEAKER actually produced, against the polish's
    //     token set. Capitalization changes alone do NOT count as drift (the
    //     brief is allowed to capitalize), so the match is case-insensitive on
    //     the surrounding text but requires the distinctive token's character
    //     sequence to be present.
    //   - Pure all-lowercase, all-alpha words are NOT checked here (sentence-
    //     start capitalization, filler removal, and punctuation are legitimate
    //     and must not trip this). Only distinctive tokens are guarded.
    //   - Sentence-start words that the speaker happened to capitalize are
    //     filtered out: a token is only treated as a "name-shaped" capitalized
    //     token when it does NOT also appear lowercased elsewhere and is not the
    //     leading token of the whole input (where caps are ambiguous). This
    //     avoids rejecting "Hello" → "hello" style legitimate recasing.
    //   - We allow ONE distinctive token to vanish (rare ASR/​self-correction
    //     overlap) and only reject when a distinctive token is altered/dropped
    //     AND it was not obviously a self-corrected duplicate.
    static func driftedDistinctiveToken(
        polish: String,
        original: String,
        userVocabulary: [String]?
    ) -> String? {
        // Tokenize on whitespace; strip surrounding punctuation but keep
        // internal punctuation/digits (so "GPT-4" and "veCRV." → "veCRV").
        func tokenize(_ s: String) -> [String] {
            s.split(whereSeparator: { $0.isWhitespace }).map {
                String($0).trimmingCharacters(in: .punctuationCharacters)
            }.filter { !$0.isEmpty }
        }

        let origTokens = tokenize(original)
        guard !origTokens.isEmpty else { return nil }
        let polishTokens = tokenize(polish)
        // Exact-spelling presence set (verbatim) + lowercased presence set.
        let polishExact = Set(polishTokens)
        let polishLower = Set(polishTokens.map { $0.lowercased() })

        // Words the speaker used lowercased somewhere (so a Capitalized
        // occurrence is just sentence-start, not a name).
        let origLowercaseUsage = Set(
            origTokens.filter { $0 == $0.lowercased() }.map { $0.lowercased() }
        )

        let vocabLower = Set((userVocabulary ?? []).map { $0.lowercased() })

        func hasInternalCapOrDigit(_ t: String) -> Bool {
            guard t.count >= 2 else { return false }
            let body = t.dropFirst()
            let hasDigit = t.contains(where: { $0.isNumber })
            let hasInternalUpper = body.contains(where: { $0.isUppercase })
            return hasDigit || hasInternalUpper
        }

        func isCapitalizedName(_ t: String, index: Int) -> Bool {
            guard let first = t.first, first.isUppercase, t.count >= 2 else { return false }
            // All-caps short tokens are acronyms — handled by internal-caps
            // branch when they contain digits; pure acronyms ("USA") are
            // proper-noun-ish and worth protecting, but we leave them to the
            // existing proper-noun guard to avoid double-counting.
            // Skip the very first token of the input (leading caps ambiguous).
            if index == 0 { return false }
            // If the same word appears lowercased elsewhere in the input, the
            // capital is positional (sentence start), not a name.
            if origLowercaseUsage.contains(t.lowercased()) { return false }
            // Must contain a lowercase letter (so "I" / "A" / all-caps are
            // excluded here; those are handled elsewhere).
            return t.dropFirst().contains(where: { $0.isLowercase })
        }

        var lost: [String] = []
        for (i, tok) in origTokens.enumerated() {
            let lower = tok.lowercased()
            let distinctive =
                hasInternalCapOrDigit(tok) ||
                isCapitalizedName(tok, index: i) ||
                vocabLower.contains(lower)
            guard distinctive else { continue }

            // Survival test. Internal-caps/digit tokens must survive with their
            // EXACT character sequence (case-sensitive) — "GPT-4" → "gpt 4"
            // is drift. Capitalized names / vocab terms may be recased, so a
            // case-insensitive match counts as survival.
            if hasInternalCapOrDigit(tok) {
                if polishExact.contains(tok) { continue }
            } else {
                if polishLower.contains(lower) { continue }
            }
            lost.append(tok)
        }

        // Tolerate exactly one vanished distinctive token (self-correction /
        // duplicate overlap). Reject on the second — that's real word drift.
        if lost.count > 1 { return lost.first }
        return nil
    }

    // MARK: - Strict-mode budget check (legacy)
    //
    // This intentionally does NOT duplicate every detail of the Qwen3Polisher
    // sanitize() — that function is the legacy, comprehensive strict path
    // and stays where it is for the local 1.7B caller. The strict branch
    // here is a SECONDARY guard suitable for any new strict caller (e.g.
    // when the local path is updated to use Sanitizer.run uniformly).
    // It enforces: word-count drift, length drift, and absence of preamble
    // residue — the same three guards that caught >90% of local-1.7B
    // failures in production.

    private static func strictBudgetCheck(
        polish: String,
        original: String,
        cleanupLevel: String?,
        userVocabulary: [String]?
    ) -> String? {
        let originalWords = original.split { $0.isWhitespace }.count
        let polishWords = polish.split { $0.isWhitespace }.count
        let wordDelta = abs(originalWords - polishWords)
        let basePct: Int
        switch cleanupLevel?.lowercased() {
        case "none":   basePct = 5
        case "light":  basePct = 15
        case "high":   basePct = 60
        default:       basePct = 30
        }
        let wordBudget = max(3, originalWords * basePct / 100)
        if wordDelta > wordBudget {
            return "word-drift(\(originalWords)→\(polishWords),budget=\(wordBudget))"
        }
        let lenDelta = abs(original.count - polish.count)
        let lenBudget = max(20, original.count * max(35, basePct) / 100)
        if lenDelta > lenBudget {
            return "length-drift(\(original.count)→\(polish.count),budget=\(lenBudget))"
        }
        _ = userVocabulary // reserved for future vocab-aware relaxation
        return nil
    }
}

// MARK: - Speaker wording (units, date order, added and dropped words)
//
// The polish may fix punctuation, casing, filler and obvious speech errors. It may not change
// the words the speaker used for units or dates, and on the light and medium paths it may not
// add a sentence the speaker did not say, drop a content word, or end a sentence on a dangling
// word. Each rule returns a short reason so the rejection log says which one fired.

extension Sanitizer {

    /// The first wording problem in a relaxed-mode polish, or nil when the speaker's wording survives.
    /// Units and dates are checked at every cleanup level. `high` is the explicit restructuring
    /// brief, so the added, dropped and dangling checks do not apply to it. When the speaker corrected
    /// themselves ("14th, no sorry, the 15th"), the words they took back are meant to go, so the
    /// dropped-word check does not apply.
    static func speakerWordingProblem(polish: String, original: String, highLevel: Bool, correcting: Bool) -> String? {
        let origTokens = wordTokens(original)
        let candTokens = wordTokens(polish)
        let origSet = Set(origTokens)
        let candSet = Set(candTokens)

        // Units: a unit word the speaker said must still be there in the same form.
        for token in unitWords where origSet.contains(token) && !candSet.contains(token) {
            return "unit:\(token)"
        }
        // Dates: "the 12th of March" and "March 12th" each stay in the order the speaker said.
        if !datesKeepOrder(polish: polish, original: original) {
            return "date-order"
        }
        // Languages: a Dutch sentence (or a Dutch part of a mixed one) is not translated.
        if translatedDutch(polish: candTokens, original: origTokens) {
            return "translated-dutch"
        }
        // Hedges: "maybe", "probably" and the like carry the speaker's uncertainty. Only the
        // restructuring brief (high) is checked here; light and medium may drop them as cleanup.
        if highLevel {
            for hedge in hedgeWords where origSet.contains(hedge) && !candSet.contains(hedge) {
                return "hedge:\(hedge)"
            }
        }

        guard !highLevel else { return nil }

        // Added words: a sentence the speaker did not say shows up as several new content words.
        let candContent = candTokens.filter { !isNumeral($0) && !numberWords.contains($0) && !functionWords.contains($0) }
        let novel = candContent.filter { !origSet.contains($0) }
        if novel.count >= 3, Double(novel.count) / Double(max(candContent.count, 1)) >= 0.25 {
            return "added-words:\(novel.prefix(3).joined(separator: ","))"
        }

        // Dropped words: two or more content words from the speaker are gone. Skipped after a
        // spoken correction, where the words the speaker took back are supposed to go. Spelled
        // numbers that became digits ("twenty five" to "25") are not dropped words, and when the
        // polish turned the speaker's items into a bulleted or numbered list, the spoken lead-in
        // ("make a quick list", "I think that's it") may go.
        if !correcting, !isBulletedList(polish) {
            let dropped = Set(origTokens.filter {
                $0.count >= 4 && !isNumeral($0) && !numberWords.contains($0) && !functionWords.contains($0)
                    && !fillerWords.contains($0) && !candSet.contains($0)
            })
            if dropped.count >= 2 {
                return "dropped-words:\(dropped.sorted().prefix(3).joined(separator: ","))"
            }
        }

        // Dangling end: a sentence cut short before a function word ("I think the budget is.").
        // A function word that the speaker said mid-sentence and that is followed by words the
        // polish kept ("log in then", "vitamin A then") is not cut short.
        for sentence in polish.split(whereSeparator: { ".!?\n".contains($0) }) {
            let tokens = wordTokens(String(sentence))
            guard tokens.count >= 3, let last = tokens.last else { continue }
            if PolishNormalizer.trailingFunctionWords.contains(last), last != origTokens.last,
               isCutShort(last, origTokens: origTokens, candSet: candSet) {
                return "dangling-end:\(last)"
            }
        }
        return nil
    }

    /// Words that carry the speaker's uncertainty.
    static let hedgeWords: [String] = ["maybe", "probably", "perhaps", "possibly", "might", "guess"]

    /// Spelled-out number words. Writing them as digits is a format change, not a dropped word.
    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion"
    ]

    /// True when the polish is a bulleted or numbered list, one item per line.
    static func isBulletedList(_ polish: String) -> Bool {
        polish.range(of: #"(?m)^\s*(?:[-*\u2022]|\d{1,2}[.)])\s+\S"#, options: .regularExpression) != nil
    }

    /// True when the polish has at least as many Dutch function words as the original needs to
    /// stay Dutch, and it has lost most of them. A Dutch sentence rendered in English is a translation.
    static func translatedDutch(polish: [String], original: [String]) -> Bool {
        let origHits = original.filter { dutchMarkers.contains($0) }.count
        guard origHits >= 3 else { return false }
        let candHits = polish.filter { dutchMarkers.contains($0) }.count
        return candHits * 2 < origHits
    }

    private static let dutchMarkers: Set<String> = [
        "de", "het", "een", "ik", "je", "niet", "geen", "wil", "dat", "dan", "naar", "om", "er",
        "ben", "zijn", "hebben", "morgen", "op", "ook", "maar", "klopt", "prima", "gehaald", "klaar", "sturen"
    ]

    /// A function word ends a sentence too early when the speaker said words after it that the
    /// polish no longer has. If every place the speaker said it is followed by words the polish kept,
    /// the sentence was not cut short.
    private static func isCutShort(_ word: String, origTokens: [String], candSet: Set<String>) -> Bool {
        let positions = origTokens.indices.filter { origTokens[$0] == word }
        if positions.isEmpty { return true }
        return positions.contains { i in
            i + 1 < origTokens.count && !candSet.contains(origTokens[i + 1])
        }
    }

    /// Unit words the speaker can say. A polish that writes the symbol or abbreviation instead
    /// ("kilos" to "kg", "percent" to "%") or drops the unit has changed what was said.
    static let unitWords: [String] = [
        "percent", "dollar", "dollars", "euro", "euros", "pound", "pounds",
        "kilo", "kilos", "kilogram", "kilograms", "gram", "grams",
        "kilometer", "kilometers", "kilometre", "kilometres", "meter", "meters", "metre", "metres",
        "mile", "miles", "milligram", "milligrams", "milliliter", "milliliters", "millilitre", "millilitres",
        "millisecond", "milliseconds",
        "degree", "degrees", "liter", "liters", "litre", "litres", "inch", "inches", "foot", "feet",
        "ounce", "ounces", "hour", "hours", "minute", "minutes"
    ]

    private static let months = "January|February|March|April|May|June|July|August|September|October|November|December"

    /// Every "<day> of <month>" in the speaker's text must survive in the same order.
    static func datesKeepOrder(polish: String, original: String) -> Bool {
        // "the 12th of March" must stay "the 12th of March" (no "March 12").
        if let rx = try? NSRegularExpression(pattern: #"\b(\d{1,2}(?:st|nd|rd|th)?)\s+of\s+("# + months + #")\b"#,
                                             options: [.caseInsensitive]) {
            let ns = original as NSString
            for match in rx.matches(in: original, range: NSRange(location: 0, length: ns.length)) {
                let day = ns.substring(with: match.range(at: 1))
                let month = ns.substring(with: match.range(at: 2))
                let kept = #"\b"# + NSRegularExpression.escapedPattern(for: day) + #"\s+of\s+"#
                    + NSRegularExpression.escapedPattern(for: month) + #"\b"#
                if polish.range(of: kept, options: [.regularExpression, .caseInsensitive]) == nil {
                    return false
                }
            }
        }
        // "March 12th" must stay "March 12th" (no "12th of March"). A suffix may be added or dropped.
        if let rx = try? NSRegularExpression(pattern: #"\b("# + months + #")\s+(\d{1,2})(?:st|nd|rd|th)?\b"#,
                                             options: [.caseInsensitive]) {
            let ns = original as NSString
            for match in rx.matches(in: original, range: NSRange(location: 0, length: ns.length)) {
                let month = ns.substring(with: match.range(at: 1))
                let day = ns.substring(with: match.range(at: 2))
                let kept = #"\b"# + NSRegularExpression.escapedPattern(for: month) + #"\s+"#
                    + NSRegularExpression.escapedPattern(for: day) + #"(?:st|nd|rd|th)?\b"#
                if polish.range(of: kept, options: [.regularExpression, .caseInsensitive]) == nil {
                    return false
                }
            }
        }
        return true
    }

    /// Lowercase letters and digits, apostrophes removed ("I'm" becomes "im").
    static func wordTokens(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    static func reviewTopicWords(_ text: String) -> Set<String> {
        Set(wordTokens(text).filter {
            $0.count >= 5 && $0.allSatisfy(\.isLetter) && !functionWords.contains($0) && !fillerWords.contains($0)
        })
    }

    private static func isNumeral(_ token: String) -> Bool {
        token.allSatisfy { $0.isNumber }
    }

    /// Words that carry no content on their own. Adding or dropping them is cleanup, not a change of meaning.
    private static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "to", "of", "in", "on", "at", "for", "with", "from",
        "by", "about", "as", "is", "are", "was", "were", "be", "been", "am", "it", "its", "this", "that",
        "these", "those", "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my",
        "your", "our", "their", "his", "do", "does", "did", "not", "no", "if", "then", "than", "there",
        "here", "what", "which", "who", "when", "where", "how", "will", "would", "should", "could", "can",
        "may", "might", "must", "shall", "have", "has", "had", "just"
    ]

    /// Spoken hesitations and hedges. Dropping these is the cleanup the brief asks for.
    private static let fillerWords: Set<String> = [
        "like", "basically", "actually", "really", "probably", "maybe", "kinda", "sorta", "honestly",
        "literally", "yeah", "okay", "sure", "guess", "mean", "well", "right", "anyway", "gonna", "wanna",
        "gotta", "dunno", "totally", "super", "pretty", "quite", "very", "know", "lol", "haha", "omg",
        "um", "uh"
    ]
}

// MARK: - Polish normalizer (dash repair and new-emoji removal before validation)
// Kept in this file so the Xcode project, which lists this file explicitly, compiles it.

public enum PolishNormalizer {

    /// Repairs dashes and drops emojis the speaker did not say. Idempotent.
    public static func normalize(polish: String, original: String) -> String {
        let dashed = normalizeDashes(polish)
        return removeNewEmojis(dashed, original: original)
    }

    // MARK: - Dashes

    private static let dashScalars: Set<Character> = ["\u{2014}", "\u{2015}", "\u{2013}"]

    /// Em dash, en dash and horizontal bar become punctuation that keeps the speaker's meaning:
    /// - between two digits ("5–10", "2024 — 2025", "9 — 5") becomes a hyphen ("5-10", "9-5")
    /// - between two days, two months, two quarters or two clock times ("Monday — Thursday",
    ///   "9am — 5pm") becomes "to" ("Monday to Thursday"). A full stop would split the range.
    /// - after punctuation, or at the start or end of the text, the dash is dropped
    /// - before a lowercase word ("I went — then I left") becomes a comma
    /// - before a capital ("It was late — Jordan left early today") becomes a full stop only when
    ///   both sides are clearly sentences (three or more words, no trailing function word); otherwise a comma
    /// - before anything else ("(", quote, symbol) becomes a comma
    public static func normalizeDashes(_ text: String) -> String {
        guard text.contains(where: { dashScalars.contains($0) }) else { return text }

        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            guard dashScalars.contains(ch) else {
                out.append(ch)
                i += 1
                continue
            }

            // Whether a space or the start of the text came before the dash (decides "-5" versus "5").
            let spacedBefore = out.isEmpty || out.last == " " || out.last == "\t" || out.last == "\n"
            // Drop spaces already written before the dash.
            while out.last == " " || out.last == "\t" { out.removeLast() }

            // Skip spaces after the dash to find the next real character.
            var j = i + 1
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            let left: Character? = out.last
            let right: Character? = j < chars.count ? chars[j] : nil

            if let l = left, let r = right, l.isNumber, r.isNumber {
                out.append("-")
            } else if let r = right, r.isNumber, j == i + 1, spacedBefore {
                // A dash with no space after it, before a digit, after a space or at the start: a minus sign
                // ("balance —5" is -5). Written as ASCII minus so it is not read as a clause break or a range.
                out.append(out.isEmpty ? "-" : " -")
            } else if left == nil || right == nil || right == "\n" {
                // Nothing to join on this side: drop the dash. A following line break is kept by the loop.
            } else if let l = left, ".,;:!?".contains(l) {
                out.append(" ")
            } else if isRange(before: out, after: chars, from: j) {
                out.append(" to ")
            } else if let r = right, r.isLowercase {
                out.append(", ")
            } else if let r = right, r.isUppercase, isClearSentenceBreak(before: out, after: chars, from: j) {
                out.append(". ")
            } else {
                out.append(", ")
            }

            i = j
        }

        return tidy(out)
    }

    /// Days, months and quarters that make a range when a dash sits between two of them.
    /// "may" is left out on purpose: it is also an ordinary verb.
    private static let rangeNames: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july", "august",
        "september", "october", "november", "december",
        "q1", "q2", "q3", "q4"
    ]

    /// Words that end a clause badly when a sentence is cut before them ("…the budget is.").
    static let trailingFunctionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "from",
        "by", "about", "as", "is", "are", "was", "were", "be", "that", "if", "so", "than",
        "my", "your", "our", "their", "his", "her", "its"
    ]

    /// True when the words either side of the dash name a range: two days, two months,
    /// two quarters, or two clock times.
    private static func isRange(before out: String, after chars: [Character], from j: Int) -> Bool {
        let leftTokens = words(in: String(out.suffix(40)))
        let rightTokens = words(in: String(chars[j..<min(chars.count, j + 40)]))
        guard let l = leftTokens.last, let r = rightTokens.first else { return false }
        if rangeNames.contains(normalizedWord(l)) && rangeNames.contains(normalizedWord(r)) {
            return true
        }
        return endsWithClockTime(leftTokens) && startsWithClockTime(rightTokens)
    }

    /// True when both sides are whole clauses: at least three words before the dash in the same
    /// sentence, at least three after it, and no dangling function word before the dash.
    private static func isClearSentenceBreak(before out: String, after chars: [Character], from j: Int) -> Bool {
        let sentenceStart = out.lastIndex(where: { ".!?\n".contains($0) }).map { out.index(after: $0) } ?? out.startIndex
        let leftWords = words(in: String(out[sentenceStart...]))
        var end = j
        while end < chars.count, !",;:.!?\n—–―".contains(chars[end]) { end += 1 }
        let rightWords = words(in: String(chars[j..<end]))
        guard leftWords.count >= 3, rightWords.count >= 3, let lastLeft = leftWords.last else { return false }
        return !trailingFunctionWords.contains(normalizedWord(lastLeft))
    }

    private static func words(in s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func isHour(_ t: String) -> Bool {
        t.range(of: #"^\d{1,2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    private static func isMeridiem(_ t: String) -> Bool {
        let n = normalizedWord(t)
        return n == "am" || n == "pm"
    }

    private static func isClockToken(_ t: String) -> Bool {
        normalizedWord(t).range(of: #"^\d{1,2}(:\d{2})?(am|pm)$"#, options: .regularExpression) != nil
    }

    /// "… at 9am", "… at 9 pm" (the last tokens are the time).
    private static func endsWithClockTime(_ tokens: [String]) -> Bool {
        guard let last = tokens.last else { return false }
        if isClockToken(last) { return true }
        return isMeridiem(last) && tokens.count >= 2 && isHour(normalizedWord(tokens[tokens.count - 2]))
    }

    /// "5pm …", "5 pm …" (the first tokens are the time).
    private static func startsWithClockTime(_ tokens: [String]) -> Bool {
        guard let first = tokens.first else { return false }
        if isClockToken(first) { return true }
        return isHour(normalizedWord(first)) && tokens.count >= 2 && isMeridiem(tokens[1])
    }

    /// Clears the artifacts that dash removal can leave behind.
    private static func tidy(_ text: String) -> String {
        var s = text
        // Dropping a dash after a comma or full stop can double the mark.
        s = s.replacingOccurrences(of: ",,", with: ",")
        s = s.replacingOccurrences(of: ", ,", with: ",")
        s = s.replacingOccurrences(of: ".. ", with: ". ")
        s = s.replacingOccurrences(of: ". .", with: ".")
        s = s.replacingOccurrences(of: ",.", with: ".")
        s = s.replacingOccurrences(of: " ,", with: ",")
        // Collapse repeated spaces, but never touch line breaks.
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s
    }

    // MARK: - Emojis

    /// Removes pictographs the original did not contain. Emojis the speaker
    /// actually said stay.
    public static func removeNewEmojis(_ text: String, original: String) -> String {
        var originalSet = Set<UnicodeScalar>()
        for s in original.unicodeScalars where isPictographic(s) { originalSet.insert(s) }

        guard text.unicodeScalars.contains(where: { isPictographic($0) && !originalSet.contains($0) }) else {
            return text
        }

        var out = String.UnicodeScalarView()
        var removedPrevious = false
        for s in text.unicodeScalars {
            if isPictographic(s) && !originalSet.contains(s) {
                removedPrevious = true
                continue
            }
            // Variation selectors and joiners that belonged to a removed emoji.
            if removedPrevious, s.value == 0xFE0F || s.value == 0x200D {
                continue
            }
            removedPrevious = false
            out.append(s)
        }
        var s = String(out)
        // Removing an emoji between two spaces leaves a double space. Collapse only that,
        // and drop the space an emoji left at the very end ("Done. 🚀" becomes "Done.").
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        while s.last == " " { s.removeLast() }
        return s
    }

    // MARK: - Finishing touches (deterministic path and model output alike)

    /// Contractions that are safe to restore from the bare ASR form. Words that also
    /// exist as real words without the apostrophe ("its", "were", "ill", "id") are left out.
    private static let contractions: [(bare: String, full: String)] = [
        ("im", "I'm"), ("ive", "I've"), ("dont", "don't"), ("doesnt", "doesn't"), ("didnt", "didn't"),
        ("cant", "can't"), ("wont", "won't"), ("isnt", "isn't"), ("arent", "aren't"), ("wasnt", "wasn't"),
        ("werent", "weren't"), ("couldnt", "couldn't"), ("shouldnt", "shouldn't"), ("wouldnt", "wouldn't"),
        ("hasnt", "hasn't"), ("havent", "haven't"), ("youre", "you're"), ("theyre", "they're"),
        ("youve", "you've"), ("weve", "we've"), ("thats", "that's"), ("whats", "what's"),
        ("theres", "there's"), ("heres", "here's")
    ]

    /// Restores the apostrophe in a lowercase bare contraction ("dont" to "don't", "im" to "I'm").
    /// A capitalised spelling keeps its capital. Words already written with an apostrophe are untouched.
    public static func restoreContractions(_ text: String) -> String {
        var out = text
        for (bare, full) in contractions {
            guard let rx = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}'’_/@.\\-])\(bare)(?![\\p{L}\\p{N}'’_/@\\-]|\\.[\\p{L}\\p{N}])", options: [.caseInsensitive]) else { continue }
            let ns = out as NSString
            var result = ""
            var cursor = 0
            for match in rx.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let original = ns.substring(with: match.range)
                if original == bare || original.first?.isUppercase == true && original.dropFirst() == bare.dropFirst() {
                    result += original.first?.isUppercase == true ? full.prefix(1).uppercased() + full.dropFirst() : full
                } else {
                    result += original  // mixed case such as "DONT" stays as spoken
                }
                cursor = match.range.location + match.range.length
            }
            result += ns.substring(from: cursor)
            out = result
        }
        return out
    }

    /// Adds the full stop or question mark a single spoken sentence lost. Questions are recognised
    /// by their opening word. Multi-line text (lists, letters) and text already ending in
    /// punctuation or a closing quote or bracket are left alone.
    public static func ensureTerminalPunctuation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, !trimmed.contains("\n") else { return text }
        if ".?!…\"')]”’".contains(last) { return text }
        // Only openers that start questions and never commands ("do the research" is not a question).
        let words = trimmed.lowercased().split(separator: " ").prefix(2).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let firstWord = words.first ?? ""
        let questionWords: Set<String> = ["who", "when", "where", "why", "which", "is", "are", "am", "was", "were",
                                          "does", "did", "isn't", "aren't", "wasn't", "weren't", "doesn't", "didn't", "what's", "who's", "where's", "how's", "why's", "what're", "who're"]
        let questionPairs: Set<String> = ["can you", "can i", "can we", "could you", "could i", "could we", "would you",
                                          "would we", "will you", "will we", "should we", "should i", "should you",
                                          "do you", "do we", "do i", "do they", "have you", "have we", "did you"]
        // "what" and "how" open a question only when a question word follows ("what time", "how are").
        // "What a lovely day" and "How nice of you" are statements.
        let auxiliarySecond: Set<String> = ["is", "are", "was", "were", "do", "does", "did", "can", "could", "will", "would",
                                            "should", "shall", "may", "might", "must", "have", "has", "had", "about", "much",
                                            "many", "long", "often", "time", "day", "kind", "sort", "you", "i", "we", "they",
                                            "he", "she", "it", "to", "far", "old", "come"]
        let secondWord = words.count > 1 ? words[1] : ""
        let whIsQuestion = ["what", "how"].contains(firstWord) && auxiliarySecond.contains(secondWord)
        let isQuestion = questionWords.contains(firstWord) || whIsQuestion || questionPairs.contains(words.joined(separator: " "))
        return trimmed + (isQuestion ? "?" : ".")
    }

    /// The last two steps for every polish result, applied after the rule-based postprocessor.
    /// Skipped for non-English text, which the pipeline passes through as the speaker said it.
    public static func finish(_ text: String, isNonEnglish: Bool) -> String {
        guard !isNonEnglish else { return text }
        return ensureTerminalPunctuation(restoreContractions(text))
    }

    // MARK: - Substituted facts

    /// Detects a number or name the model swapped for a near-identical one: "4500" became
    /// "4050", "Priya" became "Pria". Dropping a token alone is allowed (fillers, restarts),
    /// and so is a new token with nothing lost (spelled numbers, "3 pm" to "3:00"). Only a
    /// lost token together with a new, similar token of the same kind counts, because that
    /// is a wrong fact rather than a cleanup. Returns the lost token, or nil.
    public static func substitutedFact(polish: String, original: String) -> String? {
        substitutedNumber(polish: polish, original: original) ?? substitutedName(polish: polish, original: original)
    }

    private static func substitutedNumber(polish: String, original: String) -> String? {
        let origNums = digitRuns(original)
        guard !origNums.isEmpty else { return nil }
        let polNums = digitRuns(stripListMarkers(polish))
        let lost = origNums.subtracting(polNums)
        let added = polNums.subtracting(origNums)
        guard !lost.isEmpty, !added.isEmpty else { return nil }
        for token in lost.sorted() {
            if added.contains(where: { $0.count == token.count && editDistance($0, token) <= 2 && $0 != token }) {
                return token
            }
        }
        return nil
    }

    private static func substitutedName(polish: String, original: String) -> String? {
        let origNames = properNames(original)
        guard !origNames.isEmpty else { return nil }
        let lowerOriginal = Set(original.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        let polNames = properNames(polish)
        let polWords = Set(polish.components(separatedBy: CharacterSet.alphanumerics.inverted))
        let lost = origNames.filter { !polWords.contains($0) }
        guard !lost.isEmpty else { return nil }
        let added = polNames.filter { !lowerOriginal.contains($0.lowercased()) && !origNames.contains($0) }
        guard !added.isEmpty else { return nil }
        for name in lost {
            if added.contains(where: { editDistance($0.lowercased(), name.lowercased()) <= 2 }) {
                return name
            }
        }
        return nil
    }

    /// Multi-digit and single-digit runs, with thousands separators removed ("4,500" → "4500").
    private static func digitRuns(_ text: String) -> Set<String> {
        guard let rx = try? NSRegularExpression(pattern: #"\d+(?:,\d{3})*(?:\.\d+)?"#) else { return [] }
        let ns = text as NSString
        return Set(rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).replacingOccurrences(of: ",", with: "")
        })
    }

    /// Numbered-list markers ("2. ", "3) ") are formatting, not facts.
    private static func stripListMarkers(_ text: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: #"(?m)^\s*\d{1,2}[.)]\s"#) else { return text }
        return rx.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }

    /// Capitalised words of three or more letters that are not the first word of a sentence
    /// or a line. Those are where names and brands sit. A "1." or "2)" list marker counts as
    /// the start of a line, so the first word of each item is skipped too.
    private static func properNames(_ text: String) -> Set<String> {
        guard let rx = try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z]{2,}\b"#) else { return [] }
        let ns = text as NSString
        var names = Set<String>()
        for match in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: match.range.location).reversed()
            var sentenceStart = true
            for ch in before where ch != " " && ch != "\t" {
                // Walk back past the list marker's digits, so "2. Send" reads as line-initial.
                if ch.isNumber { continue }
                sentenceStart = ch == "." || ch == "!" || ch == "?" || ch == ":" || ch == "\n" || ch == ")"
                break
            }
            if !sentenceStart { names.insert(ns.substring(with: match.range)) }
        }
        return names
    }

    /// Plain Levenshtein distance, for short tokens only.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }

    private static func isPictographic(_ s: UnicodeScalar) -> Bool {
        if s.properties.isEmojiPresentation { return true }
        let v = s.value
        return (0x1F300...0x1FAFF).contains(v)
            || (0x2600...0x27BF).contains(v)
            || (0x1F1E6...0x1F1FF).contains(v)
    }
}
