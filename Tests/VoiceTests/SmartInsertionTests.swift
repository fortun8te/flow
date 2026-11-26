import Foundation
import XCTest
@testable import Voice

final class SmartInsertionTests: XCTestCase {
    private func insert(_ text: String, into field: String, at location: Int, replacing length: Int = 0,
                        preFormatted: Bool = true, code: Bool = false, messaging: Bool = false) -> String {
        let range = NSRange(location: location, length: length)
        let payload = SmartInsertion.resolve(text, field: field, selection: range,
            preFormatted: preFormatted, code: code, messaging: messaging)
        return (field as NSString).replacingCharacters(in: range, with: payload)
    }

    func testWordBoundariesAndSelectionReplacement() {
        XCTAssertEqual(insert("blue", into: "thekettle", at: 3), "thebluekettle")
        XCTAssertEqual(insert("blue", into: "the kettle", at: 4), "the blue kettle")
        XCTAssertEqual(insert("blue", into: "the kettle", at: 3, replacing: 1), "the blue kettle")
        XCTAssertEqual(insert("blue", into: "the old kettle", at: 4, replacing: 3), "the blue kettle")
        XCTAssertEqual(insert("blue", into: "the kettle", at: 10), "the kettle blue")
    }

    func testQuotesAndBracketsHaveNoInteriorPadding() {
        XCTAssertEqual(insert("blue kettle", into: "Use \"\" now", at: 5), "Use \"blue kettle\" now")
        XCTAssertEqual(insert("blue kettle", into: "Use '' now", at: 5), "Use 'blue kettle' now")
        XCTAssertEqual(insert("blue kettle", into: "Use () now", at: 5), "Use (blue kettle) now")
        XCTAssertEqual(insert("blue kettle", into: "Use “old” now", at: 5, replacing: 3), "Use “blue kettle” now")
        XCTAssertEqual(insert("next", into: "\"done\"", at: 6), "\"done\" next")
    }

    func testExistingPunctuationIsNotDoubled() {
        XCTAssertEqual(insert("blue.", into: "The , green kettle", at: 4), "The blue, green kettle")
        XCTAssertEqual(insert("blue,", into: "The , green kettle", at: 4), "The blue, green kettle")
        XCTAssertEqual(insert("Ready!", into: "!", at: 0), "Ready!")
        XCTAssertEqual(insert("Wait...", into: ".", at: 0), "Wait...")
        XCTAssertEqual(insert("Wait.", into: "...", at: 0), "Wait...")
        XCTAssertEqual(insert("Ready!!", into: "!", at: 0), "Ready!!")
        XCTAssertEqual(insert("U.S.", into: ".", at: 0), "U.S.")
    }

    func testAbbreviationsKeepTheirFinalPeriod() {
        XCTAssertEqual(insert("U.S.", into: "Visit ", at: 6, preFormatted: false), "Visit U.S.")
        XCTAssertEqual(insert("Dr.", into: "Ask ", at: 4, preFormatted: false), "Ask Dr.")
        XCTAssertEqual(insert("J.", into: "Ask ", at: 4, preFormatted: false), "Ask J.")
        XCTAssertEqual(insert("Done.", into: "", at: 0, preFormatted: false, messaging: true), "Done")
    }

    func testNamesAndAcronymsAreNotLowercasedByGuessing() {
        XCTAssertEqual(insert("Jordan Example.", into: "Ask ", at: 4, preFormatted: false), "Ask Jordan Example")
        XCTAssertEqual(insert("API details.", into: "Read ", at: 5, preFormatted: false), "Read API details")
        XCTAssertEqual(insert("I agree.", into: "Then ", at: 5, preFormatted: false), "Then I agree")
        XCTAssertEqual(insert("The blue kettle.", into: "Inspect ", at: 8, preFormatted: false), "Inspect the blue kettle")
    }

