import XCTest
@testable import Voice

final class PipelineTimerTests: XCTestCase {
    func testElapsedDurationAndMillisecondsUseTheSameMonotonicOrigin() {
        let start = ContinuousClock.now
        let timer = PipelineTimer(started: start)
        let end = start + .milliseconds(1_275)
        XCTAssertEqual(timer.seconds(at: end), 1.275, accuracy: 0.000001)
        XCTAssertEqual(timer.milliseconds(at: end), 1_275)
    }

    func testNoNegativeLatencyForAnEarlierObservation() {
        let start = ContinuousClock.now
        let timer = PipelineTimer(started: start)
        XCTAssertEqual(timer.seconds(at: start - .seconds(1)), 0)
        XCTAssertEqual(timer.milliseconds(at: start), 0)
    }
}
