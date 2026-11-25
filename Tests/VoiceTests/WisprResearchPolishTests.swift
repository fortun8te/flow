import Testing
import Foundation
@testable import Voice

// Tests for the Wispr research.
// Each failure mode becomes a test; the behaviours we must match are tested on the production path.

// MARK: - Negation hard guard (failure mode 2: dropped "not", "never", "don't", "no")

@Suite struct NegationHardGuardTests {

    private func relaxed(_ polish: String, _ original: String, level: String = "medium") -> String? {
        Sanitizer.run(polish: polish, original: original, mode: .relaxed, cleanupLevel: level)
    }

    @Test func neverDroppedWithoutACorrectionIsRejectedAtEveryLevel() {
        for level in ["light", "medium", "high"] {
            #expect(relaxed("Merge a change like this without a review.", "never merge a change like this without a review", level: level) == nil, "level \(level)")
        }
    }

    @Test func fillerMeanCannotUnlockADroppedNegation() {
        // "I mean" is filler here, not a correction, so the "don't" must survive.
        #expect(relaxed("Worry about it.", "I mean, don't worry about it") == nil)
    }

    @Test func negationAfterACorrectionCueIsStillProtected() {
        // Only the words before "no wait" were retracted. "don't" is the replacement and must stay.
        #expect(relaxed("Let's meet at the office.", "let's meet, no wait, don't come to the office") == nil)
        #expect(relaxed("Let's meet, don't come to the office.", "let's meet, no wait, don't come to the office") != nil)
    }

    @Test func negationRetractedBeforeACorrectionMayGo() {
        #expect(relaxed("It's the morning.", "it's not the evening, no wait, the morning") != nil)
    }

    @Test func doNotAndDontCountAsTheSameNegation() {
        #expect(relaxed("I do not know.", "I don't know.") != nil)
    }

    @Test func dutchNegationSurvives() {
        #expect(relaxed("Ik wil dit.", "ik wil dit niet") == nil)
        #expect(relaxed("Ik wil dit niet.", "ik wil dit niet") != nil)
    }

    @Test func fallbackKeepsTheNegation() {
        let result = PolishPostprocessor.validateAndProcess(polish: "Merge a change like this without a review.", originalForFallback: "never merge a change like this without a review", mode: .relaxed, cleanupLevel: "medium")
        #expect(result.cleaned.lowercased().contains("never"))
    }
}

// MARK: - Backtrack: only clear corrections

@Suite struct BacktrackOnlyOnClearCorrectionsTests {

    @Test func actuallyIsKeptWhenItIsNotACorrection() {
        let out = RestartCorrectionPreprocessor.process("I actually enjoyed the movie last night").cleaned
        #expect(out.lowercased().contains("actually"))
        #expect(out.lowercased().contains("enjoyed"))
    }

    @Test func clearCorrectionKeepsOnlyTheReplacement() {
        let out = RestartCorrectionPreprocessor.process("let's meet at the office actually no, at the cafe near the station").cleaned.lowercased()
        #expect(out.contains("cafe"))
        #expect(!out.contains("office"))
    }

    @Test func scratchThatRemovesTheWholeAbandonedAttempt() {
        let out = RestartCorrectionPreprocessor.process("send it to mark scratch that send it to sarah").cleaned.lowercased()
        #expect(out.contains("sarah"))
        #expect(!out.contains("mark"))
    }

    @Test func ambiguousReplacementKeepsBothOptions() {
        let out = RestartCorrectionPreprocessor.process("we can do monday or actually tuesday maybe").cleaned.lowercased()
        #expect(out.contains("monday"))
        #expect(out.contains("tuesday"))
    }
}

// MARK: - Spoken commands are not content

@Suite struct SpokenCommandTests {

    @Test func periodBecomesAFullStop() {
        #expect(PolishPostprocessor.process("meet at noon period see you then").cleaned.contains("noon."))
    }

    @Test func discussedCommaStaysAWord() {
        // Failure of the research's behaviour 3: "remove the comma" must not become "remove the,".
        #expect(PolishPostprocessor.process("remove the comma after the word fine").cleaned.lowercased().contains("comma"))
    }

    @Test func newParagraphBecomesABreak() {
        #expect(PolishPostprocessor.process("thanks for the call new paragraph can you send the invoice").cleaned.contains("\n\n"))
    }
}

// MARK: - Lists come only from explicit sequence markers

@Suite struct ExplicitListMarkerTests {

    @Test func firstSecondThirdBecomeANumberedList() {
        let out = PolishPostprocessor.process("first buy the venue second send invites third order the cake").cleaned
        #expect(out.contains("1."))
        #expect(out.contains("2."))
        #expect(out.contains("3."))
        #expect(!out.lowercased().contains("first buy"))
    }

    @Test func numberWordsBecomeANumberedList() {
        let out = PolishPostprocessor.process("number one buy milk number two call mom number three pay rent").cleaned
        #expect(out.contains("1."))
        #expect(out.contains("2."))
        #expect(out.contains("3."))
    }
}

// MARK: - Numbers become digits, units stay as spoken

