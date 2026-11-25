import XCTest
@testable import Voice

@MainActor
final class DraftDecisionGateTests: XCTestCase {
    func testOnlyWordChangesReachTheDecisionModel() {
        XCTAssertFalse(DraftDecisionGate.needsReview(original: "um dont send the file", edited: "Don't send the file."))
        XCTAssertFalse(DraftDecisionGate.needsReview(original: "Hello there.", edited: ""))
        XCTAssertTrue(DraftDecisionGate.needsReview(original: "Send only the first file.", edited: "Send all the files."))
    }

    func testOnlyAConfidentWellFormedMeaningVerdictVetoes() {
        XCTAssertTrue(DraftDecisionGate.vetoes(changedProbability: 0.50))
        XCTAssertFalse(DraftDecisionGate.vetoes(changedProbability: 0.49))
        XCTAssertFalse(DraftDecisionGate.vetoes(changedProbability: nil))
        XCTAssertFalse(DraftDecisionGate.vetoes(changedProbability: .nan))
        XCTAssertFalse(DraftDecisionGate.vetoes(changedProbability: 1.5))
    }
}
