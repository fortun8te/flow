import AppKit
import Foundation
import XCTest
@testable import Voice

/// PillHaptics: the `voice.haptics` gate and the 150 ms rate limit.
@MainActor
final class PillHapticsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var now: TimeInterval = 0
    private var taps: [NSHapticFeedbackManager.FeedbackPattern] = []

    override func setUp() {
        super.setUp()
        suite = "PillHapticsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        now = 0
        taps = []
        PillHaptics.defaults = defaults
        PillHaptics.clock = { [unowned self] in self.now }
        PillHaptics.performer = { [unowned self] pattern in self.taps.append(pattern) }
        PillHaptics.limiter = PillHaptics.RateLimiter()
    }

    override func tearDown() {
        PillHaptics.defaults = .standard
        PillHaptics.clock = { ProcessInfo.processInfo.systemUptime }
        PillHaptics.performer = { pattern in
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
        PillHaptics.limiter = PillHaptics.RateLimiter()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: Gate

    func testMissingKeyMeansOn() {
        XCTAssertTrue(PillHaptics.isEnabled(in: defaults))
    }

    func testExplicitFalseTurnsTapsOff() {
        defaults.set(false, forKey: PillHaptics.key)
        XCTAssertFalse(PillHaptics.isEnabled(in: defaults))
        PillHaptics.pasteConfirmed()
        XCTAssertTrue(taps.isEmpty)
    }

    func testExplicitTrueKeepsTapsOn() {
        defaults.set(true, forKey: PillHaptics.key)
        XCTAssertTrue(PillHaptics.isEnabled(in: defaults))
        PillHaptics.start()
        XCTAssertEqual(taps.count, 1)
    }

    func testStartUsesLevelChangeAndDoneUsesGeneric() {
        PillHaptics.start()
        now += 1
        PillHaptics.done()
        XCTAssertEqual(taps, [.levelChange, .generic])
    }

    func testChangeAppliesLiveWithoutRestart() {
        PillHaptics.error()
        XCTAssertEqual(taps.count, 1)
        defaults.set(false, forKey: PillHaptics.key)
        now += 1
        PillHaptics.error()
        XCTAssertEqual(taps.count, 1)
        defaults.set(true, forKey: PillHaptics.key)
        now += 1
        PillHaptics.error()
        XCTAssertEqual(taps.count, 2)
    }

    func testUsesLightPatterns() {
        PillHaptics.start()
        now += 1
        PillHaptics.pasteConfirmed()
        now += 1
        PillHaptics.error()
        now += 1
        PillHaptics.polishFinished()
        XCTAssertEqual(taps, [.levelChange, .generic, .levelChange, .alignment])
    }

    // MARK: Rate limit

    func testSecondTapInsideWindowIsDropped() {
        PillHaptics.pasteConfirmed()
        now += 0.100
        PillHaptics.error()
        XCTAssertEqual(taps.count, 1)
    }

    func testTapAfterWindowGoesThrough() {
        PillHaptics.pasteConfirmed()
        now += 0.150
        PillHaptics.error()
        XCTAssertEqual(taps.count, 2)
    }

    func testDroppedTapDoesNotExtendTheWindow() {
        PillHaptics.pasteConfirmed()          // t = 0, allowed
        now += 0.100
        PillHaptics.error()               // t = 0.1, dropped
        now += 0.060                          // t = 0.16, measured from the first allowed tap
        PillHaptics.polishFinished()
        XCTAssertEqual(taps.count, 2)
    }

    func testRateLimiterSpacing() {
        var limiter = PillHaptics.RateLimiter(minimumInterval: 0.150)
        XCTAssertTrue(limiter.allow(at: 0))
        XCTAssertFalse(limiter.allow(at: 0.149))
        XCTAssertTrue(limiter.allow(at: 0.150))
        XCTAssertFalse(limiter.allow(at: 0.200))
        XCTAssertTrue(limiter.allow(at: 0.400))
    }

    func testDisabledTapDoesNotUseTheRateWindow() {
        defaults.set(false, forKey: PillHaptics.key)
        PillHaptics.pasteConfirmed()
        defaults.set(true, forKey: PillHaptics.key)
        PillHaptics.error()
        XCTAssertEqual(taps.count, 1, "a suppressed tap must not block the next audible one")
    }
}
