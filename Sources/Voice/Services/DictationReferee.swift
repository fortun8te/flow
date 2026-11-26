import Foundation

/// A correction is anchored in the exact UTF-16 source that was scored.
struct LocalWordEdit: Sendable {
    let start: Int
    let end: Int
    let original: String
    let replacement: String

    var lengthChange: Int { replacement.utf16.count - (end - start) }
}

/// Apply non-overlapping, verified source edits and carry their locks forward.
/// All ranges in the returned list are in the edited text, not its input.
enum LocalWordEdits {
    static func apply<T>(_ text: String, changes: [T], edit: (T) -> LocalWordEdit)
        -> (text: String, changes: [T]) {
        let source = text as NSString
        var accepted: [(T, LocalWordEdit)] = []
        var cursor = 0
        for (change, e) in changes.map({ ($0, edit($0)) }).sorted(by: { $0.1.start < $1.1.start }) {
            guard e.start >= cursor, e.end > e.start, e.end <= source.length,
                  !e.replacement.isEmpty, e.original != e.replacement else { continue }
            let range = NSRange(location: e.start, length: e.end - e.start)
            guard Range(range, in: text) != nil, source.substring(with: range) == e.original else { continue }
            accepted.append((change, e))
            cursor = e.end
        }
        let output = NSMutableString(string: text)
        for (_, e) in accepted.reversed() {
            output.replaceCharacters(in: NSRange(location: e.start, length: e.end - e.start), with: e.replacement)
        }
        return (output as String, accepted.map { $0.0 })
    }

    static func locks(after edits: [LocalWordEdit], preserving prior: [NSRange] = []) -> [NSRange] {
        let ordered = edits.sorted { $0.start < $1.start }
        var result: [NSRange] = []
        var delta = 0
        for edit in ordered {
            result.append(NSRange(location: edit.start + delta, length: edit.replacement.utf16.count))
            delta += edit.lengthChange
        }
        for old in prior {
            // A later pass should never edit a locked word. If it does, the
            // new correction already contributes its own replacement lock.
            guard !ordered.contains(where: { $0.start < old.upperBound && $0.end > old.location }) else { continue }
            let shift = ordered.filter { $0.end <= old.location }.reduce(0) { $0 + $1.lengthChange }
            result.append(NSRange(location: old.location + shift, length: old.length))
        }
        return result.sorted { $0.location < $1.location }
    }
}

/// Flow's small judges in one place, the way COMPUTERUSE's referee does it for computer use: every judge
/// returns a probability and a short reason, so what Flow did to a dictation can be explained and tuned.
///
/// | Judge        | Looks at                     | Probability means                          | Can do            |
/// |--------------|------------------------------|--------------------------------------------|-------------------|
/// | language     | the text                     | share of words in clearly English sentences | skip English-only fixes |
/// | contentGuard | transcript vs cleanup output | the literal checks passed (links, numbers, names, negations, language) | fall back |
/// | pasteSafety  | transcript vs cleanup output | calibrated chance the cleanup is safe to paste | fall back |
/// | finalPass    | the text                     | rule pass (hesitations, stutters, list tags) | remove fillers |
/// | realWords    | the text                     | chance every swap made is right (tinyfix)    | fix homophones |
///
/// Reasons never contain transcript text. Word changes belong in the opt-out-aware run record;
/// the event log holds only numeric diagnostics, including for secure-field delivery failures.
enum DictationReferee {
    enum Judge: String, Codable, Sendable { case language, contentGuard, pasteSafety, finalPass, realWords }
    enum Action: String, Codable, Sendable { case keep, fix, fallback, skip }

    struct Verdict: Equatable, Codable, Sendable {
        let judge: Judge
        /// The chance that the text, as this judge leaves it, is right (or safe to paste).
        let probability: Double
        let action: Action
        /// Short plain words, never transcript text.
        let reason: String

