import Testing
@testable import Voice

struct PillInkTests {
    @Test("Glass ink does not flicker near one threshold and holds still while the pill is busy")
    func hysteresis() {
        #expect(PillInk.bright(false, luma: 0.62, busy: false) == false)
        #expect(PillInk.bright(false, luma: 0.70, busy: false) == true)
        #expect(PillInk.bright(true, luma: 0.58, busy: false) == true)
        #expect(PillInk.bright(true, luma: 0.40, busy: false) == false)
        #expect(PillInk.bright(false, luma: 0.95, busy: true) == false)
        #expect(PillInk.bright(true, luma: nil, busy: false) == true)
    }
}
