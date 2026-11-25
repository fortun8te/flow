import AppKit
import XCTest
@testable import Voice

/// Typing and deletion remain available during dictation.
/// Flow's taps may consume only Flow's own keys, and the finished text must land at the
/// cursor the user has at that moment, never at a position saved when recording started.
final class TypingDuringDictationTests: XCTestCase {

    private let letterA: Int64 = 0
    private let delete: Int64 = 51
    private let forwardDelete: Int64 = 117
    private let leftArrow: Int64 = 123
    private let space: Int64 = 49

    // MARK: Event pass-through

    func testOrdinaryKeysPassThroughWhileFnIsHeld() {
        for key in [letterA, delete, forwardDelete, leftArrow] {
            XCTAssertFalse(FnKeyTap.consumesKeyDown(keyCode: key, fnDown: true, fnBit: true, hasOtherModifier: false),
                           "key \(key) must reach the app while fn is held")
        }
    }

    func testKeysPassThroughWhenFnIsNotHeld() {
        XCTAssertFalse(FnKeyTap.consumesKeyDown(keyCode: letterA, fnDown: false, fnBit: false, hasOtherModifier: false))
        XCTAssertFalse(FnKeyTap.consumesKeyDown(keyCode: space, fnDown: false, fnBit: false, hasOtherModifier: false))
    }

    func testOnlyFnSpaceChordIsConsumed() {
        XCTAssertTrue(FnKeyTap.consumesKeyDown(keyCode: space, fnDown: true, fnBit: true, hasOtherModifier: false))
        // Space with another modifier is the app's own shortcut, so it passes.
        XCTAssertFalse(FnKeyTap.consumesKeyDown(keyCode: space, fnDown: true, fnBit: true, hasOtherModifier: true))
    }

    func testFnSpaceKeyUpIsConsumedOnlyWhileTheChordIsDown() {
        XCTAssertTrue(FnKeyTap.consumesKeyUp(keyCode: space, fnSpaceDown: true))
        XCTAssertFalse(FnKeyTap.consumesKeyUp(keyCode: space, fnSpaceDown: false))
        XCTAssertFalse(FnKeyTap.consumesKeyUp(keyCode: letterA, fnSpaceDown: true))
    }

    // MARK: Insert position

    func testInsertionAtTheCurrentEndOfASentenceJoinsWithASpace() {
        let field = "I typed this."
        let caret = NSRange(location: (field as NSString).length, length: 0)
        let result = CursorPaster.resolvedInsertion("More words", field: field, selection: caret,
                                                    preFormatted: false, bundleID: "com.apple.TextEdit")
        XCTAssertTrue(result.hasPrefix(" "), "expected a space after the typed sentence, got \(result.debugDescription)")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespaces), "More words")
    }

    func testInsertionAtTheStartOfTheFieldHasNoLeadingSpace() {
        let field = "typed later"
        let caret = NSRange(location: 0, length: 0)
        let result = CursorPaster.resolvedInsertion("More words", field: field, selection: caret,
                                                    preFormatted: false, bundleID: "com.apple.TextEdit")
        XCTAssertFalse(result.hasPrefix(" "), "nothing precedes the caret, so no leading space")
        XCTAssertTrue(result.hasSuffix(" "), "the existing text follows, so it needs a separating space")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespaces), "More words")
    }

    func testInsertionUsesTheLiveCaretNotAnEarlierOne() {
        // Recording started with the caret at 0. He then moved to the end and typed.
        let field = "Hello. Edited by me."
        let liveEnd = NSRange(location: (field as NSString).length, length: 0)
        let atStart = CursorPaster.resolvedInsertion("Dictated", field: field,
                                                     selection: NSRange(location: 0, length: 0),
                                                     preFormatted: false, bundleID: "com.apple.TextEdit")
        let atEnd = CursorPaster.resolvedInsertion("Dictated", field: field, selection: liveEnd,
                                                   preFormatted: false, bundleID: "com.apple.TextEdit")
        XCTAssertFalse(atStart.hasPrefix(" "), "the live start of the field has nothing before the caret")
        XCTAssertTrue(atEnd.hasPrefix(" "), "the live end of the field needs its own spacing")
        XCTAssertNotEqual(atStart, atEnd)
    }
}
