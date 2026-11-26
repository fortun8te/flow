import Foundation
import XCTest
@testable import Voice

final class VocabularyReplacementRulesTests: XCTestCase {
    func testLongestPhraseWinsWithoutCascading() {
        let rules = VocabularyReplacementRules([("blue", "BlueToy"), ("blue kettle", "MoonToy"), ("MoonToy", "OrbitToy")])
        XCTAssertEqual(rules.apply(to: "blue kettle beside blue"), "MoonToy beside BlueToy")
    }

    func testHorizontalWhitespaceMatchesWithoutJoiningLines() {
        let rules = VocabularyReplacementRules([("blue kettle", "BlueKettle")])
        XCTAssertEqual(rules.apply(to: "blue  kettle blue\tkettle blue\u{00A0}kettle"), "BlueKettle BlueKettle BlueKettle")
        XCTAssertEqual(rules.apply(to: "blue\nkettle"), "blue\nkettle")
    }

    func testConflictingTargetsAndExplicitlyBlockedAliasesAbstain() {
        let rules = VocabularyReplacementRules([("blue kettle", "MoonToy"), ("BLUE  KETTLE", "OrbitToy"), ("zed", "ZedToy")],
                                               blockedAliases: [" ZED "])
        XCTAssertNil(rules.regex)
        XCTAssertEqual(rules.apply(to: "blue kettle and zed"), "blue kettle and zed")
    }

    func testPreferredCaseAndApostropheVariantsAreStable() {
        let rules = VocabularyReplacementRules([("orbit toy", "OrbitToy"), ("ORBIT TOY", "ORBITTOY"), ("zen's box", "ZenBox")])
        XCTAssertEqual(rules.apply(to: "ORBIT toy and zen’s  box"), "OrbitToy and ZenBox")
    }

    func testExcludedTargetsAreNormalized() {
        let rules = VocabularyReplacementRules([("blue kettle", "MoonToy"), ("zed", "ZedToy")], excludedTargets: [" MOONTOY "])
        XCTAssertEqual(rules.apply(to: "blue kettle and zed"), "blue kettle and ZedToy")
    }

    func testWholeWordsAndPathBoundariesArePreserved() {
        let rules = VocabularyReplacementRules([("zed", "ZedToy")])
        XCTAssertEqual(rules.apply(to: "zed zedder /zed zed/path zed@example.com"), "ZedToy zedder /zed zed/path zed@example.com")
    }

    func testEmptyAndMultilineRulesDoNotCorruptText() {
        let rules = VocabularyReplacementRules([(" ", "BlueToy"), ("blue\nkettle", "BlueKettle"), ("zed", "Zed\nToy")])
        XCTAssertNil(rules.regex)
        XCTAssertEqual(rules.apply(to: "blue kettle and zed"), "blue kettle and zed")
    }
}
