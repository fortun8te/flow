import Foundation

/// Shared side-effect-free text preparation and delivery intent. Capture,
/// clipboard/history writes and actual insertion remain in AppDelegate.
@MainActor
enum DictationTextPreparation {
    enum Rejection: String, Codable { case empty, nonLatin }
    struct Prepared {
        let rawText: String
        let command: TrailingPressEnter.Parsed
        let rejection: Rejection?
    }
    struct DeliveryIntent: Codable, Equatable {
        let shouldPaste: Bool
        let restoreClipboard: Bool
        let preFormatted: Bool
        let requireCapturedTarget: Bool
        let shouldSubmit: Bool
    }
    /// `endedByVoiceStop`: true only when the spoken stop word ended this recording. Only then is the
    /// trailing stop word removed, so a real word like "salt" in push-to-talk text is never touched.
    static func prepare(segments: [TranscriptSegment], formatter: TextFormatter,
                        pressEnterEnabled: Bool, autoPaste: Bool, endedByVoiceStop: Bool = false) -> Prepared {
        let raw = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return Prepared(rawText: raw, command: .init(text: "", shouldSubmit: false), rejection: .empty) }
        if predominantlyNonLatin(raw) { return Prepared(rawText: raw, command: .init(text: raw, shouldSubmit: false), rejection: .nonLatin) }
        let timed = segments.map { (text: DictationFinalPass.joinBrokenSentences($0.text), startTime: $0.startTime, endTime: $0.endTime) }
        let formatted = formatter.formatSegments(timed)
        let text = endedByVoiceStop ? RecordingCoordinator.strippingTrailingStopWord(from: formatted) : formatted
        return Prepared(rawText: raw, command: TrailingPressEnter.parse(text, enabled: pressEnterEnabled && autoPaste), rejection: nil)
    }
    static func finalize(polished: String, formatted: String) -> String {
        let nonempty = polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? formatted : polished
        let result = WisprImportService.applyReplacements(to: AmericanSpelling.apply(DictationFinalPass.apply(nonempty)))
        return preservingFilenameCase(result, original: formatted)
    }

    static let sectionLimit = 900

    /// Use complete lines and prefer sentence ends inside a long line. The
    /// whitespace between sections stays outside the editor's input.
    static func cleanupSections(in text: String, limit: Int = sectionLimit) -> [Range<String.Index>] {
        guard limit > 0 else { return [] }
        var ranges: [Range<String.Index>] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var start = line.startIndex
            while start < line.endIndex {
                while start < line.endIndex && text[start].isWhitespace { text.formIndex(after: &start) }
                guard start < line.endIndex else { break }
                let limitIndex = text.index(start, offsetBy: limit, limitedBy: line.endIndex) ?? line.endIndex
                var end = limitIndex
                if limitIndex < line.endIndex {
                    let prefix = text[start...limitIndex]
                    let mid = text.index(start, offsetBy: limit / 2)
                    let sentenceEnd = prefix.indices.reversed().first { index in
                        index > mid && text[index].isWhitespace && ".!?".contains(text[text.index(before: index)])
                    }
                    if let boundary = sentenceEnd ?? prefix.lastIndex(where: \.isWhitespace) {
                        end = boundary
                    } else {
                        // A URL, pasted identifier or other long unbroken token
                        // is preserved as-is and never sent to the editor.
                        start = text[limitIndex..<line.endIndex].firstIndex(where: \.isWhitespace) ?? line.endIndex
                        continue
                    }
                }
                var contentEnd = end
                while contentEnd > start && text[text.index(before: contentEnd)].isWhitespace {
                    text.formIndex(before: &contentEnd)
                }
                if start < contentEnd { ranges.append(start..<contentEnd) }
                start = end
            }
        }
        return ranges
    }

    static func sectionRequestSeconds(tuned: Double, general: Double, remaining: Double) -> Double {
        // General inference is attempted before the tuned fallback; it has
        // its own allowance, but neither can extend the outer deadline.
        min(max(0, remaining), max(0, tuned) + max(0, general))
    }

    /// Keep successful sections if a later call times out. Sections that
    /// fail validation and all remaining source text pass through verbatim.
    static func cleanSections(in source: String, ranges: [Range<String.Index>],
                              deadline: ContinuousClock.Instant,
                              review: (@Sendable (String, String) async -> Bool)? = nil,
                              using cleanup: @escaping @Sendable (String) async -> String?) async
        -> (text: String, timedOut: Bool) {
        var parts: [String] = []
        var cursor = source.startIndex
        var timedOut = false
        // Review one guarded draft while the cleanup engine works on the next.
        // The original section stays in its slot until its own review resolves.
        var pending: (index: Int, edited: String, task: Task<Bool, Never>)?
        for range in ranges {
            if Task.isCancelled { break }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .milliseconds(50) else { timedOut = true; break }
            let original = String(source[range])
            // A long section gets the model's own request time (4 s + 30 ms a word), inside the overall deadline.
            // A flat 4 s let one slow 160-word section under load drop the cleanup of the whole dictation (22 Nov 2026).
            let words = original.split(whereSeparator: \.isWhitespace).count
            let seconds = sectionRequestSeconds(tuned: WhisperNowTunedPolisher.timeout(for: original),
                general: GeneralCleanupModel.liveExtraSeconds(words: words),
                remaining: Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
            let reply = await DictationDeadline.run(seconds: seconds) { await cleanup(original) }
            guard let answer = reply else { timedOut = true; break }
            parts.append(String(source[cursor..<range.lowerBound]))
            if let edited = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !edited.isEmpty,
               WhisperNowContentGuard.trip(source: original, output: edited) == nil,
               !WhisperNowContentGuard.shortened(source: original, output: edited),
               Qwen3Polisher.reviewIdentifiersPreserved(edited, original: original) {
                if let review, original != edited {
                    // Never queue multiple reviews behind the single-request D1 worker.
                    if let previous = pending {
                        if Task.isCancelled { previous.task.cancel() }
                        let vetoed = await previous.task.value
                        if !vetoed && !Task.isCancelled { parts[previous.index] = previous.edited }
                        pending = nil
                    }
                    let slot = parts.count
                    parts.append(original)
                    let left = ContinuousClock.now.duration(to: deadline)
                    let seconds = min(0.2, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
                    let task = Task {
                        // The optional reviewer is fail-open, like the existing D1 gate.
                        // Bound even a misbehaving reviewer by the original section deadline.
                        await DictationDeadline.run(seconds: seconds) { await review(original, edited) } ?? false
                    }
                    pending = (slot, edited, task)
                } else {
                    parts.append(edited)
                }
            } else {
                parts.append(original)
            }
            cursor = range.upperBound
        }
        if let previous = pending {
            if Task.isCancelled { previous.task.cancel() }
            let vetoed = await previous.task.value
            if !vetoed && !Task.isCancelled { parts[previous.index] = previous.edited }
        }
        parts.append(String(source[cursor...]))
        return (Task.isCancelled ? source : parts.joined(), timedOut)
    }

    private static let filename = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\d_])[\w-]+(?:\.[\w-]+)*\.(?:"# + Qwen3Polisher.explicitFileExtensions + #")(?![\p{L}\d_-])"#,
        options: .caseInsensitive)

    /// Restore case only when the same filename has a single spelling in the source.
    static func preservingFilenameCase(_ result: String, original: String) -> String {
        guard original != result, original.contains("."), let filename else { return result }
        var spellings: [String: Set<String>] = [:]
        let source = original as NSString
        for token in filename.matches(in: original, range: NSRange(location: 0, length: source.length)) {
            let value = source.substring(with: token.range)
            spellings[value.lowercased(), default: []].insert(value)
        }
        guard !spellings.isEmpty else { return result }
        let output = NSMutableString(string: result)
        for token in filename.matches(in: result, range: NSRange(location: 0, length: output.length)).reversed() {
            let value = output.substring(with: token.range)
            if let known = spellings[value.lowercased()], known.count == 1,
               let exact = known.first, exact != value {
                output.replaceCharacters(in: token.range, with: exact)
            }
        }
        return output as String
    }
    static func delivery(autoCopy: Bool, autoPaste: Bool, skipPolish: Bool,
                         formatted: String, final: String, fieldContextProvided: Bool,
                         command: TrailingPressEnter.Parsed) -> DeliveryIntent {
        // The paster checks the captured app when known. Ordinary dictation can
        // still paste in editors that do not expose their focused field to AX.
        DeliveryIntent(shouldPaste: autoPaste && !final.isEmpty, restoreClipboard: !autoCopy,
                       preFormatted: !skipPolish && final != formatted && fieldContextProvided,
                       requireCapturedTarget: false, shouldSubmit: autoPaste && command.shouldSubmit)
    }
    nonisolated static func predominantlyNonLatin(_ text: String) -> Bool {
        var latin = 0, nonLatin = 0
        for scalar in text.unicodeScalars {
            guard [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter].contains(scalar.properties.generalCategory) else { continue }
            let v = scalar.value
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || (0xC0...0xFF).contains(v) || (0x100...0x24F).contains(v) { latin += 1 }
            else { nonLatin += 1 }
        }
        let total = latin + nonLatin
        return total >= 4 && Double(nonLatin) / Double(total) > 0.30
    }
}
