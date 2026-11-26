import Foundation
import XCTest
@testable import Voice

final class DictationLayoutBoundaryTests: XCTestCase {
    func testSectionRangesLeaveOriginalSeparatorsAndIndentationOutsideTheModel() {
        let source = "Read the report. Mark page 15. Save it.\r\n\r\n  Next section.  \u{2028}"
        let ranges = DictationLayout.cleanupSections(in: source, limit: 30)
        XCTAssertEqual(ranges.map { String(source[$0]) }, ["Read the report. Mark page 15.", "Save it.", "Next section."])
        XCTAssertEqual(String(source[ranges[1].upperBound..<ranges[2].lowerBound]), "\r\n\r\n  ")
        XCTAssertEqual(String(source[ranges[2].upperBound...]), "  \u{2028}")
    }

    func testSectionsDoNotEditFencedOrIndentedCodeAsProse() {
        let source = "Before.\n````swift\nlet um = 1  \n```\nKeep this code.\n````\n"
            + "    return value\n\tprint(value)\nAfter."
        let ranges = DictationLayout.cleanupSections(in: source, limit: 900)
        XCTAssertEqual(ranges.map { String(source[$0]) }, ["Before.", "After."])
        let unfinished = "Before.\n~~~text\nKeep this code.\n"
        XCTAssertEqual(DictationLayout.cleanupSections(in: unfinished, limit: 900).map { String(unfinished[$0]) }, ["Before."])
    }

    func testLongUnbrokenTokensStayOutsideSectionCleanup() {
        let token = "https://example.com/" + String(repeating: "x", count: 70)
        let source = token + "\n   See it."
        XCTAssertEqual(DictationLayout.cleanupSections(in: source, limit: 30).map { String(source[$0]) }, ["See it."])
        XCTAssertTrue(DictationLayout.cleanupSections(in: source, limit: 0).isEmpty)
    }

    func testLineBreakCommandsAreContentButEmptyPaddingIsNot() {
        for text in ["\n", "\n\n", "\r\n", "\u{2028}", "\n    "] {
            XCTAssertTrue(DictationLayout.isBreakOnly(text))
            XCTAssertEqual(DictationLayout.restoringBoundaryBreaks(in: "", from: text), text)
        }
        for text in ["", " ", "\t", "Send the file.\n"] {
            XCTAssertFalse(DictationLayout.isBreakOnly(text))
        }
    }

    func testModelsCannotRemoveBoundaryCommands() {
        XCTAssertEqual(DictationLayout.restoringBoundaryBreaks(in: "Next line.", from: "\nnext line"), "\nNext line.")
        XCTAssertEqual(DictationLayout.restoringBoundaryBreaks(in: "Next line.", from: "next line\n\n"), "Next line.\n\n")
        XCTAssertEqual(DictationLayout.restoringBoundaryBreaks(in: "  Edited.\n", from: "\r\n  original\r\n    "),
                       "\r\n  Edited.\r\n    ")
        XCTAssertEqual(DictationLayout.restoringBoundaryBreaks(in: "Edited.", from: "\u{2028}original\u{2029}"),
                       "\u{2028}Edited.\u{2029}")
    }

    func testWholeDocumentCleanupCannotCollapseOrMoveBlankLines() {
        let source = "Hi Noor,\r\nSend the file.\r\n\r\nThanks."
        XCTAssertEqual(DictationLayout.preservingLineBreaks(in: "Hi Noor, send the file. Thanks.", from: source), source)
        XCTAssertEqual(DictationLayout.preservingLineBreaks(in: "Hi Noor,\n\nSend the file.\nThanks.", from: source), source)
    }

    func testWholeDocumentWordEditsKeepExactSourceWhitespace() {
        let source = "\nThey is ready.  \r\n\r\n  Keep the backup.\u{2028}"
        let edited = "They are ready.\n\nKeep the backup."
        XCTAssertEqual(DictationLayout.preservingLineBreaks(in: edited, from: source),
                       "\nThey are ready.  \r\n\r\n  Keep the backup.\u{2028}")
        XCTAssertEqual(DictationLayout.preservingLineBreaks(in: "New.\n\nParagraphs.", from: "Unformatted prose."),
                       "New.\n\nParagraphs.")
    }

    func testInternalParagraphsDoNotInventBoundaryWhitespace() {
        let edited = "They are ready.\n\nKeep page 15."
        XCTAssertEqual(DictationLayout.restoringBoundaryBreaks(in: edited, from: "They is ready.\n\nKeep page 15."), edited)
        XCTAssertEqual(DictationLayout.restoringBoundaryBreaks(in: "New paragraphs.\n\nStill here.", from: "One paragraph."),
                       "New paragraphs.\n\nStill here.")
    }

    func testSectionRepliesCannotAddBreaksInsideAnItem() {
        XCTAssertEqual(DictationLayout.singleLineReply(" \nThey are ready.\r\n"), "They are ready.")
        XCTAssertEqual(DictationLayout.singleLineReply("1. Keep the backup."), "1. Keep the backup.")
        for text in ["", " \n ", "1. Keep\nthe backup.", "- Keep\r\nthe backup.", "## Keep\u{2028}the backup.",
                     "```\nkeep()\n```", "let count = 1\nreturn count", "Use `keep`\nnow."] {
            XCTAssertNil(DictationLayout.singleLineReply(text))
        }
    }

    func testPlainModelParagraphsAreRejoinedInsideTheirOriginalSection() {
        for separator in ["\n", "\n\n", "\r\n", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(DictationLayout.singleLineReply("They are ready." + separator + "  Send the report."),
                           "They are ready. Send the report.")
        }
    }

    func testPasteLastRemembersAStandaloneLayoutCommand() {
        var store = LastTranscriptStore()
        store.remember("Older dictation.")
        store.remember("\n\n")
        XCTAssertEqual(store.text, "\n\n")
        XCTAssertTrue(store.shouldHandlePasteLast(isRecording: false))
        XCTAssertFalse(store.shouldHandlePasteLast(isRecording: true))
        store.remember("")
        store.remember(" \t ")
        XCTAssertEqual(store.text, "\n\n")
    }
}
