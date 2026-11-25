import XCTest
@testable import Voice

final class FlowPillStateTests: XCTestCase {
    func testPasteRecoveryKeepsExactResultWithoutEmbeddingItInAnErrorMessage() throws {
        let text = "First line.\nKeep the last space. "
        let notice = try XCTUnwrap(FlowPillNotice.pasteRecovery(text))
        XCTAssertEqual(notice.recoveryText, text)
        XCTAssertEqual(notice.kind, .paste)
        XCTAssertEqual(notice.timeout, 8)
        XCTAssertEqual(notice.message, "")
        XCTAssertFalse(notice.hidesRecoveryPreview)
        XCTAssertNil(FlowPillNotice.pasteRecovery(" \n"))
        let second = try XCTUnwrap(FlowPillNotice.pasteRecovery("A newer result."))
        XCTAssertNotEqual(second.id, notice.id)
        XCTAssertEqual(notice.recoveryText, text)
    }

    func testPasteRecoveryResumesWithTheRemainingTimeAndAtLeastTwoSeconds() throws {
        let notice = try XCTUnwrap(FlowPillNotice.pasteRecovery("A failed paste."))
        XCTAssertEqual(notice.resumedTimeout(remaining: nil), 8)
        XCTAssertEqual(notice.resumedTimeout(remaining: 5), 5)
        XCTAssertEqual(notice.resumedTimeout(remaining: 0.25), 2)
        XCTAssertEqual(notice.resumedTimeout(remaining: 0), 2)
        XCTAssertEqual(FlowPillNotice.permission(.microphone).resumedTimeout(remaining: 1), 10)
    }

    func testPrivateFieldRecoveryKeepsCopyButHidesThePreview() throws {
        let notice = try XCTUnwrap(FlowPillNotice.pasteRecovery("Private text", secureField: true))
        XCTAssertEqual(notice.recoveryText, "Private text")
        XCTAssertTrue(notice.hidesRecoveryPreview)
        XCTAssertEqual(notice.title, "Skipped password field")
        XCTAssertEqual(FlowPillNotice.pasteRecovery("Another edit", unconfirmed: true)?.title, "Paste not confirmed")
    }

    func testHoverOpensAfter150msAndBackendWins() {
        var machine = FlowPillMachine()
        XCTAssertEqual(machine.send(.pointerEntered), [.scheduleCollapse(generation: 1, milliseconds: FlowPillMachine.enterMilliseconds)])
        XCTAssertEqual(machine.state, .resting)
        XCTAssertEqual(machine.send(.pointerEntered), [])   // repeated pointer moves queue nothing
        _ = machine.send(.collapseElapsed(1))
        XCTAssertEqual(machine.state, .ready)
        _ = machine.send(.backend(.pushToTalk))
        _ = machine.send(.collapseElapsed(1))               // a stale timer changes nothing
        XCTAssertEqual(machine.state, .pushToTalk)
        XCTAssertEqual(machine.send(.escape), [.cancel])
        XCTAssertEqual(machine.send(.clicked), [.finishAndPaste])
    }

    func testReadyClickAndSideGeometry() {
        var machine = FlowPillMachine()
        _ = machine.send(.pointerEntered)
        _ = machine.send(.collapseElapsed(1))
        XCTAssertEqual(machine.send(.clicked), [.startHandsFree])
        XCTAssertEqual(FlowPillPresentation.forState(.handsFree, side: true).height, 102.5)
        XCTAssertEqual(FlowPillPresentation.forState(.meeting(.active)).waveformBars, 5)
        XCTAssertEqual(FlowPillPresentation.forState(.pushToTalk).waveformBars, 10)
    }

    func testLeavingWaits120msAndAnEarlyReturnKeepsTheBarOpen() {
        var machine = FlowPillMachine()
        _ = machine.send(.pointerEntered)
        _ = machine.send(.collapseElapsed(1))
        XCTAssertEqual(machine.state, .ready)
        XCTAssertEqual(machine.send(.pointerExited), [.scheduleCollapse(generation: 2, milliseconds: 120)])
        XCTAssertEqual(machine.state, .ready)               // inside the 120 ms: still open
        XCTAssertEqual(machine.send(.pointerEntered), [])   // back in time: nothing queued
        XCTAssertEqual(machine.send(.collapseElapsed(2)), []) // the cancelled exit does nothing
        XCTAssertEqual(machine.state, .ready)
        _ = machine.send(.pointerExited)
        _ = machine.send(.collapseElapsed(4))
        XCTAssertEqual(machine.state, .resting)
    }

    func testLeavingBeforeTheEnterTimerCancelsTheOpen() {
        var machine = FlowPillMachine()
        _ = machine.send(.pointerEntered)
        XCTAssertEqual(machine.send(.pointerExited), [])
        _ = machine.send(.collapseElapsed(1))
        XCTAssertEqual(machine.state, .resting)
    }