@Suite struct SpelledNumberTests {

    private func relaxed(_ polish: String, _ original: String, level: String = "medium") -> String? {
        Sanitizer.run(polish: polish, original: original, mode: .relaxed, cleanupLevel: level)
    }

    @Test func digitsAndSpelledNumbersAreTheSameQuantity() {
        #expect(MeaningIntegrity.preservesMeaning(original: "twenty five percent off", candidate: "25 percent off"))
        #expect(MeaningIntegrity.preservesMeaning(original: "one two five degrees", candidate: "125 degrees"))
    }

    @Test func spelledOutRunOfDigitsBecomesDigitsAndKeepsTheUnitWord() {
        #expect(relaxed("The oven is at 125 degrees.", "the oven is at one two five degrees") != nil)
    }

    @Test func compoundNumberBecomesDigitsAndKeepsThePercentWord() {
        // "dropped words" must not count "twenty" and "five" when they became "25".
        #expect(relaxed("It's about 25 percent off.", "it's about twenty five percent off") != nil)
    }

    @Test func spelledNumberWithAUnitKeepsTheUnitWord() {
        #expect(relaxed("About 20 kilos.", "about twenty kilos") != nil)
    }

    @Test func degreeSymbolIsAUnitChangeAndIsRejected() {
        #expect(relaxed("The oven is at 125°.", "the oven is at one two five degrees") == nil)
    }
}

// MARK: - Bulleted lists may drop the spoken list cue

@Suite struct ListCueTests {

    @Test func spokenListCueMayGoWhenTheItemsBecomeABulletedList() {
        let polish = "I need:\n- Tomatoes\n- Lettuce\n- Burger buns\n- Ketchup"
        let original = "all right so we're going to make a quick list um I need tomatoes lettuce burger buns ketchup and I think that's it"
        #expect(Sanitizer.run(polish: polish, original: original, mode: .relaxed, cleanupLevel: "medium") != nil)
    }
}

// MARK: - Hedges survive high cleanup (failure mode 1, "over-editing")

@Suite struct HedgeGuardTests {

    @Test func hedgesSurviveHighCleanup() {
        #expect(Sanitizer.run(polish: "We should wait a bit.", original: "I think maybe we probably should wait a bit", mode: .relaxed, cleanupLevel: "high") == nil)
    }
}

// MARK: - Dutch and English are never translated into each other

@Suite struct NoTranslationGuardTests {

    @Test func dutchSentenceTranslatedToEnglishIsRejected() {
        #expect(Sanitizer.run(polish: "The client wants the invoice tomorrow and we'll send it to Sanne then.", original: "de client wil de invoice morgen en we sturen het dan naar Sanne", mode: .relaxed, cleanupLevel: "medium") == nil)
        #expect(Sanitizer.run(polish: "I'm there at half past eight, that's fine.", original: "ik ben er om half negen dat is prima", mode: .relaxed, cleanupLevel: "high") == nil)
    }

    @Test func mixedSentenceKeepingItsDutchIsAccepted() {
        #expect(Sanitizer.run(polish: "De client wil de invoice morgen en we sturen het dan naar Sanne.", original: "de client wil de invoice morgen en we sturen het dan naar Sanne", mode: .relaxed, cleanupLevel: "medium") != nil)
    }
}

// MARK: - Tiny utterances must not gain invented text

@Suite struct TinyUtteranceGuardTests {

    @Test func inventedSentenceOnATinyClipIsRejected() {
        #expect(Sanitizer.run(polish: "Thanks for watching, see you next time.", original: "yes", mode: .relaxed, cleanupLevel: "medium") == nil)
    }
}

// MARK: - Review bugs found while reading the polish code

@Suite struct PolishReviewBugTests {

    private func relaxed(_ polish: String, _ original: String) -> String? {
        Sanitizer.run(polish: polish, original: original, mode: .relaxed, cleanupLevel: "medium")
    }

    @Test func aSentenceEndingInAWordLikeLogInIsNotDangling() {
        #expect(relaxed("Please log in. Then wait for the email.", "please log in then wait for the email") != nil)
    }

    @Test func aSentenceEndingInTheLetterAIsNotDangling() {
        #expect(relaxed("I take vitamin A. Then I sleep.", "i take vitamin a then i sleep") != nil)
    }

    @Test func dateWrittenMonthFirstMustNotBeReordered() {
        #expect(relaxed("The meeting is on the 12th of March.", "the meeting is on March 12th") == nil)
        #expect(relaxed("The meeting is on March 12th.", "the meeting is on March 12th") != nil)
    }

    @Test func contractionWordsInsideIdentifiersAreUntouched() {
        #expect(PolishNormalizer.restoreContractions("set dont_show to true") == "set dont_show to true")
    }

    @Test func whatsAndWhosQuestionsGetAQuestionMark() {
        #expect(PolishNormalizer.ensureTerminalPunctuation("What's the plan for tomorrow") == "What's the plan for tomorrow?")
        #expect(PolishNormalizer.ensureTerminalPunctuation("Who's coming tonight") == "Who's coming tonight?")
    }
}
