import Testing
import Foundation
@testable import Voice

/// Guards that run on every polish result, cloud or local, after the model answers. Each one
/// has a case here. The end-to-end replay (recorded model answers, real pipeline) is in
/// Tests/PolishEval/test_replay_eval.py.
@Suite struct PolishGuardTests {

    // MARK: - Contractions

    @Test func bareContractionsGetTheirApostrophe() {
        #expect(PolishNormalizer.restoreContractions("sorry im late and i dont mind") == "sorry I'm late and i don't mind")
        #expect(PolishNormalizer.restoreContractions("Dont worry about it") == "Don't worry about it")
        #expect(PolishNormalizer.restoreContractions("im") == "I'm")
    }

    @Test func contractionsInsideWordsAndAmbiguousWordsAreUntouched() {
        #expect(PolishNormalizer.restoreContractions("give him the item") == "give him the item")
        #expect(PolishNormalizer.restoreContractions("its were ill") == "its were ill")
        #expect(PolishNormalizer.restoreContractions("we don't know") == "we don't know")
    }

    // MARK: - Terminal punctuation

    @Test func singleSentenceGetsAFullStop() {
        #expect(PolishNormalizer.ensureTerminalPunctuation("Send it to Sarah") == "Send it to Sarah.")
        #expect(PolishNormalizer.ensureTerminalPunctuation("Do the research") == "Do the research.")
        #expect(PolishNormalizer.ensureTerminalPunctuation("Have a good day") == "Have a good day.")
    }

    @Test func questionsGetAQuestionMark() {
        #expect(PolishNormalizer.ensureTerminalPunctuation("are you still coming to the gym tomorrow") == "are you still coming to the gym tomorrow?")
        #expect(PolishNormalizer.ensureTerminalPunctuation("Can you call me back") == "Can you call me back?")
        #expect(PolishNormalizer.ensureTerminalPunctuation("should we wait") == "should we wait?")
    }

    @Test func punctuationAlreadyThereAndMultiLineTextAreUntouched() {
        #expect(PolishNormalizer.ensureTerminalPunctuation("Done!") == "Done!")
        #expect(PolishNormalizer.ensureTerminalPunctuation("He said \"hi\"") == "He said \"hi\"")
        #expect(PolishNormalizer.ensureTerminalPunctuation("1. Book the venue\n2. Send invites") == "1. Book the venue\n2. Send invites")
    }

    @Test func finishLeavesNonEnglishAsSpoken() {
        #expect(PolishNormalizer.finish("ik denk dat we moeten", isNonEnglish: true) == "ik denk dat we moeten")
    }

    // MARK: - Emoji the model added

    @Test func emojiAddedAtTheEndLeavesNoStrayBlank() {
        #expect(PolishNormalizer.removeNewEmojis("Ready to go. \u{1F680}\u{1F389}", original: "ready to go") == "Ready to go.")
    }

    // MARK: - Substituted numbers and names

    @Test func swappedNumberIsFlagged() {
        #expect(PolishNormalizer.substitutedFact(polish: "We paid 4050 euros for the car", original: "we paid 4500 euros for the car") == "4500")
        #expect(PolishNormalizer.substitutedFact(polish: "Send it on the 15th", original: "send it on the 12th") == "12")
    }

    @Test func swappedNameIsFlagged() {
        // Lowercase in the speaker's raw text: no capital to compare against, so nothing to flag.
        #expect(PolishNormalizer.substitutedFact(polish: "I talked to Pria about it", original: "i talked to priya about it") == nil)
        #expect(PolishNormalizer.substitutedFact(polish: "I talked to Pria about it", original: "I talked to Priya about it") == "Priya")
    }

    @Test func deletionsFormattingAndSpelledNumbersAreNotSubstitutions() {
        // Fillers and restarts removed: lost tokens with nothing similar added.
        #expect(PolishNormalizer.substitutedFact(polish: "I think the budget is fine", original: "I I think the the budget is fine") == nil)
        // Spelled number turned into a digit: nothing lost.
        #expect(PolishNormalizer.substitutedFact(polish: "I need 5 boxes", original: "I need five boxes") == nil)
        // Thousands separators are formatting.
        #expect(PolishNormalizer.substitutedFact(polish: "We paid 4,500 euros", original: "we paid 4500 euros") == nil)
        // Numbered list markers are formatting, not facts.
        #expect(PolishNormalizer.substitutedFact(polish: "1. Book the venue\n2. Send invites\n3. Order the cake", original: "first book the venue second send invites third order the cake") == nil)
    }

    @Test func sentenceStartWordsAreNotNames() {
        #expect(PolishNormalizer.substitutedFact(polish: "Sarah is here. Tanya too.", original: "Sarah is here. Tanya too.") == nil)
        #expect(PolishNormalizer.substitutedFact(polish: "Okay, sure.", original: "okay sure") == nil)
    }

    // MARK: - Corrections

    @Test func correctionCueIsDetected() {
        #expect(Sanitizer.containsCorrectionCue("send it to Mark no wait send it to Sarah"))
        #expect(Sanitizer.containsCorrectionCue("the 14th no sorry the 15th"))
        #expect(!Sanitizer.containsCorrectionCue("send it to Sarah"))
    }

    @Test func correctionMayRetractAQuantityOrANegationButNotAddOne() {
        #expect(MeaningIntegrity.preservesMeaningAfterCorrection(original: "the 14th no sorry the 15th", candidate: "the 15th"))
        #expect(!MeaningIntegrity.preservesMeaningAfterCorrection(original: "the 14th no sorry the 15th", candidate: "the 16th"))
        #expect(MeaningIntegrity.preservesMeaningAfterCorrection(original: "the morning one not the evening", candidate: "the morning one"))
        #expect(!MeaningIntegrity.preservesMeaningAfterCorrection(original: "the morning one", candidate: "the morning one not the evening"))
    }

