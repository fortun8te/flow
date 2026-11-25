import XCTest
import ApplicationServices
@testable import Voice

final class AccessibilityBudgetTests: XCTestCase {
    func testTimeoutIsItsOwnOutcome() {
        XCTAssertEqual(AccessibilityBudget.outcome(for: .cannotComplete, hasValue: false), .timedOut)
        XCTAssertEqual(AccessibilityBudget.outcome(for: .cannotComplete, hasValue: true), .timedOut)
    }

    func testSuccessWithValueIsAValue() {
        XCTAssertEqual(AccessibilityBudget.outcome(for: .success, hasValue: true), .value)
    }

    func testMissingOrEmptyAnswersAreAbsent() {
        XCTAssertEqual(AccessibilityBudget.outcome(for: .success, hasValue: false), .absent)
        XCTAssertEqual(AccessibilityBudget.outcome(for: .noValue, hasValue: false), .absent)
        XCTAssertEqual(AccessibilityBudget.outcome(for: .attributeUnsupported, hasValue: false), .absent)
        XCTAssertEqual(AccessibilityBudget.outcome(for: .apiDisabled, hasValue: false), .absent)
    }

    func testBudgetIsShortAndPositive() {
        XCTAssertGreaterThan(AccessibilityBudget.messagingTimeout, 0)
        XCTAssertLessThanOrEqual(AccessibilityBudget.messagingTimeout, 2)
    }

    func testTimeoutIsLoggedOncePerApp() {
        let gate = TimeoutLogGate()
        XCTAssertTrue(gate.shouldLog(app: "com.example.slow"))
        XCTAssertFalse(gate.shouldLog(app: "com.example.slow"))
        XCTAssertFalse(gate.shouldLog(app: "com.example.slow"))
        XCTAssertTrue(gate.shouldLog(app: "com.example.other"))
        XCTAssertFalse(gate.shouldLog(app: "com.example.other"))
    }

    func testNoteTimeoutReportsOnlyTheFirstTime() {
        let gate = TimeoutLogGate()
        XCTAssertTrue(gate.noteTimeout(app: "com.example.slow", attribute: "AXValue"))
        XCTAssertFalse(gate.noteTimeout(app: "com.example.slow", attribute: "AXValue"))
    }

    func testBindReturnsTheSameElement() {
        let element = AXUIElementCreateSystemWide()
        let bound = AccessibilityBudget.bind(element)
        XCTAssertTrue(CFEqual(bound, element))
        // Setting the process default on the system-wide element must not crash.
        AccessibilityBudget.installProcessDefault()
    }
}