    func testLiteralFragmentsAndPreformattedCasingArePreserved() {
        XCTAssertEqual(insert("sample", into: "https://.example", at: 8), "https://sample.example")
        XCTAssertEqual(insert("sample", into: "https://example./path", at: 16), "https://example.sample/path")
        XCTAssertEqual(insert("mail", into: "sample@.example", at: 7), "sample@mail.example")
        XCTAssertEqual(insert("The blue kettle.", into: "Inspect ", at: 8), "Inspect The blue kettle.")
    }

    func testPartialContractionReplacementDoesNotAddSpaces() {
        XCTAssertEqual(insert("t", into: "can't", at: 4, replacing: 1), "can't")
        XCTAssertEqual(insert("n", into: "can't", at: 2, replacing: 1), "can't")
        XCTAssertEqual(insert("n", into: "can’t", at: 2, replacing: 1), "can’t")
        XCTAssertEqual(insert("e", into: "w're", at: 1), "we're")
    }

    func testUnicodeAndIntentionalLineBreaksArePreserved() {
        let field = "👩🏽‍💻 kettle"
        XCTAssertEqual(insert("blue", into: field, at: "👩🏽‍💻 ".utf16.count), "👩🏽‍💻 blue kettle")
        XCTAssertEqual(insert("\n\tblue kettle", into: "Shelf", at: 5), "Shelf\n\tblue kettle")
        XCTAssertEqual(insert("blue\n", into: "kettle", at: 0), "blue\nkettle")
    }

    func testPreformattedFirstLineIndentationAndPaddingSurvive() {
        for code in [false, true] {
            XCTAssertEqual(insert("    return value", into: "", at: 0, code: code), "    return value")
            XCTAssertEqual(insert("    return value  ", into: "if ready:\n", at: 10, code: code),
                           "if ready:\n    return value  ")
            XCTAssertEqual(insert("    ", into: "", at: 0, code: code), "    ")
        }
    }

    func testPreformattedMultilineCodeAndMarkdownWhitespaceRoundTrip() {
        let code = "    first()\n        second()  \n    return value  "
        XCTAssertEqual(insert(code, into: "", at: 0, code: true), code)
        let markdown = "line one  \nline two  "
        XCTAssertEqual(insert(markdown, into: "", at: 0), markdown)
        let nextLineIndent = "    first()\n    "
        XCTAssertEqual(insert(nextLineIndent, into: "", at: 0, code: true), nextLineIndent)
    }

    func testPlainDictationStillTrimsHorizontalModelPadding() {
        XCTAssertEqual(insert(" blue ", into: "the ", at: 4, preFormatted: false), "the blue")
        XCTAssertEqual(insert(" detail ", into: "Use () now", at: 5, preFormatted: false), "Use (detail) now")
        XCTAssertEqual(insert(" New text ", into: "", at: 0, preFormatted: false), "New text")
    }

