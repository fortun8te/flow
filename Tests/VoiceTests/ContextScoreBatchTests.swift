import Foundation
import XCTest
@testable import Voice

final class ContextScoreBatchTests: XCTestCase {
    func testRepeatedContextsScoreOnceAndKeepCallerOrder() {
        var submitted: [String] = []
        let scores = ContextScoreBatch.score(["The violet kettle.", "A copper lantern.", "The violet kettle."]) {
            submitted = $0
            return [-4, -7]
        }
        XCTAssertEqual(submitted, ["The violet kettle.", "A copper lantern."])
        XCTAssertEqual(scores, [-4, -7, -4])
    }

    func testByteDistinctUnicodeContextsAreNotConflated() {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(composed, decomposed) // Swift equality alone is insufficient for BPE.
        var count = 0
        let scores = ContextScoreBatch.score([composed, decomposed, composed]) {
            count = $0.count
            return [-1, -2]
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(scores, [-1, -2, -1])
    }

    func testIncompleteBackendResultCannotShiftCandidateScores() {
        let scores = ContextScoreBatch.score(["violet", "copper", "violet"]) { _ in [-1] }
        XCTAssertEqual(scores.count, 3)
        XCTAssertTrue(scores.allSatisfy(\.isNaN))
    }

    func testEmptyBatchDoesNotInvokeModelAndFailedScoresStayFailed() {
        XCTAssertTrue(ContextScoreBatch.score([]) { _ in XCTFail("empty model call"); return [] }.isEmpty)
        let scores = ContextScoreBatch.score(["violet", "violet"]) { _ in [.nan] }
        XCTAssertEqual(scores.count, 2)
        XCTAssertTrue(scores.allSatisfy(\.isNaN))
    }
}
