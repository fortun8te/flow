import XCTest
@testable import Voice

final class SelectionSafetyTests: XCTestCase {
    func testCopyOnlySelectionCannotAuthorizeAReplacement() {
        let target = CursorPaster.PasteTargetSnapshot(bundleId: "test.editor", focusedElement: nil)
        let range = CFRange(location: 6, length: 5)
        var selection = CursorPaster.SelectionSnapshot(target: target, text: "world", fullText: "hello world", range: range)
        XCTAssertEqual(selection.expectedFullText(replacingWith: "Flow"), "hello Flow")
        selection.viaCopy = true
        XCTAssertNil(selection.expectedFullText(replacingWith: "Flow"))
        XCTAssertFalse(CursorPaster().replaceSelection(with: "Flow", expected: selection))
    }

    func testSelectionMustKeepTextAndRange() {
        let original = CFRange(location: 6, length: 5)
        func matches(_ full: String, _ range: CFRange, _ selection: String) -> Bool {
            CursorPaster.selectionMatches(originalText: "hello world", currentText: full,
                originalRange: original, currentRange: range,
                originalSelection: "world", currentSelection: selection)
        }
        XCTAssertTrue(matches("hello world", original, "world"))
        XCTAssertFalse(matches("hello world!", original, "world"))
        XCTAssertFalse(matches("hello world", CFRange(location: 0, length: 5), "world"))
        XCTAssertFalse(matches("hello world", CFRange(location: 6, length: 0), ""))
        XCTAssertFalse(matches("hello world", original, "other"))
    }
}
