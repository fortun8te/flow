import Testing
@testable import Voice

@Suite("Hands-free double-tap window")
struct DoubleTapWindowTests {
    @Test("Unset value uses the 450 ms default")
    func defaultWindow() {
        #expect(HotkeyService.resolvedDoubleTapWindow(storedMs: nil) == 0.45)
    }

    @Test("Values inside the range are used as given")
    func inRange() {
        #expect(HotkeyService.resolvedDoubleTapWindow(storedMs: 400) == 0.40)
        #expect(HotkeyService.resolvedDoubleTapWindow(storedMs: 600) == 0.60)
    }

    @Test("Values outside 250...700 ms are clamped")
    func clamped() {
        #expect(HotkeyService.resolvedDoubleTapWindow(storedMs: 10) == 0.25)
        #expect(HotkeyService.resolvedDoubleTapWindow(storedMs: 0) == 0.25)
        #expect(HotkeyService.resolvedDoubleTapWindow(storedMs: 5000) == 0.70)
    }

    @Test("Range bounds are inclusive and the default is inside the range")
    func bounds() {
        #expect(HotkeyService.doubleTapWindowRangeMs.contains(HotkeyService.defaultDoubleTapWindowMs))
        #expect(HotkeyService.resolvedDoubleTapWindow(storedMs: 250) == 0.25)
        #expect(HotkeyService.resolvedDoubleTapWindow(storedMs: 700) == 0.70)
    }
}