        var telemetry: [String: Any] {
            ["judge": judge.rawValue, "p": (probability * 1000).rounded() / 1000, "action": action.rawValue, "reason": reason]
        }
    }

    // MARK: Language

    /// English, Dutch, mixed or other, from marker words; Apple's recogniser only for unclear sentences.
    static func language(_ text: String) -> Verdict {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var english = 0, total = 0
        for s in sentences {
            let n = DictationLanguage.words(s).count
            total += n
            if RealWordFixer.LanguageGate.sentenceIsEnglish(s) { english += n }
        }
        guard total > 0 else { return Verdict(judge: .language, probability: 0, action: .skip, reason: "no words") }
        let p = Double(english) / Double(total)
        if p >= 0.85 { return Verdict(judge: .language, probability: p, action: .keep, reason: "English") }
        if p <= 0.15 { return Verdict(judge: .language, probability: p, action: .skip, reason: "not English") }
        return Verdict(judge: .language, probability: p, action: .skip, reason: "mixed languages")
    }

    // MARK: Cleanup output (content guard + paste safety)

    /// The guard's literal checks, then the calibrated coverage score. The second verdict is nil when a
    /// literal check already failed.
    static func cleanup(source: String, output: String) -> (guardVerdict: Verdict, safety: Verdict?) {
        if let trip = WhisperNowContentGuard.hardTrip(source: source, output: output) {
            return (Verdict(judge: .contentGuard, probability: 0.02, action: .fallback, reason: plain(trip)), nil)
        }
        let guardVerdict = Verdict(judge: .contentGuard, probability: 0.98, action: .keep, reason: "details kept")
        let decision = PasteSafety.decide(source: source, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
        return (guardVerdict, Verdict(judge: .pasteSafety, probability: decision.probability,
                                      action: decision.accept ? .keep : .fallback, reason: decision.reason))
    }

    static func plain(_ trip: WhisperNowContentGuard.Trip) -> String {
        switch trip {
        case .empty: return "empty answer"
        case .cut: return "words dropped"
        case .negation: return "a negation lost"
        case .number: return "a number changed"
        case .name: return "a name changed"
        case .link: return "a link changed"
        case .coverage: return "language changed"
        }
    }

    // MARK: Final word pass

    /// DictationFinalPass is rules only (hesitations, stutters, list markup): a fixed confidence, from its
    /// tests and the 21 Nov dev panel (no wrong removals there).
    static func finalPass(_ text: String) -> (text: String, verdict: Verdict) {
        let out = DictationFinalPass.apply(text)
        let removed = max(0, DictationLanguage.words(text).count - DictationLanguage.words(out).count)
        if out == text { return (out, Verdict(judge: .finalPass, probability: 1, action: .keep, reason: "nothing to remove")) }
        return (out, Verdict(judge: .finalPass, probability: 0.99, action: .fix,
                             reason: removed == 0 ? "tidied list markup" : "removed \(removed) filler or repeated words"))
    }

    // MARK: Real words (tinyfix)

    /// The user's own words: dictionary entries and both sides of every replacement (snippet).
    static func protectedTerms() -> [String] {
        var terms = ProperNounVocabulary.preferredSpellingTerms()
        let file = WisprImportService.archiveDirectory.appendingPathComponent("replacements.json")
        if let data = try? Data(contentsOf: file),
           let pairs = try? JSONDecoder().decode([WisprImportService.Replacement].self, from: data) {
            for pair in pairs { terms.append(pair.from); terms.append(pair.to) }
        }
        return terms
    }

    static func realWords(_ text: String, mode: RealWordFixer.Mode, isCode: Bool = false,
                          protectedTerms: [String]? = nil, wait: Bool = false)
        -> (text: String, fixes: [RealWordFixer.Fix], verdict: Verdict) {
        guard RealWordFixer.isEnabled else {
            return (text, [], Verdict(judge: .realWords, probability: 1, action: .skip, reason: "turned off"))
        }
        guard !isCode else { return (text, [], Verdict(judge: .realWords, probability: 1, action: .skip, reason: "code")) }
        let fixer = RealWordFixer.shared
        guard fixer.model(wait: wait) != nil else {
            fixer.prewarm()
            return (text, [], Verdict(judge: .realWords, probability: 1, action: .skip, reason: fixer.readiness))
        }
        let result = fixer.fix(text, mode: mode, protectedTerms: protectedTerms ?? Self.protectedTerms(), wait: wait)
        guard !result.fixes.isEmpty else {
            return (text, [], Verdict(judge: .realWords, probability: 1, action: .keep, reason: "no mix-ups"))
        }
        let p = result.fixes.map(\.probability).reduce(1, *)
        return (result.text, result.fixes,
                Verdict(judge: .realWords, probability: p, action: .fix,
                        reason: result.fixes.count == 1 ? "fixed 1 mixed-up word" : "fixed \(result.fixes.count) mixed-up words"))
    }

    /// Writes scores and positions only. Text is already captured by the run's stage diff.
    static func trace(_ fixes: [RealWordFixer.Fix], mode: RealWordFixer.Mode, ms: Double) {
        guard !fixes.isEmpty, !BackgroundActivityGate.privacyMode else { return }
        for fix in fixes {
            Telemetry.log("realword.fix", properties: [
                "mode": mode.rawValue,
                "margin": (Double(fix.margin) * 100).rounded() / 100, "value": (Double(fix.value) * 100).rounded() / 100,
                "p": (fix.probability * 1000).rounded() / 1000, "mixup": fix.knownMixup, "offset": fix.location,
                "ms": (ms * 10).rounded() / 10
            ])
        }
    }

    // MARK: Pipeline entry points

    /// CPU model scoring is independent of the UI actor. Preserve stage order
    /// but let new recording events and audio UI proceed while the model scores.
    static func background<T: Sendable>(collector: FlowRunCollector? = nil, _ work: @escaping @Sendable () -> T) async -> T {
        let activeCollector = collector ?? FlowRunCollector.current
        let task = Task.detached(priority: .userInitiated) {
            FlowRunCollector.$current.withValue(activeCollector) { work() }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    struct DictationPassResult: Sendable {
        let text: String
        let lockedRanges: [NSRange]
    }

    /// Dictation: preserve the existing text-only API for replay and other callers.
    static func dictationPass(_ text: String, isCode: Bool) -> String {
        dictationPassDetailed(text, isCode: isCode).text
    }

    /// TinyFix and the sound-alike scorer operate on successive immutable drafts.
    /// A later pass protects the precise occurrence fixed earlier, not every
    /// identical word in the draft. Length-changing edits update the offsets.
    static func dictationPassDetailed(_ text: String, isCode: Bool,
                                      vocabulary: [String] = []) -> DictationPassResult {
        let start = DispatchTime.now().uptimeNanoseconds
        guard !Task.isCancelled else { return DictationPassResult(text: text, lockedRanges: []) }
        let terms = protectedTerms() + vocabulary
        let result = realWords(text, mode: .dictation, isCode: isCode, protectedTerms: terms)
        FlowRunCollector.current?.decision("tinyfix", result.verdict.action.rawValue, reason: result.verdict.reason)
        if result.verdict.action != .skip { FlowRunCollector.current?.model("tinyfix", "tinyfix") }
        trace(result.fixes, mode: .dictation, ms: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        let fixed = result.fixes.map {
            LocalWordEdit(start: $0.location, end: $0.location + $0.original.utf16.count,
                          original: $0.original, replacement: $0.replacement)
        }
        let locks = LocalWordEdits.locks(after: fixed)
        guard !isCode, RealWordFixer.isEnabled, !Task.isCancelled else {
            return DictationPassResult(text: result.text, lockedRanges: locks)
        }
        let soundStart = DispatchTime.now().uptimeNanoseconds
        let sound = SoundAlikeCheck.check(result.text, protectedTerms: terms, protectedRanges: locks)
        traceSoundAlikes(sound.changes, started: soundStart)
        let soundEdits = sound.changes.map {
            LocalWordEdit(start: $0.start, end: $0.end, original: $0.original, replacement: $0.replacement)
        }
        return DictationPassResult(text: sound.text, lockedRanges: LocalWordEdits.locks(after: soundEdits, preserving: locks))
    }

    /// Text-only entry point for callers that do not need to propagate locks.
    static func soundAlikes(_ text: String, skipping: Set<String> = [], wait: Bool = false) -> String {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = SoundAlikeCheck.check(text, protectedTerms: protectedTerms() + Array(skipping), wait: wait)
        traceSoundAlikes(result.changes, started: start)
        return result.text
    }

    private static func traceSoundAlikes(_ changes: [SoundAlikeCheck.Decision], started: UInt64) {
        guard !changes.isEmpty, !BackgroundActivityGate.privacyMode, !Task.isCancelled else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        for change in changes {
            Telemetry.log("soundalike.fix", properties: [
                "delta": (Double(change.delta) * 100).rounded() / 100, "learned": change.learned,
                "ms": (ms * 10).rounded() / 10
            ])
        }
    }

    /// Opt+1, before the polish: fixes mixed-up real words in the selection. `nonWords` is the
    /// edit-distance dictionary pass for misspelled words (Qwen3Polisher.recoverTypedSpelling); the model
    /// judges each word with those repaired, because a garbled neighbour hides what was meant
    /// ("htey their going" reads clearly only as "they their going"). Only the real-word swaps are written
    /// back here; the non-word repairs stay with the polish, as before.
    static func typedPrePass(_ text: String, nonWords: (String) -> String) -> String {
        guard RealWordFixer.isEnabled, RealWordFixer.shared.isAvailable else {
            RealWordFixer.shared.prewarm()
            return text
        }
        // Only pay for the spelling pass when a mix-up word (their, your, form ...) is there at all.
        guard RealWordFixer.shared.hasCandidates(text, mode: .typed) else { return text }
        let start = DispatchTime.now().uptimeNanoseconds
        let cleaned = nonWords(text)
        let result = RealWordFixer.shared.fix(cleaned, mode: .typed, protectedTerms: protectedTerms())
        guard !result.fixes.isEmpty else { return text }
        let out = transplant(result.fixes, from: cleaned, onto: text)
        trace(result.fixes, mode: .typed, ms: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        return out
    }

    /// Writes fixes found in `cleaned` onto `original`: the k-th whole-word occurrence of the fixed word in
    /// `cleaned` is the k-th in `original`, when both texts hold that word the same number of times.
    static func transplant(_ fixes: [RealWordFixer.Fix], from cleaned: String, onto original: String) -> String {
        guard cleaned != original else {
            let out = NSMutableString(string: original)
            for fix in fixes.sorted(by: { $0.location > $1.location }) {
                out.replaceCharacters(in: NSRange(location: fix.location, length: (fix.original as NSString).length), with: fix.replacement)
            }
            return out as String
        }
        func occurrences(_ word: String, in text: String) -> [NSRange] {
            let pattern = #"(?<![\p{L}\p{N}'’])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}\p{N}'’])"#
            guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
            return rx.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
        }
        var edits: [(NSRange, String)] = []
        for fix in fixes {
            let inCleaned = occurrences(fix.original, in: cleaned), inOriginal = occurrences(fix.original, in: original)
            guard inCleaned.count == inOriginal.count,
                  let k = inCleaned.firstIndex(where: { $0.location == fix.location }) else { continue }
            edits.append((inOriginal[k], fix.replacement))
        }
        let out = NSMutableString(string: original)
        for (range, word) in edits.sorted(by: { $0.0.location > $1.0.location }) { out.replaceCharacters(in: range, with: word) }
        return out as String
    }
}
