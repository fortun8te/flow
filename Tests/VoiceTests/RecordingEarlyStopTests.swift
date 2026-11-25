import AVFoundation
import XCTest
@testable import Voice

/// "Sometimes the recording just stops recording." (21 Nov 2026)
/// events.jsonl 2026-11-21 02:10:29 and 14:57:02: on a cold engine start the user's quick
/// double-tap was measured as a 280-302 ms hold (keyUp delivered late on a busy main thread),
/// so Flow committed an empty push-to-talk ("No speech was transcribed") and the second tap
/// was then discarded as a stray.
@MainActor private final class EarlyStopDelegate: HotkeyServiceDelegate {
    weak var service: HotkeyService?
    var starts = 0, commits = 0, discards = 0, locks = 0
    func hotkeyDidActivate() {
        if service?.isLocked == true { commits += 1; service?.endSessionFromUI() } else { starts += 1 }
    }
    func hotkeyDidDeactivate() { commits += 1 }
    func hotkeyDidQuickRelease() { discards += 1 }
    func hotkeyDidDoubleTap() { locks += 1; service?.isLocked = true }
}

final class RecordingEarlyStopTests: XCTestCase {
    @MainActor func testLateDeliveredReleaseOfAQuickTapStillArmsTheDoubleTap() {
        var now: TimeInterval = 100
        let service = HotkeyService(monotonicNow: { now }, physicalFnHeld: { false })
        let delegate = EarlyStopDelegate()
        delegate.service = service
        service.delegate = delegate

        service.fnKeyDown(at: 100.0)          // delivered at once
        now = 100.302                          // main thread busy starting the audio engine
        service.fnKeyUp(at: 100.110)           // the finger really lifted after 110 ms
        XCTAssertEqual(delegate.commits, 0, "a 110 ms tap must not commit as push-to-talk")
        now = 100.355
        service.fnKeyDown(at: 100.300)
        XCTAssertEqual(delegate.locks, 1, "second tap locks hands-free")
        XCTAssertEqual(delegate.starts, 1)
        XCTAssertEqual(delegate.discards, 0)
        service.fnKeyUp(at: 100.40)
        service.endSessionFromUI()
    }

    @MainActor func testWithoutEventTimesALateReleaseStillBehavesAsBefore() {
        var now: TimeInterval = 100
        let service = HotkeyService(monotonicNow: { now }, physicalFnHeld: { false })
        let delegate = EarlyStopDelegate()
        delegate.service = service
        service.delegate = delegate
        service.fnKeyDown()
        now += 0.30
        service.fnKeyUp()
        XCTAssertEqual(delegate.commits, 1)
    }

    @MainActor func testRealHoldStillCommitsOnRelease() {
        var now: TimeInterval = 100
        let service = HotkeyService(monotonicNow: { now }, physicalFnHeld: { false })
        let delegate = EarlyStopDelegate()
        delegate.service = service
        service.delegate = delegate
        service.fnKeyDown(at: 100)
        now = 103
        service.fnKeyUp(at: 102.9)
        XCTAssertEqual(delegate.commits, 1)
        XCTAssertEqual(delegate.discards, 0)
    }

    @MainActor func testEventTimeInTheFutureIsClampedToNow() {
        var now: TimeInterval = 100
        let service = HotkeyService(monotonicNow: { now }, physicalFnHeld: { false })
        let delegate = EarlyStopDelegate()
        delegate.service = service
        service.delegate = delegate
        service.fnKeyDown(at: 100)
        now = 101
        service.fnKeyUp(at: 500)   // nonsense time can only shorten to "now"
        XCTAssertEqual(delegate.commits, 1)
    }

    func testEventTimestampReadsNanosecondsOrMachTicks() {
        let now: TimeInterval = 197_221.76
        let nanos = UInt64((now - 0.2) * 1e9)
        XCTAssertEqual(FnKeyTap.eventUptime(rawTimestamp: nanos, now: now, timebase: (125, 3))!, now - 0.2, accuracy: 0.001)
        let ticks = UInt64((now - 0.2) * 1e9 * 3 / 125)
        XCTAssertEqual(FnKeyTap.eventUptime(rawTimestamp: ticks, now: now, timebase: (125, 3))!, now - 0.2, accuracy: 0.001)
        XCTAssertNil(FnKeyTap.eventUptime(rawTimestamp: 0, now: now))
        XCTAssertNil(FnKeyTap.eventUptime(rawTimestamp: UInt64((now - 60) * 1e9), now: now, timebase: (1, 1)))
    }

    func testSameDeviceSameFormatRouteChangeIsIgnored() {
        let format = (sampleRate: 48_000.0, channels: AVAudioChannelCount(1))
        XCTAssertFalse(AudioCaptureService.routeChangeNeedsRebuild(engineRunning: true, oldClass: "builtIn",
            newClass: "builtIn", oldFormat: format, newFormat: format))
        XCTAssertTrue(AudioCaptureService.routeChangeNeedsRebuild(engineRunning: false, oldClass: "builtIn",
            newClass: "builtIn", oldFormat: format, newFormat: format))
        XCTAssertTrue(AudioCaptureService.routeChangeNeedsRebuild(engineRunning: true, oldClass: "builtIn",
            newClass: "bluetooth", oldFormat: format, newFormat: (16_000, 1)))
        XCTAssertTrue(AudioCaptureService.routeChangeNeedsRebuild(engineRunning: true, oldClass: "builtIn",
            newClass: "builtIn", oldFormat: format, newFormat: (44_100, 1)))
        XCTAssertTrue(AudioCaptureService.routeChangeNeedsRebuild(engineRunning: true, oldClass: "builtIn",
            newClass: "builtIn", oldFormat: nil, newFormat: format))
    }
}
