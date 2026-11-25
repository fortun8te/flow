import Testing
import Foundation
@testable import Voice

@Suite struct FlowNoticeRulesTests {
    private func fresh() -> UserDefaults { UserDefaults(suiteName: "flow.test.rules." + UUID().uuidString)! }

    @Test func debounceOnlyForLightUsersAndTwiceADay() {
        let d = fresh(); let t0 = Date()
        #expect(FlowNoticeRules.debounce(shortcut: "fn", defaults: d, now: t0)?.title == "Don't tap. Hold down fn.")
        #expect(FlowNoticeRules.debounce(shortcut: "fn", defaults: d, now: t0.addingTimeInterval(3600)) == nil)
        #expect(FlowNoticeRules.debounce(shortcut: "fn", defaults: d, now: t0.addingTimeInterval(13 * 3600)) != nil)
        let heavy = fresh(); heavy.set(203_988, forKey: "flow.importedWisprWords")
        #expect(FlowNoticeRules.debounce(shortcut: "fn", defaults: heavy, now: t0) == nil)
    }

    @Test func handsFreeTipThreeTimesAnHourApart() {
        let d = fresh(); var t = Date()
        for _ in 0..<3 {
            #expect(FlowNoticeRules.suggestHandsFree(shortcut: "fn", defaults: d, now: t)?.badge == "Tip")
            #expect(FlowNoticeRules.suggestHandsFree(shortcut: "fn", defaults: d, now: t.addingTimeInterval(60)) == nil)
            t = t.addingTimeInterval(3601)
        }
        #expect(FlowNoticeRules.suggestHandsFree(shortcut: "fn", defaults: d, now: t) == nil)
    }

    @Test func detailedCancelThreeTimesOnceADay() {
        let d = fresh(); var t = Date()
        for _ in 0..<3 {
            #expect(FlowNoticeRules.cancelledDetailed(defaults: d, now: t) != nil)
            #expect(FlowNoticeRules.cancelledDetailed(defaults: d, now: t.addingTimeInterval(3600)) == nil)
            t = t.addingTimeInterval(24 * 3600 + 1)
        }
        #expect(FlowNoticeRules.cancelledDetailed(defaults: d, now: t) == nil)
    }

    @Test func processingCardHasCancel() {
        #expect(FlowNoticeRules.currentlyProcessing().actions.map(\.title) == ["Cancel"])
    }
}
