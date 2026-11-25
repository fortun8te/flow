import AppKit
import CoreGraphics
import XCTest
@testable import Voice

/// Jordan, 21 Nov 2026: "Sometimes it kicks me off of my keyboard." Flow's active key taps ran on the
/// main run loop, so every key on the Mac waited for Flow's main thread, and each synthetic Cmd-V / Cmd-C
/// muted the real keyboard for 0.25 s. These tests pin the fixes.
final class KeyboardFreezeTests: XCTestCase {

    // MARK: Tap thread

    func testKeyTapThreadRunsWorkWhileMainThreadIsBlocked() {
        XCTAssertTrue(Thread.isMainThread)
        let done = DispatchSemaphore(value: 0)
        var ranOnTapThread = false
        KeyTapThread.shared.perform {
            ranOnTapThread = KeyTapThread.shared.isCurrent && !Thread.isMainThread
            done.signal()
        }
        // The main thread is blocked here. On the old main-run-loop design this would time out.
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(ranOnTapThread)
    }

    // MARK: Paste-last / quick-polish keys

    private func decide(_ keyCode: Int64, down: Bool = true, flags: CGEventFlags = [],
                        latch: PolishKeyTap.Latch = .init(), answer: Bool = true,
                        asked: inout [PolishKeyTap.Action]) -> PolishKeyTap.Decision {
        PolishKeyTap.decide(keyCode: keyCode, isDown: down, flags: flags, latch: latch) { action in
            asked.append(action)
            return answer
        }
    }

    func testOrdinaryTypingNeverAsksTheMainThread() {
        var asked: [PolishKeyTap.Action] = []
        // a, v, 1, Shift+V, Cmd+V, Option+V, Cmd+1: all pass, none waits for Flow.
        let cases: [(Int64, CGEventFlags)] = [(0, []), (9, []), (18, []), (9, .maskShift), (9, .maskCommand),
                                              (9, .maskAlternate), (18, .maskCommand), (18, [.maskAlternate, .maskShift])]
        for (key, flags) in cases {
            for down in [true, false] {
                let d = decide(key, down: down, flags: flags, asked: &asked)
                XCTAssertFalse(d.swallow, "key \(key) flags \(flags.rawValue) down \(down)")
                XCTAssertNil(d.action)
            }
        }
        XCTAssertEqual(asked, [])
    }

    func testControlCommandVPastesOnceAndTakesItsKeyUp() {
        var asked: [PolishKeyTap.Action] = []
        let first = decide(9, flags: [.maskControl, .maskCommand], asked: &asked)
        XCTAssertEqual(first, .init(swallow: true, latch: .init(pasteDown: true), action: .pasteLast))
        let repeatDown = decide(9, flags: [.maskControl, .maskCommand], latch: first.latch, asked: &asked)
        XCTAssertEqual(repeatDown, .init(swallow: true, latch: first.latch, action: nil))
        let up = decide(9, down: false, flags: [.maskControl, .maskCommand], latch: first.latch, asked: &asked)
        XCTAssertEqual(up, .init(swallow: true, latch: .init(), action: nil))
        XCTAssertEqual(asked, [.pasteLast])
    }

    func testControlCommandVPassesWhenThereIsNothingToPaste() {
        var asked: [PolishKeyTap.Action] = []
        let d = decide(9, flags: [.maskControl, .maskCommand], answer: false, asked: &asked)
        XCTAssertEqual(d, .init(swallow: false, latch: .init(), action: nil))
    }

    func testOptionOneStartsQuickPolishOnce() {
        var asked: [PolishKeyTap.Action] = []
        let d = decide(18, flags: .maskAlternate, asked: &asked)
        XCTAssertEqual(d, .init(swallow: true, latch: .init(polishDown: true), action: .quickPolish))
        let up = decide(18, down: false, flags: [], latch: d.latch, asked: &asked)
        XCTAssertEqual(up, .init(swallow: true, latch: .init(), action: nil))
        let off = decide(18, flags: .maskAlternate, answer: false, asked: &asked)
        XCTAssertFalse(off.swallow)
    }

    // MARK: Synthetic keys no longer mute the keyboard

    func testIsolatedEventSourceDoesNotSuppressTheRealKeyboard() throws {
        let src = try XCTUnwrap(CursorPaster.isolatedEventSource())
        XCTAssertEqual(src.localEventsSuppressionInterval, 0)
        let filter = src.getLocalEventsFilterDuringSuppressionState(.eventSuppressionStateSuppressionInterval)
        XCTAssertTrue(filter.contains(.permitLocalKeyboardEvents))
    }

    // MARK: Opt+1 selection read

    func testCopyWaitsForOptionToComeUp() {
        var reads = 0
        let flags: () -> CGEventFlags = {
            reads += 1
            return reads < 4 ? .maskAlternate : []
        }
        XCTAssertTrue(CursorPaster.waitForModifiersUp(timeout: 1, flags: flags, sleep: { _ in }))
        XCTAssertEqual(reads, 4)
    }

    func testCopyGivesUpWaitingWhenOptionStaysDown() {
        let started = Date()
        XCTAssertFalse(CursorPaster.waitForModifiersUp(timeout: 0.05, flags: { .maskAlternate }, sleep: { usleep(useconds_t($0 * 1e6)) }))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        // Caps Lock does not count as held.
        XCTAssertTrue(CursorPaster.waitForModifiersUp(timeout: 0.05, flags: { .maskAlphaShift }, sleep: { _ in }))
    }

    func testElectronWindowWithoutAFocusedFieldStillCountsAsTheSamePlace() {
        let eq: (Int, Int) -> Bool = { $0 == $1 }
        XCTAssertTrue(CursorPaster.sameOptionalField(nil as Int?, nil, equal: eq))
        XCTAssertTrue(CursorPaster.sameOptionalField(1, 1, equal: eq))
        XCTAssertFalse(CursorPaster.sameOptionalField(1, 2, equal: eq))
        XCTAssertFalse(CursorPaster.sameOptionalField(1, nil, equal: eq))
        XCTAssertFalse(CursorPaster.sameOptionalField(nil, 1, equal: eq))
    }
}
