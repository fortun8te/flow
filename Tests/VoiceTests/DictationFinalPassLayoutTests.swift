import XCTest
@testable import Voice

/// Synthetic layout regressions: exercising the actual final pass requires
/// no speech model, Accessibility access, or private dictations.
final class DictationFinalPassLayoutTests: XCTestCase {
    func testFillerCleanupKeepsMarkdownHardBreaksAndBlankLines() {
        let source = "Uh, send the notes.  \nThen call the clerk.\n \t\nKeep the receipt.  "
        XCTAssertEqual(DictationFinalPass.apply(source),
                       "Send the notes.  \nThen call the clerk.\n \t\nKeep the receipt.  ")
    }

    func testFillerCleanupKeepsListIndentation() {
        let source = "Uh, the tasks are:\n  - Check the gate.  \n    - Keep the spare key.\n\t- Call the clerk."
        XCTAssertEqual(DictationFinalPass.apply(source),
                       "The tasks are:\n  - Check the gate.  \n    - Keep the spare key.\n\t- Call the clerk.")
    }

    func testInteriorSpacingStillGetsTidied() {
        XCTAssertEqual(DictationFinalPass.apply("Uh, send  the notes , then call."),
                       "Send the notes, then call.")
    }

    func testDeliberateWaitRepetitionSurvives() {
        XCTAssertEqual(DictationFinalPass.apply("Wait wait!\nCheck the gate."), "Wait wait!\nCheck the gate.")
    }

    func testRepeatedWordsNeverJoinSeparateLines() {
        for separator in ["\n", "\n\n", "\r\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let source = "repeat" + separator + "repeat the line."
            XCTAssertEqual(DictationFinalPass.apply(source), source)
            let pronoun = "We" + separator + "we're ready."
            XCTAssertEqual(DictationFinalPass.apply(pronoun), pronoun)
        }
    }

    func testRepeatedPhrasesKeepEveryLineSeparator() {
        for separator in ["\n", "\n\n", "\r\n", "\r", "\u{2028}", "\u{2029}"] {
            let source = "Check the gate" + separator + "check the gate before leaving."
            XCTAssertEqual(DictationFinalPass.removeRepeatedPhrases(source), source)
            let stutter = "Check the gate check the gate before leaving." + separator + "Keep the key."
            XCTAssertEqual(DictationFinalPass.removeRepeatedPhrases(stutter),
                           "Check the gate before leaving." + separator + "Keep the key.")
        }
    }

    func testLineStartHesitationsKeepIndentationForEverySeparator() {
        for separator in ["\n", "\r\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(DictationFinalPass.apply("Keep the key." + separator + "  Uh, send the notes.  "),
                           "Keep the key." + separator + "  Send the notes.  ")
        }
    }

    func testFencedCodeSurvivesWhileSurroundingProseIsCleaned() {
        let code = "```python\n    uh = \"keep  spaces\"\n    render(\"<br>\")\n```"
        XCTAssertEqual(DictationFinalPass.apply("Uh, check this:\n" + code + "\n\nUm, then go."),
                       "Check this:\n" + code + "\n\nThen go.")
    }

    func testTildeFenceAndItsIndentationArePreserved() {
        let code = "  ~~~~text\r\n  um um\r\n  <ul><li>literal</li></ul>\r\n  ~~~~"
        XCTAssertEqual(DictationFinalPass.apply(code + "\r\nUh, done."), code + "\r\nDone.")
    }

    func testShorterFenceDoesNotCloseAnOuterFence() {
        let code = "````markdown\n```\nuh uh\n```\n````"
        XCTAssertEqual(DictationFinalPass.apply(code + "\nUh, done."), code + "\nDone.")
    }

    func testUnclosedFenceIsPreserved() {
        let code = "```text\nuh uh\nKeep  these spaces.  "
        XCTAssertEqual(DictationFinalPass.apply("Uh, example:\n" + code), "Example:\n" + code)
    }

    func testInlineCodeDoesNotBecomeHtmlOrLoseWhitespace() {
        XCTAssertEqual(DictationFinalPass.apply("Uh, run `echo  um <br>` now."),
                       "Run `echo  um <br>` now.")
        XCTAssertEqual(DictationFinalPass.apply("Uh, use ``literal `tick`  um`` here."),
                       "Use ``literal `tick`  um`` here.")
    }

    func testCodeDoesNotDisableProseStutterCleanup() {
        XCTAssertEqual(DictationFinalPass.apply("When should we paint when should we paint fences? See `a  b`."),
                       "When should we paint fences? See `a  b`.")
    }

    func testLiteralPrivateUseCharactersDoNotCollideWithCodeProtection() {
        let source = "Uh, keep \u{E000}0\u{E001} and `echo  hello` here.  \nThen stop."
        XCTAssertEqual(DictationFinalPass.apply(source),
                       "Keep \u{E000}0\u{E001} and `echo  hello` here.  \nThen stop.")
    }

    func testLayoutCleanupIsIdempotent() {
        let source = "Uh, send  the notes.  \n\n  - Keep the key.\n\n```text\num um\n```"
        let once = DictationFinalPass.apply(source)
        XCTAssertEqual(DictationFinalPass.apply(once), once)
    }
}