    @Test func withoutACorrectionANegationStillMustMatch() {
        #expect(!MeaningIntegrity.preservesMeaning(original: "don't think so", candidate: "think so"))
    }

    // MARK: - Model narrating the job

    @Test func modelNarrationIsFlagged() {
        #expect(Sanitizer.metaCommentary(polish: "The user wants me to clean this up. Thanks for the call.", original: "thanks for the call") != nil)
        #expect(Sanitizer.metaCommentary(polish: "Here's the cleaned-up version: Thanks.", original: "thanks") != nil)
    }

    @Test func narrationTheSpeakerSaidIsAllowed() {
        #expect(Sanitizer.metaCommentary(polish: "The user wants a refund.", original: "the user wants a refund") == nil)
    }
}

// MARK: - Speaker wording: units, date order, added and dropped words

@Suite struct SpeakerWordingGuardTests {

    private func relaxed(_ polish: String, _ original: String, level: String = "medium") -> String? {
        Sanitizer.run(polish: polish, original: original, mode: .relaxed, cleanupLevel: level)
    }

    @Test func kilosStayKilos() {
        #expect(relaxed("The range is 5 to 10 kg for the bag.", "the range is 5 to 10 kilos for the bag") == nil)
        #expect(relaxed("The range is 5 to 10 kilos for the bag.", "the range is 5 to 10 kilos for the bag") != nil)
    }

    @Test func percentStaysAsSpoken() {
        #expect(relaxed("It's about 25% off, so like 75 bucks.", "it's about twenty five percent off so like 75 bucks") == nil)
        #expect(relaxed("It's about twenty five percent off, so like 75 bucks.", "it's about twenty five percent off so like 75 bucks") != nil)
    }

    @Test func dayOrderOfADateStaysAsSpoken() {
        #expect(relaxed("The meeting is at 3:30 PM on March 12.", "the meeting is at 3:30 pm on the 12th of march") == nil)
        #expect(relaxed("The meeting is at 3:30 PM on the 12th of March.", "the meeting is at 3:30 pm on the 12th of march") != nil)
    }

    @Test func addedSentenceIsRejectedAndTheCleanedOriginalShips() {
        let cleaned = "so I think we should move the meeting to thursday"
        let polish = "So I think we should move the meeting to Thursday. Let me know if that works."
        #expect(relaxed(polish, "um so I think we should uh move the meeting to thursday") == nil)
        let result = PolishPostprocessor.validateAndProcess(polish: polish, originalForFallback: cleaned, mode: .relaxed, cleanupLevel: "medium")
        #expect(!result.cleaned.contains("Let me know"))
        #expect(result.cleaned.contains("move the meeting to"))
    }

    @Test func droppedWordIsRejectedAndTheCleanedOriginalShips() {
        // "fine" is gone and the sentence now ends on "is".
        #expect(relaxed("I think the budget is.", "I think the budget is fine.") == nil)
        let result = PolishPostprocessor.validateAndProcess(polish: "I think the budget is.", originalForFallback: "I think the budget is fine.", mode: .relaxed, cleanupLevel: "medium")
        #expect(result.cleaned.contains("fine"))
    }

    @Test func twoDroppedContentWordsAreRejected() {
        #expect(relaxed("We need the landing page before launch.", "we need the landing page and the email sequence before launch") == nil)
        #expect(relaxed("We need the landing page and the email sequence before launch.", "we need the landing page and the email sequence before launch") != nil)
    }

    @Test func cleanPolishIsAccepted() {
        #expect(relaxed("So I think we should move the meeting to Thursday.", "so i think we should move the meeting to thursday") == "So I think we should move the meeting to Thursday.")
    }

    @Test func fillersAndHedgesCanBeDropped() {
        // Dropping "probably", "maybe" and "think about" for "consider" is ordinary cleanup.
        #expect(relaxed("We should consider moving the event to a bigger venue.", "we should probably maybe think about moving the event to a bigger venue") != nil)
    }

    @Test func highRestructuringIsNotCheckedForAddedWords() {
        #expect(relaxed("Let me know if that works. So, the meeting moves to Thursday.", "so the meeting moves to thursday", level: "high") != nil)
    }

    @Test func productionPostprocessorKeepsUnitsAndDateOrder() {
        let options = PolishPostprocessor.Options(numberSpellout: false, unitAbbreviation: false, quarterAbbreviation: false)
        let out = PolishPostprocessor.process("the range is 5 kilos on the 12th of March, twenty five percent off", options: options).cleaned
        #expect(out.contains("5 kilos"))
        #expect(out.contains("12th of March"))
        #expect(out.contains("twenty five percent"))
    }

    @Test func spokenDatesKeepDayOrderAndSuffix() {
        #expect(PolishPostprocessor.spokenDatePass("on the 12th of March") == "on the 12th of March")
        #expect(PolishPostprocessor.spokenDatePass("December the 3rd") == "December the 3rd")
        #expect(PolishPostprocessor.spokenDatePass("March 15th 2026") == "March 15th, 2026")
    }

    @Test func dayAndMonthNamesAreCapitalised() {
        #expect(PolishPostprocessor.dayAndMonthCasingPass("see you on monday in march") == "see you on Monday in March")
        #expect(PolishPostprocessor.dayAndMonthCasingPass("we may go in june") == "we may go in June")
    }

    @Test func dutchDictationIsNotRewrittenByTheModel() {
        #expect(Qwen3Polisher.isNonEnglish("ik denk dat we de deck moeten sturen naar het team"))
    }
}
