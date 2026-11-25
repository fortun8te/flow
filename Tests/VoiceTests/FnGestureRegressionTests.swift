import XCTest
@testable import Voice

@MainActor private final class FnGestureClock {
    var now: TimeInterval = 100
}

@MainActor private final class FnGestureDelegate: HotkeyServiceDelegate {
    weak var service: HotkeyService?
    var starts = 0
    var commits = 0
    var discards = 0
    var locks = 0
    var recording = false
    var stopSynchronously = false

    func hotkeyDidActivate() {
        if service?.isLocked == true {
            recording = false
            commits += 1
            service?.endSessionFromUI()
        } else {
            starts += 1
            recording = true
        }
    }
    func hotkeyDidDeactivate() {
        recording = false
        commits += 1
        if stopSynchronously { service?.endSessionFromUI() }
    }
    func hotkeyDidQuickRelease() { recording = false; discards += 1 }
    func hotkeyDidDoubleTap() { locks += 1; service?.isLocked = true }
}

final class FnGestureRegressionTests: XCTestCase {
    @MainActor private func fixture() -> (HotkeyService, FnGestureDelegate, FnGestureClock) {
        let clock = FnGestureClock()
        let service = HotkeyService(monotonicNow: { clock.now })
        let delegate = FnGestureDelegate()
        delegate.service = service
        service.delegate = delegate
        return (service, delegate, clock)
    }

    @MainActor func testLateSecondTapCannotLockBeforeOverdueTimerRuns() {
        let (service, delegate, clock) = fixture()
        service.fnKeyDown()
        clock.now += 0.04
        service.fnKeyUp()
        // No run-loop turn: the old discard timer has not executed.
        clock.now += 1
        service.fnKeyDown()
        XCTAssertEqual(delegate.discards, 1)
        XCTAssertEqual(delegate.starts, 2)
        XCTAssertEqual(delegate.locks, 0)
        clock.now += 0.25
        service.fnKeyUp()
        XCTAssertEqual(delegate.commits, 1)
        XCTAssertFalse(delegate.recording)
        service.endSessionFromUI()
    }

    @MainActor func testDoubleTapAndThirdTapKeepOneRecordingAndCommitOnce() {
        let (service, delegate, clock) = fixture()
        service.fnKeyDown()
        clock.now += 0.04
        service.fnKeyUp()
        clock.now += 0.05
        service.fnKeyDown()
        service.fnKeyUp()
        XCTAssertEqual(delegate.starts, 1)
        XCTAssertEqual(delegate.locks, 1)
        XCTAssertTrue(delegate.recording)
        service.fnKeyDown()
        service.fnKeyUp()
        XCTAssertEqual(delegate.commits, 1)
        XCTAssertFalse(delegate.recording)
        XCTAssertFalse(service.isHotkeyActive)
    }

    @MainActor func testExternalStopAllowsTheNextHoldToCommit() {
        let (service, delegate, clock) = fixture()
        service.fnSpacePressed()
        delegate.recording = false
        service.endSessionFromUI()
        service.fnKeyDown()
        clock.now += 0.25
        service.fnKeyUp()
        XCTAssertEqual(delegate.starts, 2)
        XCTAssertEqual(delegate.commits, 1)
        XCTAssertFalse(delegate.recording)
    }

    @MainActor func testStopWhileKeyHeldIgnoresRepeatUntilPhysicalRelease() {
        let (service, delegate, clock) = fixture()
        service.fnKeyDown()
        delegate.recording = false
        service.endSessionFromUI()
        service.fnKeyDown()
        XCTAssertEqual(delegate.starts, 1)
        service.fnKeyUp()
        delegate.stopSynchronously = true
        service.fnKeyDown()
        clock.now += 0.25
        service.fnKeyUp()
        XCTAssertEqual(delegate.starts, 2)
        XCTAssertEqual(delegate.commits, 1)
        XCTAssertFalse(delegate.recording)
        XCTAssertFalse(service.isHotkeyActive)
    }
}
