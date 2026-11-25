import Testing
import Foundation
@testable import Voice

// Regression tests for cleanup guards.

// Finding 1: typed shorthand expansions are valid edits, not new meanings.
@Suite struct ReviewFinding1ShorthandTests {

    @Test func idkExpandsToIDontKnowOnTheSelectedTextPath() {
        #expect(Qwen3Polisher.selectedTextResultIsSafe("I don't know which gear to fit", original: "idk which gear to fit"))
    }

    @Test func bareDontBecomesDontWithTheApostropheOnTheSelectedTextPath() {
        #expect(Qwen3Polisher.selectedTextResultIsSafe("I don't want that", original: "i dont want that"))
    }
}

// Finding 5: qualifiers and negation attachment on the selected-text path.
@Suite struct ReviewFinding5QualifierTests {

    @Test func droppedTimingWordIsRejected() {
        #expect(!Qwen3Polisher.selectedTextResultIsSafe("Send it today.", original: "maybe send it tomorrow"))
    }

    @Test func droppedHedgeIsRejectedOutsideElevate() {
        #expect(!Qwen3Polisher.selectedTextResultIsSafe("Send it tomorrow.", original: "maybe send it tomorrow", preset: "fix"))
    }

    @Test func hedgeMayGoOnlyInElevate() {
        #expect(Qwen3Polisher.selectedTextResultIsSafe("Send it tomorrow.", original: "maybe send it tomorrow", preset: "elevate"))
    }

    @Test func negationMovedOntoAnotherVerbIsRejected() {
        #expect(!Qwen3Polisher.selectedTextResultIsSafe("Email bob, do not call alice.", original: "do not email bob, call alice"))
    }

    @Test func negationKeptOnItsOwnVerbIsAccepted() {
        #expect(Qwen3Polisher.selectedTextResultIsSafe("Do not email Bob, call Alice.", original: "do not email bob, call alice"))
    }

    @Test func synonymInsideANegationIsAccepted() {
        // "not sure" to "not certain" is a reword, not a moved negation.
        #expect(Qwen3Polisher.selectedTextResultIsSafe("I'm not certain about the date.", original: "im not sure about the date"))
    }
}

// Finding 9: a statement opened by "what" or "how" is not a question.
@Suite struct ReviewFinding9QuestionTests {

    @Test func exclamationOpenersStayStatements() {
        #expect(PolishNormalizer.ensureTerminalPunctuation("What a lovely day") == "What a lovely day.")
        #expect(PolishNormalizer.ensureTerminalPunctuation("How nice of you") == "How nice of you.")
    }

    @Test func realQuestionsKeepTheirMark() {
        #expect(PolishNormalizer.ensureTerminalPunctuation("What do you want") == "What do you want?")
        #expect(PolishNormalizer.ensureTerminalPunctuation("How are you") == "How are you?")
        #expect(PolishNormalizer.ensureTerminalPunctuation("What time is the meeting") == "What time is the meeting?")
    }
}

// Finding 10: a dash that is a minus sign stays a minus sign.
@Suite struct ReviewFinding10SignedNumberTests {

    @Test func dashBeforeADigitAfterASpaceIsAMinusSign() {
        #expect(PolishNormalizer.normalizeDashes("balance —5") == "balance -5")
    }

    @Test func dashAtTheStartBeforeADigitIsAMinusSign() {
        #expect(PolishNormalizer.normalizeDashes("—5 degrees") == "-5 degrees")
    }

    @Test func aRangeBetweenDigitsIsStillAHyphen() {
        #expect(PolishNormalizer.normalizeDashes("5—10 leads") == "5-10 leads")
    }

    @Test func aNegativeQuantityIsNotTheSameAsAPositiveOne() {
        #expect(!MeaningIntegrity.preservesQuantities(original: "balance -5", candidate: "balance 5"))
        #expect(MeaningIntegrity.preservesQuantities(original: "5-10 leads", candidate: "5-10 leads"))
    }
}

// Finding 7: "none" and "polish disabled" must not delete the speaker's words.
@Suite struct ReviewFinding7RawModeTests {

    @Test func minimalPostprocessorKeepsFillerWords() {
        let out = Qwen3Polisher.applyMinimalPostprocessor("um send it tomorrow", userVocabulary: nil)
        #expect(out.lowercased().hasPrefix("um"))
    }
}

// Finding 8: a cloud stream is only an answer when it completed.
@Suite struct ReviewFinding8StreamCompletionTests {

    @Test func completedStreamIsAccepted() {
        #expect(CloudStreamCompletion.failure(finishReason: "stop", sawDone: true) == nil)
        #expect(CloudStreamCompletion.failure(finishReason: "stop", sawDone: false) == nil)
    }

    @Test func truncatedStreamIsRefused() {
        #expect(CloudStreamCompletion.failure(finishReason: "length", sawDone: true) == "truncated-length")
    }

    @Test func contentFilteredStreamIsRefused() {
        #expect(CloudStreamCompletion.failure(finishReason: "content_filter", sawDone: true) == "content-filter")
    }

    @Test func streamThatEndsWithoutAFinishIsRefused() {
        #expect(CloudStreamCompletion.failure(finishReason: nil, sawDone: false) == "incomplete-stream")
    }

    @Test func doneWithoutAFinishReasonIsAccepted() {
        #expect(CloudStreamCompletion.failure(finishReason: nil, sawDone: true) == nil)
    }
}

// Finding 3: a local S1 result that did not settle must not end routing.
@Suite struct ReviewFinding3S1SettleTests {

    @Test func acceptedAndUnchangedSettle() {
        #expect(Qwen3Polisher.s1Settles(.accepted("Send it."), assessment: .accepted("Send it.")))
        #expect(Qwen3Polisher.s1Settles(.unchanged, assessment: .unchanged))
    }

    @Test func unavailableOrRefusedDoesNotSettle() {
        #expect(!Qwen3Polisher.s1Settles(.unavailable(.missingOrInvalidCache), assessment: .unavailable(.missingOrInvalidCache)))
        #expect(!Qwen3Polisher.s1Settles(.accepted("x"), assessment: .rejected(.meaningChanged)))
    }
}

// A contrastive "not" after a correction is not a negation the speaker needs kept (restart-02).
@Suite struct ContrastiveNegationTests {

    @Test func contrastiveNotAfterACorrectionMayGo() {
        #expect(MeaningIntegrity.keepsNegations(original: "book the flight for the 14th no sorry the 15th and make it the morning one not the evening",
                                                candidate: "Book the flight for the 15th, the morning one."))
    }

    @Test func verbalNegationAfterACorrectionStillMustSurvive() {
        #expect(!MeaningIntegrity.keepsNegations(original: "let's meet, no wait, I don't want the office",
                                                 candidate: "Let's meet, I want the office."))
    }
}
