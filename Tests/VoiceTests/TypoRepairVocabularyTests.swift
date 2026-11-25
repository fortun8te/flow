import XCTest
@testable import Voice

final class TypoRepairVocabularyTests: XCTestCase {
    func testProductNameNearMissesSnap() throws {
        guard TypoRepair.shared.lexicon(wait: true) != nil else { throw XCTSkip("words.txt is not in the test bundle") }
        let repair = TypoRepair.shared
        XCTAssertEqual(repair.snapVocabulary("wisprflwo"), "Wispr Flow")
        XCTAssertEqual(repair.snapVocabulary("look at how wisprflow does it"), "look at how Wispr Flow does it")
        XCTAssertEqual(repair.snapVocabulary("look at how wispr flow does it"), "look at how Wispr Flow does it")
        XCTAssertEqual(repair.snapVocabulary("what can computeruse do"), "what can COMPUTERUSE do")
        XCTAssertEqual(repair.snapVocabulary("open t3 code pls"), "open T3 Code pls")
    }

    func testOrdinaryWordsAndLinksStay() {
        let repair = TypoRepair.shared
        XCTAssertEqual(repair.snapVocabulary("go with the flow in dark mode"), "go with the flow in dark mode")
        XCTAssertEqual(repair.snapVocabulary("see https://example.com/wisprflow now"), "see https://example.com/wisprflow now")
        XCTAssertEqual(repair.snapVocabulary("the codes are pure"), "the codes are pure")
    }

    func testKeyboardCostCountsSwapsAndSpaces() {
        XCTAssertLessThan(TypoRepair.typoCost("wisprflwo", "wisprflow"), 1.5)
        XCTAssertLessThanOrEqual(TypoRepair.typoCost("figu rei tout", "figure it out"), 3)
    }

    func testRefereeKeepsSpellingAndRevertsNumbers() throws {
        guard TypoRepair.shared.lexicon(wait: true) != nil else { throw XCTSkip("words.txt is not in the test bundle") }
        let merged = OptOneReferee.merge(source: "it has 3 bugs adn dont fix it", candidate: "It has 4 bugs and fix it")
        XCTAssertTrue(merged.text.contains("3 bugs"))
        XCTAssertTrue(merged.text.contains("dont"))
        XCTAssertTrue(merged.text.contains("and"))
    }
}
