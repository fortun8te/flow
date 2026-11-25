import Testing
import Foundation
@testable import Voice

@Suite struct PolishNormalizerTests {

    // MARK: - Dashes become clause punctuation

    @Test func dashBeforeLowercaseBecomesComma() {
        #expect(PolishNormalizer.normalizeDashes("I went \u{2014} then I left.") == "I went, then I left.")
    }

    @Test func dashBeforeCapitalBecomesFullStopWhenBothSidesAreSentences() {
        #expect(PolishNormalizer.normalizeDashes("It was late \u{2014} Jordan left early today.") == "It was late. Jordan left early today.")
    }

    @Test func dashBeforeShortCapitalisedPhraseBecomesComma() {
        // "Jordan left" is two words, not a clear sentence, so the dash becomes a comma.
        #expect(PolishNormalizer.normalizeDashes("It was late\u{2014}Jordan left.") == "It was late, Jordan left.")
    }

    @Test func asideWithCapitalisedNameBecomesCommas() {
        #expect(PolishNormalizer.normalizeDashes("We met Sarah \u{2014} Jordan's sister \u{2014} at noon.") == "We met Sarah, Jordan's sister, at noon.")
    }

    @Test func dashAfterSingleWordBecomesComma() {
        #expect(PolishNormalizer.normalizeDashes("Coffee \u{2014} Jordan's favourite.") == "Coffee, Jordan's favourite.")
    }

    // MARK: - Ranges read "to", never a full stop

    @Test func dayRangeReadsToNotFullStop() {
        #expect(PolishNormalizer.normalizeDashes("Monday \u{2014} Thursday, that's the window for the shoot.") == "Monday to Thursday, that's the window for the shoot.")
    }

    @Test func lowercaseDayRangeReadsTo() {
        #expect(PolishNormalizer.normalizeDashes("monday \u{2014} thursday") == "monday to thursday")
    }

    @Test func dayRangeWithoutSpacesReadsTo() {
        #expect(PolishNormalizer.normalizeDashes("Monday\u{2014}Friday works") == "Monday to Friday works")
    }

    @Test func monthRangeReadsTo() {
        #expect(PolishNormalizer.normalizeDashes("from January \u{2014} March we rent it") == "from January to March we rent it")
    }

    @Test func quarterRangeReadsTo() {
        #expect(PolishNormalizer.normalizeDashes("Q1 \u{2014} Q3 was strong") == "Q1 to Q3 was strong")
    }

    @Test func clockTimeRangeReadsTo() {
        #expect(PolishNormalizer.normalizeDashes("open 9am \u{2014} 5pm daily") == "open 9am to 5pm daily")
        #expect(PolishNormalizer.normalizeDashes("open 9 am \u{2014} 5 pm daily") == "open 9 am to 5 pm daily")
    }

    @Test func numericRangeWithSpacesKeepsHyphen() {
        #expect(PolishNormalizer.normalizeDashes("Work 9 \u{2014} 5 today") == "Work 9-5 today")
    }

    @Test func dashAfterNumberWithAsideIsCommaNotRange() {
        // "9 pm" then a count is not a time range, so the dash stays an aside.
        #expect(PolishNormalizer.normalizeDashes("We left at 9 pm \u{2014} 5 people came") == "We left at 9 pm, 5 people came")
    }

    @Test func rangeWordsWithAsideAreNotRanges() {
        // "Monday" alone is not a range: the right side is an aside.
        #expect(PolishNormalizer.normalizeDashes("Call me Monday \u{2014} unless it rains") == "Call me Monday, unless it rains")
    }

    @Test func dashBeforeLowercaseNeverBecomesFullStop() {
        #expect(PolishNormalizer.normalizeDashes("We tried everything last week \u{2014} then we stopped") == "We tried everything last week, then we stopped")
    }

    @Test func dashAfterTrailingFunctionWordIsComma() {
        // "the budget is" cannot end a sentence, so the next capital does not start a new one.
        #expect(PolishNormalizer.normalizeDashes("The budget for the trip is \u{2014} Jordan paid") == "The budget for the trip is, Jordan paid")
    }

    @Test func dashAfterPunctuationIsDropped() {
        #expect(PolishNormalizer.normalizeDashes("Okay. \u{2014} then we go.") == "Okay. then we go.")
    }