    func testRapidFlipsLeaveNoLiveTimerAndStaleTimersDoNothing() {
        var machine = FlowPillMachine()
        var timers: [Int] = []
        for _ in 0..<50 {
            if case .scheduleCollapse(let generation, _)? = machine.send(.pointerEntered).first { timers.append(generation) }
            _ = machine.send(.pointerExited)
        }
        XCTAssertEqual(machine.state, .resting)
        for generation in timers { _ = machine.send(.collapseElapsed(generation)) }
        XCTAssertEqual(machine.state, .resting)
    }

    func testPolishLabelIsAlwaysPolishingWithNoFractionOrOverdueText() {
        let start = ContinuousClock.now
        let estimate = FlowWorkPresentation.PolishEstimate(stageStartedAt: start,
            finishAt: start + .seconds(4), range: 0.2...0.8)
        for stage in [FlowWorkPresentation.PolishStage.editing, .checkingDraft, .applying, .restoring, .loadingModel] {
            for elapsed in [0.0, 2, 4, 9] {
                let progress = FlowWorkPresentation.polishProgress(stage: stage, estimate: estimate, at: start + .seconds(elapsed))
                XCTAssertEqual(progress.title, "Polishing")
                XCTAssertNil(progress.fraction)
            }
        }
    }

    func testPolishProgressDoesNotRestartWhenTheForecastChanges() {
        let start = ContinuousClock.now
        let history = QuickPolishTiming.History()
        var timing = QuickPolishTiming(words: 40, at: start)

        let loading = start + .milliseconds(150)
        let beforeLoading = timing.estimate(using: history).fraction(at: loading)
        timing.enter(.loadingModel, at: loading)
        XCTAssertEqual(timing.estimate(using: history).fraction(at: loading), beforeLoading, accuracy: 0.0001)

        let editing = start + .seconds(2)
        let beforeEditing = timing.estimate(using: history).fraction(at: editing)
        timing.enter(.editing, at: editing)
        XCTAssertEqual(timing.estimate(using: history).fraction(at: editing), beforeEditing, accuracy: 0.0001)

        let checking = start + .seconds(3)
        let beforeChecking = timing.estimate(using: history).fraction(at: checking)
        timing.enter(.checkingDraft, at: checking)
        XCTAssertEqual(timing.estimate(using: history).fraction(at: checking), beforeChecking, accuracy: 0.0001)
    }

    func testSlowPolishKeepsMovingThroughOverdueStageAndReachesApplyingWithoutJumpingBack() throws {
        let start = ContinuousClock.now
        let history = QuickPolishTiming.History()
        var timing = QuickPolishTiming(words: 20, at: start)
        let editing = timing.estimate(using: history)
        let first = editing.fraction(at: start + .seconds(2))
        let later = editing.fraction(at: start + .seconds(4))
        XCTAssertGreaterThan(later, first)
        timing.enter(.checkingDraft, at: start + .seconds(4))
        let checking = timing.estimate(using: history)
        XCTAssertEqual(checking.fraction(at: start + .seconds(4)), later, accuracy: 0.0001)
        XCTAssertGreaterThan(checking.fraction(at: start + .seconds(7)), later)
        let deadline = start + .seconds(PolishTransaction.shortcutBudgetSeconds)
        XCTAssertNil(FlowWorkPresentation.polishProgress(stage: .applying, estimate: checking, at: deadline).fraction)
    }

    func testQuickPolishRefitsForecastOnStageChangesAndRecentDuration() {
        let start = ContinuousClock.now
        var history = QuickPolishTiming.History()
        var short = QuickPolishTiming(words: 12, at: start)
        var long = QuickPolishTiming(words: 100, at: start)
        XCTAssertLessThan(short.estimate(using: history).finishAt, long.estimate(using: history).finishAt)
        short.enter(.loadingModel, at: start)
        XCTAssertGreaterThan(short.estimate(using: history).finishAt, long.estimate(using: history).finishAt)

        short.enter(.editing, at: start + .seconds(2))
        long.enter(.checkingDraft, at: start + .seconds(1))
        XCTAssertGreaterThan(long.estimate(using: history).finishAt, short.estimate(using: history).finishAt)
        let initial = history.expectedSeconds(.loadingModel, words: 12)
        history.record(short.samples(endingAt: start + .seconds(3)))
        XCTAssertLessThan(history.expectedSeconds(.loadingModel, words: 12), initial)
        XCTAssertGreaterThan(history.expectedSeconds(.editing, words: 12), 0.5)

        let expectedReview = history.expectedSeconds(.checkingDraft, words: 100)
        long.enter(.checkingDraft, at: start + .seconds(2)) // repeated callback cannot restart the clock
        XCTAssertEqual(long.samples(endingAt: start + .seconds(3)).last?.duration, .seconds(2))
        XCTAssertEqual(history.expectedSeconds(.checkingDraft, words: 100), expectedReview)
    }

    func testMeetingStopAddsSpaceAlongTheDockAxis() {
        XCTAssertEqual(FlowPillPresentation.addingMeetingStop(to: CGSize(width: 102.5, height: 30), side: false), CGSize(width: 140.5, height: 30))
        XCTAssertEqual(FlowPillPresentation.addingMeetingStop(to: CGSize(width: 30, height: 102.5), side: true), CGSize(width: 30, height: 140.5))
    }

}