    func testInvalidRangesKeepPayloadAndDoNotPretendFieldIsEmpty() {
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: 1, length: Int.max),
                      NSRange(location: 1, length: 0)] {
            let field = range.location == 1 && range.length == 0 ? "😀" : ""
            XCTAssertEqual(SmartInsertion.resolve(" New ", field: field, selection: range,
                preFormatted: true, code: false, messaging: false), " New ")
        }
    }

    func testBoundedContextRangesNeverOverflowOrReadHugeSelections() {
        XCTAssertEqual(SmartInsertion.contextRange(selection: NSRange(location: 2, length: 0), fieldLength: 10),
                       NSRange(location: 0, length: 10))
        XCTAssertEqual(SmartInsertion.contextRange(selection: NSRange(location: 400, length: 3), fieldLength: 1_000),
                       NSRange(location: 272, length: 259))
        XCTAssertNil(SmartInsertion.contextRange(selection: NSRange(location: 2, length: Int.max), fieldLength: 10))
        XCTAssertNil(SmartInsertion.contextRange(selection: NSRange(location: NSNotFound, length: 0), fieldLength: 10))
        XCTAssertNil(SmartInsertion.contextRange(selection: NSRange(location: 0, length: 1_025), fieldLength: 2_000))
    }

    func testRememberedSpacingUnderstandsClosingQuotesAndBrackets() {
        for ending: Character in ["”", "\"", ")", "]", "…"] {
            XCTAssertEqual(SmartInsertion.boundarySpaced("Next", after: ending), " Next")
        }
    }

    func testListsAndHeadingsStartOnTheirOwnLineAtAnExistingCursor() {
        XCTAssertEqual(insert("- Keep the backup\n- Send the report", into: "Tasks:", at: 6),
                       "Tasks:\n- Keep the backup\n- Send the report")
        XCTAssertEqual(insert("1. Keep the backup\n2. Send the report", into: "Tasks: Next task.", at: 7),
                       "Tasks: \n1. Keep the backup\n2. Send the report\nNext task.")
        XCTAssertEqual(insert("## Next section", into: "Introduction.", at: 13), "Introduction.\n## Next section")
        XCTAssertEqual(insert("> Keep this quote", into: "Read:", at: 5), "Read:\n> Keep this quote")
    }

    func testStructuredPasteReusesExistingLineBoundaries() {
        XCTAssertEqual(insert("- Keep the backup", into: "Tasks:\n\nDone.", at: 7),
                       "Tasks:\n- Keep the backup\nDone.")
        XCTAssertEqual(insert("- Keep the backup", into: "Tasks:\n  ", at: 9), "Tasks:\n  - Keep the backup")
        XCTAssertEqual(insert("- Keep the backup\n", into: "Done.", at: 0), "- Keep the backup\nDone.")
        XCTAssertEqual(insert("- Keep the backup", into: "Old\r\nTasks:", at: 11), "Old\r\nTasks:\r\n- Keep the backup")
    }

    func testFencedCodeDoesNotGlueToSurroundingProse() {
        XCTAssertEqual(insert("```swift\nlet value = 1\n```", into: "Example:Next.", at: 8),
                       "Example:\n```swift\nlet value = 1\n```\nNext.")
    }

    func testInlineNumbersHyphensAndPlainParagraphsKeepNormalSpacing() {
        XCTAssertEqual(insert("1.25 kg", into: "Weight:", at: 7), "Weight: 1.25 kg")
        XCTAssertEqual(insert("-5", into: "value=", at: 6, code: true), "value=-5")
        XCTAssertEqual(insert("#tag", into: "Use ", at: 4), "Use #tag")
        XCTAssertEqual(insert("the report.\n\nAlso, keep the backup.", into: "Send ", at: 5),
                       "Send the report.\n\nAlso, keep the backup.")
    }

    func testRememberedBoundaryStartsAListAfterThePreviousDictation() {
        XCTAssertEqual(SmartInsertion.boundarySpaced("- First item\n- Second item", after: ":"),
                       "\n- First item\n- Second item")
        XCTAssertEqual(SmartInsertion.boundarySpaced("- First item", after: "\n"), "- First item")
    }

    func testBlockInferenceKeepsCodeOperatorsAndQuotedLiteralsInline() {
        XCTAssertEqual(insert("* 2", into: "return value ", at: 13, code: true), "return value * 2")
        XCTAssertEqual(insert("> 5", into: "if x ", at: 5, code: true), "if x > 5")
        XCTAssertEqual(insert("> literal", into: "Use \"\" here", at: 5), "Use \"> literal\" here")
        XCTAssertEqual(insert("- literal", into: "Use '' here", at: 5), "Use '- literal' here")
    }

    func testStructuredReplacementDoesNotOrphanExistingSentencePunctuation() {
        XCTAssertEqual(insert("- item", into: "Replace.", at: 0, replacing: 7), "- item.")
        XCTAssertEqual(insert("- item.", into: "Replace.", at: 0, replacing: 7), "- item.")
        XCTAssertEqual(insert("- item", into: "Replace!", at: 0, replacing: 7), "- item!")
    }

    func testIndentedListContinuationStaysSeparateFromFollowingText() {
        XCTAssertEqual(insert("- item\n  continuation", into: "Tail", at: 0), "- item\n  continuation\nTail")
        XCTAssertEqual(insert("- item\n\tcontinuation", into: "Tail", at: 0), "- item\n\tcontinuation\nTail")
    }
}
