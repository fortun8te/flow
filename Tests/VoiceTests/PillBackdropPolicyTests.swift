import Foundation
import Testing
@testable import Voice

@Suite("Pill backdrop idle policy")
struct PillBackdropPolicyTests {
    private func mode(glass: Bool = true, shown: Bool = true, resting: Bool, hasFrame: Bool = true,
                      age: TimeInterval = 0) -> PillBackdropPolicy.Mode {
        PillBackdropPolicy.mode(isGlass: glass, isShown: shown, resting: resting, hasFrame: hasFrame, frameAge: age)
    }

    @Test("Flat skins and hidden pills run no capture")
    func flatOrHiddenIsOff() {
        #expect(mode(glass: false, resting: false) == .off)
        #expect(mode(glass: false, resting: true, hasFrame: false) == .off)
        #expect(mode(shown: false, resting: false) == .off)
        #expect(mode(shown: false, resting: true, hasFrame: false) == .off)
    }

    @Test("An open or working glass pill streams live")
    func activeIsLive() {
        #expect(mode(resting: false) == .live)
        #expect(mode(resting: false, hasFrame: false) == .live)
    }

    @Test("A resting glass pill never streams: it holds a fresh frame")
    func restingHoldsFreshFrame() {
        #expect(mode(resting: true, hasFrame: true, age: 0) == .hold)
        #expect(mode(resting: true, hasFrame: true, age: PillBackdropPolicy.staleAfter) == .hold)
    }

    @Test("A resting glass pill takes one snapshot when it has no frame or a stale one")
    func restingSnapshotsWhenNeeded() {
        #expect(mode(resting: true, hasFrame: false, age: .infinity) == .snapshot)
        #expect(mode(resting: true, hasFrame: true, age: PillBackdropPolicy.staleAfter + 0.5) == .snapshot)
    }
}
