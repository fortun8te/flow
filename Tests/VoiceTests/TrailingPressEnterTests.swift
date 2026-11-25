import XCTest
@testable import Voice

final class TrailingPressEnterTests: XCTestCase {
    func testOnlyExplicitStandaloneTrailingCommandIsParsed() {
        XCTAssertEqual(TrailingPressEnter.parse("Hello. Press enter.", enabled: true),
                       .init(text: "Hello.", shouldSubmit: true))
        for text in ["Hello. Press enter.", "Hello press enter", "Do not press enter.",
                     "He said \"Press enter.\"", "He wrote 'hello. Press enter", "Hello. Press enter to continue.",
                     "Press enter.", "Don't send this. Press enter."] {
            XCTAssertFalse(TrailingPressEnter.parse(text, enabled: false).shouldSubmit)
            if text != "Hello. Press enter." {
                XCTAssertFalse(TrailingPressEnter.parse(text, enabled: true).shouldSubmit, text)
            }
        }
    }

    func testCanonicallyEquivalentTextIsNotAnExactReceipt() {
        XCTAssertFalse(TrailingPressEnter.insertionVerified(original: "", replacedRange: NSRange(location: 0, length: 0),
            inserted: "é", observed: "e\u{301}", caret: NSRange(location: 1, length: 0), sameTarget: true))
    }

    func testReceiptRequiresExactValueCaretAndTargetUsingUTF16() {
        let range = NSRange(location: 2, length: 2)
        func verified(_ text: String, _ caret: NSRange, _ target: Bool = true) -> Bool {
            TrailingPressEnter.insertionVerified(original: "A 🌍 end", replacedRange: range,
                inserted: "Hi", observed: text, caret: caret, sameTarget: target)
        }
        XCTAssertTrue(verified("A Hi end", NSRange(location: 4, length: 0)))
        XCTAssertFalse(verified("A Hi end!", NSRange(location: 4, length: 0)))
        XCTAssertFalse(verified("A Hi end", NSRange(location: 3, length: 0)))
        XCTAssertFalse(verified("A Hi end", NSRange(location: 4, length: 1)))
        XCTAssertFalse(verified("A Hi end", NSRange(location: 4, length: 0), false))
        XCTAssertFalse(TrailingPressEnter.insertionVerified(original: "x", replacedRange: NSRange(location: 99, length: 1),
            inserted: "y", observed: "y", caret: NSRange(location: 1, length: 0), sameTarget: true))
    }
}
