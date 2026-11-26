import Foundation
import XCTest
@testable import Voice

final class CorrectionEvidenceTests: XCTestCase {
    func testExpectedBaselineUsesExactSelectedOccurrence() {
        let field = "teh kettle; teh kettle"
        XCTAssertEqual(CorrectionEvidence.baseline(before: field, replacing: NSRange(location: 0, length: 10),
                                                   inserted: "the kettle"), "the kettle; teh kettle")
    }

    func testOnlyTheInsertedOccurrenceCanSupplyCorrections() {
        let field = "teh kettle; teh kettle"
        let range = NSRange(location: 0, length: 10)
        XCTAssertEqual(CorrectionEvidence.correctedInsertion(baseline: field, pastedRange: range,
                                                              current: "the kettle; teh kettle"), "the kettle")
        XCTAssertNil(CorrectionEvidence.correctedInsertion(baseline: field, pastedRange: range,
                                                           current: "teh kettle; the kettle"))
    }

    func testCorrectedTargetExcludesSurroundingFieldAndPreservesInsertionPadding() {
        let field = "Earlier text: teh blue kettle. Unrelated text."
        let range = (field as NSString).range(of: " teh blue kettle.")
        XCTAssertEqual(CorrectionEvidence.correctedInsertion(baseline: field, pastedRange: range,
                                                              current: "Earlier text: the azure kettle. Unrelated text."),
                       " the azure kettle.")
    }

    func testAppendingOrPrependingOutsideThePasteIsNotACorrection() {
        let field = "teh kettle"
        let range = NSRange(location: 0, length: field.utf16.count)
        XCTAssertNil(CorrectionEvidence.correctedInsertion(baseline: field, pastedRange: range, current: field + " is blue"))
        XCTAssertNil(CorrectionEvidence.correctedInsertion(baseline: field, pastedRange: range, current: "Look: " + field))
    }

    func testEditsToBothPasteAndSurroundingTextAreAmbiguous() {
        let field = "Before: teh kettle. After."
        let range = (field as NSString).range(of: "teh kettle.")
        XCTAssertNil(CorrectionEvidence.correctedInsertion(baseline: field, pastedRange: range,
                                                           current: "Before: the kettle. Elsewhere."))
    }

    func testUnchangedClearedOrWhitespaceOnlyFieldsNeverBecomeTargets() {
        let field = "teh kettle"
        let range = NSRange(location: 0, length: field.utf16.count)
        for current in [field, "", " ", "\n"] {
            XCTAssertNil(CorrectionEvidence.correctedInsertion(baseline: field, pastedRange: range, current: current))
        }
    }

    func testMalformedAndOverflowRangesReturnNil() {
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 2),
                      NSRange(location: 2, length: Int.max), NSRange(location: 50, length: 0)] {
            XCTAssertNil(CorrectionEvidence.correctedInsertion(baseline: "teh kettle", pastedRange: range, current: "the kettle"))
            XCTAssertNil(CorrectionEvidence.baseline(before: "teh kettle", replacing: range, inserted: "the"))
        }
    }

    func testEmojiAndCombiningCharactersKeepValidUTF16Boundaries() {
        let field = "🫖 Café: teh blue kettle. 🛶"
        let range = (field as NSString).range(of: "teh blue kettle.")
        XCTAssertEqual(CorrectionEvidence.correctedInsertion(baseline: field, pastedRange: range,
                                                              current: "🫖 Café: the blue kettle. 🛶"), "the blue kettle.")
        XCTAssertFalse(CorrectionEvidence.valid(NSRange(location: 1, length: 1), in: "🫖"))
        let decomposed = "Cafe\u{301}: teh kettle"
        let decomposedRange = (decomposed as NSString).range(of: "teh kettle")
        XCTAssertEqual(CorrectionEvidence.correctedInsertion(baseline: decomposed, pastedRange: decomposedRange,
                                                              current: "Cafe\u{301}: the kettle"), "the kettle")
    }

    func testInternalInsertionsAndDeletionsStayWithinThePaste() {
        let field = "Note: the kettle is blue. End."
        let range = (field as NSString).range(of: "the kettle is blue.")
        XCTAssertEqual(CorrectionEvidence.correctedInsertion(baseline: field, pastedRange: range,
                                                              current: "Note: the small kettle is blue. End."), "the small kettle is blue.")
        XCTAssertEqual(CorrectionEvidence.correctedInsertion(baseline: field, pastedRange: range,
                                                              current: "Note: the kettle is. End."), "the kettle is.")
    }
}
