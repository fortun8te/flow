import XCTest
@testable import Voice

final class FlowRecoveryVisibilityTests: XCTestCase {
    func testInterruptedDictationAudioRemainsVisibleAtUnknownDuration() {
        XCTAssertTrue(FlowHistoryVisibility.includes(isMeeting: false, duration: 0, hasAudio: true, segmentCount: 0))
        XCTAssertTrue(FlowHistoryVisibility.includes(isMeeting: true, duration: 12, hasAudio: true, segmentCount: 0))
    }
    func testOrdinaryShortDictationsDoNotFillTheMeetingList() {
        XCTAssertFalse(FlowHistoryVisibility.includes(isMeeting: false, duration: 30, hasAudio: true, segmentCount: 2))
        XCTAssertFalse(FlowHistoryVisibility.includes(isMeeting: false, duration: 0, hasAudio: false, segmentCount: 0))
        XCTAssertTrue(FlowHistoryVisibility.includes(isMeeting: true, duration: 300, hasAudio: false, segmentCount: 3))
    }
}
