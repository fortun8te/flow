import XCTest
@testable import Voice

/// Regression tests for the 21 Nov 2026 pipeline review (the dictation text path).
final class PipebugsRegressionTests: XCTestCase {

    // Fallback (cleanup failed or was cut off): the transcript with hesitations stripped is pasted through
    // the final pass. Known bug, kept as an expected failure: WhisperNowContentGuard.stripHesitations joins
    // paragraphs and lines (\s{2,} and a trailing \s* in the hesitation pattern). The Python reference
    // scripts/pc/dev/guard.py has the same rule and the parity fixture pins it, so the fix needs the owner's
    // go-ahead to change both sides together. Fix: replace the \s with [ \t] in both patterns.
    func testFallbackKeepsParagraphBreaks() {
                let out = DictationFinalPass.apply(WhisperNowContentGuard.stripHesitations(
            "The lock turns slowly.\n\nUh the hinges need oil."))
        XCTAssertEqual(out, "The lock turns slowly.\n\nThe hinges need oil.")
    }

    func testFallbackKeepsLineBreakAfterTrailingHesitation() {
                let out = DictationFinalPass.apply(WhisperNowContentGuard.stripHesitations(
            "First line about the tab um\nSecond line stays on its own."))
        XCTAssertEqual(out, "First line about the tab\nSecond line stays on its own.")
    }

    // The final pass tidies whitespace across the whole text, including inside `code` spans, which the
    // pass promises never to touch. Fixed: spans are masked while the spacing rules run.
    func testFinalPassDoesNotRewriteSpacingInsideCodeSpans() {
        XCTAssertEqual(DictationFinalPass.apply("Run `ls  -la` now um please."),
                       "Run `ls  -la` now please.")
        XCTAssertEqual(DictationFinalPass.apply("Use `a  ,  b` here, um, and `c  .d` too."),
                       "Use `a  ,  b` here, and `c  .d` too.")
    }
}
