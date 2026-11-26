import Foundation
import XCTest
@testable import Voice

final class PolishPostprocessorLineBreakTests: XCTestCase {
    func testInlineSalutationReplacesOnlyItsHorizontalGap() {
        XCTAssertEqual(PolishLayoutPreservation.normalizeEmailSalutation("Hi Noor,   Send the file."),
                       "Hi Noor,\n\nSend the file.")
        XCTAssertEqual(PolishLayoutPreservation.normalizeEmailSalutation("Good morning Élodie,\tSend the file."),
                       "Good morning Élodie,\n\nSend the file.")
    }

    func testSalutationPreservesExistingLineAndParagraphBreaks() {
        for separator in ["\n", "\n\n", "\r\n", "\r\n\r\n", " \t\n", "\u{2028}", "\u{2029}"] {
            let input = "Hi Noor," + separator + "Send the file."
            XCTAssertEqual(PolishLayoutPreservation.normalizeEmailSalutation(input), input)
        }
    }

    func testSalutationDoesNotCrossLinesInsideTheGreeting() {
        for input in ["Hi\nNoor, Send the file.", "Hi Noor and\nAlex, Send the file.",
                      "Hi Noor,  \r\nSend the file.", "Hi Noor, "] {
            XCTAssertEqual(PolishLayoutPreservation.normalizeEmailSalutation(input), input)
        }
    }

    func testSalutationUsesUTF16RangesForUnicodeNames() {
        for name in ["Élodie", "A\u{0301}lex", "\u{10400}lex", "Noor and André"] {
            let input = "Hi \(name),  The 📁 folder is ready."
            let expected = "Hi \(name),\n\nThe 📁 folder is ready."
            XCTAssertEqual(PolishLayoutPreservation.normalizeEmailSalutation(input), expected)
            XCTAssertEqual(PolishLayoutPreservation.normalizeEmailSalutation(expected), expected)
        }
    }

    func testLongProseReplacesTheWholeSelectedWhitespaceGap() {
        let lines = ["First", "Later", "Third", "Final"].map {
            $0 + " " + String(repeating: "amber ", count: 25) + "ends."
        }
        let gap = " \t  "
        let input = lines.joined(separator: gap)
        let expected = lines.prefix(2).joined(separator: gap) + "\n\n" + lines.suffix(2).joined(separator: gap)
        let actual = PolishLayoutPreservation.forceParagraphBreaks(input)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.split(whereSeparator: \.isWhitespace), input.split(whereSeparator: \.isWhitespace))
        XCTAssertEqual(PolishLayoutPreservation.forceParagraphBreaks(actual), actual)
    }

    func testLongProseNeverExpandsExistingBreaks() {
        let paragraph = String(repeating: "A small brass bell rang beside the door. ", count: 12)
        for separator in ["\n", "\n\n", "\n\n\n", "\r\n", "\r\n\r\n", "\u{2028}", "\u{2029}"] {
            let input = paragraph + separator + paragraph
            XCTAssertEqual(PolishLayoutPreservation.forceParagraphBreaks(input), input)
        }
    }

    func testLongStructuredLinesAndCodeAreNotReflowed() {
        let prose = String(repeating: "A small brass bell rang beside the door. ", count: 12)
        for input in ["- " + prose, "1. " + prose, "## " + prose, "> " + prose,
                      "    " + prose, "`" + prose + "`", "return { " + prose + " }"] {
            XCTAssertEqual(PolishLayoutPreservation.forceParagraphBreaks(input), input)
        }
    }

    func testShortMessagesKeepOneLine() {
        for input in ["Hi Noor, can you send the file?", "Make it smaller. Also, move it left.", "A. B. C."] {
            XCTAssertEqual(PolishLayoutPreservation.forceParagraphBreaks(input), input)
        }
    }

    func testOrdinaryOneLineSpacingStillNormalizes() {
        XCTAssertEqual(PolishLayoutPreservation.whitespacePass("  I  left\t\tthe room.  "), "I left the room.")
        XCTAssertEqual(PolishLayoutPreservation.punctuationSpacingPass("  I  left ,then came home.She was ready !  "),
                       "I left, then came home. She was ready!")
    }

    func testWhitespacePreservesExactSeparatorsAndBoundaryBlankLines() {
        for separator in ["\n", "\r\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let input = separator + "A  short line" + separator + separator + "Next  line" + separator
            let expected = separator + "A short line" + separator + separator + "Next line" + separator
            XCTAssertEqual(PolishLayoutPreservation.whitespacePass(input), expected)
            XCTAssertEqual(PolishLayoutPreservation.punctuationSpacingPass(input), expected)
        }
    }

    func testMarkdownHardBreaksAndNestedListIndentationSurvive() {
        let input = "- Parent  \n  - Child  \n    - Grandchild\n\nA  short line  \nNext line  "
        let expected = "- Parent  \n  - Child  \n    - Grandchild\n\nA short line  \nNext line  "
        XCTAssertEqual(PolishLayoutPreservation.whitespacePass(input), expected)
        XCTAssertEqual(PolishLayoutPreservation.punctuationSpacingPass(input), expected)
    }

    func testPunctuationNeverConsumesNewlineAfterOpeningParenthesis() {
        let input = "(\r\n    first(),\r\n  next item\r\n)\r\n"
        XCTAssertEqual(PolishLayoutPreservation.punctuationSpacingPass(input), input)
        XCTAssertEqual(PolishLayoutPreservation.punctuationSpacingPass("(  detail )"), "(detail)")
    }

    func testFencedAndIndentedCodeKeepTheirSpacing() {
        let code = "```swift\r\nlet values = [1,2]\r\n    call(  values )\r\n```\r\n\n    return  value  "
        XCTAssertEqual(PolishLayoutPreservation.whitespacePass(code), code)
        XCTAssertEqual(PolishLayoutPreservation.punctuationSpacingPass(code), code)
    }

    func testShorterFenceInsideALongerFenceDoesNotCloseIt() {
        let input = "````md\n```\nA  code ,line\n```\n````\nProse  line ,then next."
        let expected = "````md\n```\nA  code ,line\n```\n````\nProse line, then next."
        XCTAssertEqual(PolishLayoutPreservation.punctuationSpacingPass(input), expected)
    }

    func testInlineCodeAndUnclosedFencesStayUntouched() {
        for input in ["Run `call(  value )` now.", "~~~\nA  code ,line\n    nested  line  "] {
            XCTAssertEqual(PolishLayoutPreservation.whitespacePass(input), input)
            XCTAssertEqual(PolishLayoutPreservation.punctuationSpacingPass(input), input)
        }
    }

    func testWhitespaceOnlyLinesAndTrailingIndentationArePreserved() {
        for input in ["\n\n\n", "\r\n\r\n", "\n  \n\t\n", "    first()\n    "] {
            XCTAssertEqual(PolishLayoutPreservation.whitespacePass(input), input)
            XCTAssertEqual(PolishLayoutPreservation.punctuationSpacingPass(input), input)
        }
    }

    func testLayoutSpacingPassesAreIdempotent() {
        let input = "\nA  small line ,then another.  \r\n  - Child  item  \r\n```\ncall(  item )\n```\n\n"
        let spaced = PolishLayoutPreservation.punctuationSpacingPass(PolishLayoutPreservation.whitespacePass(input))
        XCTAssertEqual(PolishLayoutPreservation.whitespacePass(spaced), spaced)
        XCTAssertEqual(PolishLayoutPreservation.punctuationSpacingPass(spaced), spaced)
    }
}
