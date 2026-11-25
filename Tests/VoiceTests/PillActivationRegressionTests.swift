import XCTest
@testable import Voice

@MainActor private final class PillShortcutDelegate: HotkeyServiceDelegate {
    var activated = 0
    var doubled = 0
    weak var service: HotkeyService?
    func hotkeyDidActivate() { activated += 1 }
    func hotkeyDidDeactivate() {}
    func hotkeyDidQuickRelease() {}
    func hotkeyDidDoubleTap() { doubled += 1; service?.isLocked = true }
}
final class PillActivationRegressionTests: XCTestCase {
    @MainActor func testPillHandsFreeThenUIStopAllowsAFreshPhysicalPress() {
        let service = HotkeyService()
        let delegate = PillShortcutDelegate(); delegate.service = service; service.delegate = delegate
        service.fnSpacePressed()
        XCTAssertEqual(delegate.activated, 1)
        XCTAssertEqual(delegate.doubled, 1)
        XCTAssertTrue(service.isLocked)
        service.endSessionFromUI()
        XCTAssertFalse(service.isLocked)
        service.fnKeyDown()
        XCTAssertEqual(delegate.activated, 2)
        service.endSessionFromUI()
    }
    func testFailedModelsNeverLookLikeLoading() {
        XCTAssertEqual(FlowPillNotice.speechNotReady(.error("synthetic failure")).kind, .modelUnavailable)
        XCTAssertEqual(FlowPillNotice.speechNotReady(.notDownloaded).kind, .modelUnavailable)
        XCTAssertEqual(FlowPillNotice.speechNotReady(.loading).kind, .preparing)
    }
}