    @Test func dashAtEdgesIsDropped() {
        #expect(PolishNormalizer.normalizeDashes("\u{2014} we start here.") == "we start here.")
        #expect(PolishNormalizer.normalizeDashes("We end here \u{2014}") == "We end here")
    }

    @Test func numericRangesBecomeHyphen() {
        #expect(PolishNormalizer.normalizeDashes("Take 5\u{2013}10 kg") == "Take 5-10 kg")
        #expect(PolishNormalizer.normalizeDashes("Between 2024 \u{2014} 2025") == "Between 2024-2025")
    }

    @Test func textWithoutDashesIsUnchanged() {
        let text = "Plain sentence, with a number 42 and a name Jordan."
        #expect(PolishNormalizer.normalizeDashes(text) == text)
    }

    @Test func dashNormalizationIsIdempotent() {
        let once = PolishNormalizer.normalizeDashes("We met \u{2014} then Sarah \u{2014} and it was 5\u{2013}10 minutes \u{2014} fine.")
        #expect(PolishNormalizer.normalizeDashes(once) == once)
        #expect(!once.contains("\u{2014}"))
        #expect(!once.contains("\u{2013}"))
    }

    @Test func noEmDashSurvivesNormalization() {
        let out = PolishNormalizer.normalize(
            polish: "Call Jordan \u{2014} tomorrow \u{2013} before noon \u{2015} please.",
            original: "call jordan tomorrow before noon please")
        #expect(!out.contains("\u{2014}") && !out.contains("\u{2013}") && !out.contains("\u{2015}"))
        #expect(out.contains("Jordan"))
        #expect(out.contains("noon"))
    }

    // MARK: - Emojis

    @Test func newEmojiIsRemoved() {
        #expect(PolishNormalizer.removeNewEmojis("Great \u{1F680} news", original: "great news") == "Great news")
    }

    @Test func emojiTheSpeakerSaidIsKept() {
        let text = "Launch \u{1F680} today."
        #expect(PolishNormalizer.removeNewEmojis(text, original: "launch \u{1F680} today") == text)
    }

    @Test func textWithoutEmojiIsUnchanged() {
        let text = "No pictures here."
        #expect(PolishNormalizer.removeNewEmojis(text, original: "no pictures here") == text)
    }

    // MARK: - Integration with the relaxed sanitizer

    @Test func dashedPolishIsAcceptedAfterRepair() {
        let original = "i went to the office then i left early because sarah asked me to"
        let dashed = "I went to the office \u{2014} then I left early because Sarah asked me to."
        // Before the repair the sanitizer rejects the whole cleanup (the raw text used to ship).
        #expect(Sanitizer.run(polish: dashed, original: original, mode: .relaxed) == nil)
        let repaired = PolishNormalizer.normalize(polish: dashed, original: original)
        let accepted = Sanitizer.run(polish: repaired, original: original, mode: .relaxed)
        #expect(accepted != nil)
        #expect(accepted?.contains("office, then I left") == true)
    }

    @Test func repairKeepsNamesAndNumbers() {
        let original = "we paid 4500 euros to Jordan \u{2014} then we left"
        let repaired = PolishNormalizer.normalize(
            polish: "We paid 4500 euros to Jordan, then we left.",
            original: original)
        #expect(Sanitizer.run(polish: repaired, original: original, mode: .relaxed) != nil)
        #expect(repaired.contains("4500"))
        #expect(repaired.contains("Jordan"))
    }

    @Test func validateAndProcessNoLongerFallsBackOnDash() {
        let raw = "um i went then i left early"
        let result = PolishPostprocessor.validateAndProcess(
            polish: "I went \u{2014} then I left early.",
            originalForFallback: raw,
            mode: .relaxed)
        #expect(!result.cleaned.contains("\u{2014}"))
        #expect(result.cleaned != raw)
        #expect(result.cleaned.contains("went"))
    }

    @Test func rawSanitizerStillRejectsDashWhenNotRepaired() {
        // The absolute rule itself is unchanged: a dash that reaches the sanitizer is still refused.
        #expect(Sanitizer.run(polish: "I went \u{2014} then I left.", original: "i went then i left", mode: .relaxed) == nil)
    }
}
