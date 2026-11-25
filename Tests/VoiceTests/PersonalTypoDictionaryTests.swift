import XCTest
@testable import Voice

final class PersonalTypoDictionaryTests: XCTestCase {
    private let dict = ["poreprly": "properly", "nadn": "and", "teh": "the", "dont": "don't", "im": "i'm"]

    func testWholeWordSwapsKeepCapitals() {
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("do it poreprly nadn teh way", dictionary: dict),
                       "do it properly and the way")
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("Teh build is ready", dictionary: dict), "The build is ready")
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("Dont stop", dictionary: dict), "Don't stop")
    }

    func testOnlyWholeWords() {
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("tehran and nadnx", dictionary: dict), "tehran and nadnx")
    }

    func testProtectedSpansStay() {
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("see https://x.com/teh now", dictionary: dict),
                       "see https://x.com/teh now")
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("run `teh` then teh", dictionary: dict),
                       "run `teh` then the")
    }

    func testCurlyApostropheInputMatches() {
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("Dont", dictionary: ["dont": "don't"]), "Don't")
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("i dont know", dictionary: dict), "i don't know")
    }

    func testShippedDictionaryLoadsAndIsSmall() {
        XCTAssertEqual(TypoRepair.personalDictionary["metronmoe"], "metronome")
        XCTAssertLessThan(TypoRepair.personalDictionary.count, 10)
        XCTAssertNil(TypoRepair.personalDictionary["its"], "real English words are never in the dictionary")
        XCTAssertNil(TypoRepair.personalDictionary["bru"], "Slang stays untouched")
    }

    func testPassIsFast() {
        let text = String(repeating: "i dont think teh build poreprly nadn works but whatever ", count: 40)
        let start = Date()
        _ = TypoRepair.applyPersonalDictionary(text, dictionary: dict)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.01)
    }
}
