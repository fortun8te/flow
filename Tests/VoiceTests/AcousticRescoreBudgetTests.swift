import Foundation
import XCTest
@testable import Voice

final class AcousticRescoreBudgetTests: XCTestCase {
    private func budget() -> AcousticRescoreBudget {
        AcousticRescoreBudget(baseSeconds: 1.8, secondsPerWord: 0.015, maximumSeconds: 6)
    }

    func testWindowsShareConsumedTimeInsteadOfEachGettingAFreshBudget() {
        let budget = budget()
        XCTAssertEqual(budget.remainingSeconds(addingWords: 100), 3.3, accuracy: 0.000_001)
        budget.consume(seconds: 2)
        XCTAssertEqual(budget.remainingSeconds(addingWords: 100), 2.8, accuracy: 0.000_001)
        budget.consume(seconds: 2.8)
        XCTAssertEqual(budget.remainingSeconds(addingWords: 0), 0, accuracy: 0.000_001)
        XCTAssertEqual(budget.remainingSeconds(addingWords: 100), 1.2, accuracy: 0.000_001)
    }

    func testLongRecordingsCannotMultiplyTheMaximumAllowance() {
        let budget = budget()
        XCTAssertEqual(budget.remainingSeconds(addingWords: Int.max), 6)
        budget.consume(seconds: 6)
        for _ in 0..<100 { XCTAssertEqual(budget.remainingSeconds(addingWords: Int.max), 0) }
    }

    func testSkippedWorkDoesNotConsumeAllowanceAndInvalidMeasurementsAbstain() {
        let budget = budget()
        budget.consume(seconds: 0)
        XCTAssertEqual(budget.remainingSeconds(addingWords: -10), 1.8)
        budget.consume(seconds: .nan)
        XCTAssertEqual(budget.remainingSeconds(addingWords: 1_000), 0)
    }

    func testInvalidConfigurationCannotCreateUnboundedWork() {
        for budget in [AcousticRescoreBudget(baseSeconds: .infinity, secondsPerWord: 0.1, maximumSeconds: 6),
                       AcousticRescoreBudget(baseSeconds: 1, secondsPerWord: -1, maximumSeconds: 6),
                       AcousticRescoreBudget(baseSeconds: 7, secondsPerWord: 1, maximumSeconds: 6)] {
            XCTAssertEqual(budget.remainingSeconds(addingWords: 1_000), 0)
        }
    }

    func testTimeoutExhaustsTheRecordingEvenWhenLaterChunksAddWords() {
        let budget = budget()
        XCTAssertEqual(budget.remainingSeconds(addingWords: 20), 2.1, accuracy: 0.000_001)
        budget.exhaust()
        budget.consume(seconds: 2.1)
        XCTAssertEqual(budget.remainingSeconds(addingWords: 1_000), 0)
    }
}
