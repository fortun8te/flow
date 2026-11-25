import AppKit
import XCTest
@testable import Voice

/// Opt+1 in Chrome / Electron / web fields: Accessibility gives no selected text, so Flow asks the
/// app to copy. These tests drive the copy helper against a private pasteboard.
/// Evidence: events.jsonl 2026-11-21T15:05:04Z "Couldn’t read selected text. Select text to polish."
final class SelectionCopyFallbackTests: XCTestCase {
    private var pb: NSPasteboard!

    override func setUp() {
        pb = NSPasteboard(name: NSPasteboard.Name("flow-test-\(UUID().uuidString)"))
        pb.clearContents()
    }

    override func tearDown() { pb.releaseGlobally() }

    private let custom = NSPasteboard.PasteboardType("com.example.private-flavour")

    private func seedUserClipboard() {
        let first = NSPasteboardItem()
        first.setString("user text", forType: .string)
        first.setData(Data([1, 2, 3]), forType: custom)
        let second = NSPasteboardItem()
        second.setString("<b>rich</b>", forType: .html)
        pb.clearContents()
        pb.writeObjects([first, second])
    }

    func testCopiedSelectionIsReadAndEveryItemAndTypeIsRestored() throws {
        seedUserClipboard()
        let before = try XCTUnwrap(CursorPaster.snapshotPasteboard(pb))
        let text = CursorPaster.copySelectionText(pasteboard: pb, prior: before, settle: 0, sendCopy: {
            self.pb.clearContents()
            self.pb.setString("make it even better", forType: .string)
            return true
        })
        XCTAssertEqual(text, "make it even better")
        XCTAssertEqual(CursorPaster.snapshotPasteboard(pb), before)
        XCTAssertEqual(pb.pasteboardItems?.count, 2)
        XCTAssertEqual(pb.pasteboardItems?.first?.data(forType: custom), Data([1, 2, 3]))
    }

    func testChromiumTwoStepWriteStillCounts() throws {
        seedUserClipboard()
        let before = try XCTUnwrap(CursorPaster.snapshotPasteboard(pb))
        let text = CursorPaster.copySelectionText(pasteboard: pb, prior: before, settle: 0, sendCopy: {
            self.pb.clearContents()
            self.pb.clearContents()
            self.pb.setString("selected words", forType: .string)
            return true
        })
        XCTAssertEqual(text, "selected words")
        XCTAssertEqual(CursorPaster.snapshotPasteboard(pb), before)
    }

    func testNothingCopiedLeavesClipboardUntouchedAndReturnsNil() throws {
        seedUserClipboard()
        let before = try XCTUnwrap(CursorPaster.snapshotPasteboard(pb))
        let count = pb.changeCount
        let text = CursorPaster.copySelectionText(pasteboard: pb, prior: before, timeout: 0.05, settle: 0,
                                                  sendCopy: { true })
        XCTAssertNil(text)
        XCTAssertEqual(pb.changeCount, count)
        XCTAssertEqual(CursorPaster.snapshotPasteboard(pb), before)
    }

    func testWhitespaceOrScopeChangeGivesNilButStillRestores() throws {
        seedUserClipboard()
        let before = try XCTUnwrap(CursorPaster.snapshotPasteboard(pb))
        let blank = CursorPaster.copySelectionText(pasteboard: pb, prior: before, settle: 0, sendCopy: {
            self.pb.clearContents(); self.pb.setString("  \n", forType: .string); return true
        })
        XCTAssertNil(blank)
        XCTAssertEqual(CursorPaster.snapshotPasteboard(pb), before)

        let moved = CursorPaster.copySelectionText(pasteboard: pb, prior: before, settle: 0, sendCopy: {
            self.pb.clearContents(); self.pb.setString("words", forType: .string); return true
        }, stillInScope: { false })
        XCTAssertNil(moved)
        XCTAssertEqual(CursorPaster.snapshotPasteboard(pb), before)
    }

    func testEmptyUserClipboardIsRestoredEmpty() throws {
        let before = try XCTUnwrap(CursorPaster.snapshotPasteboard(pb))
        let text = CursorPaster.copySelectionText(pasteboard: pb, prior: before, settle: 0, sendCopy: {
            self.pb.clearContents(); self.pb.setString("hi there", forType: .string); return true
        })
        XCTAssertEqual(text, "hi there")
        XCTAssertNil(pb.string(forType: .string))
    }

    func testRefusedCopyReturnsNil() throws {
        seedUserClipboard()
        let before = try XCTUnwrap(CursorPaster.snapshotPasteboard(pb))
        XCTAssertNil(CursorPaster.copySelectionText(pasteboard: pb, prior: before, sendCopy: { false }))
    }

    func testReReadMatchIgnoresLineEndingsOnly() {
        XCTAssertTrue(CursorPaster.sameSelectionText("one\r\ntwo\n", "one\ntwo"))
        XCTAssertFalse(CursorPaster.sameSelectionText("one two", "one  two"))
        XCTAssertFalse(CursorPaster.sameSelectionText("one two", "one"))
    }

    func testCopyOnlySelectionNeverPastesWithoutTheSameApp() {
        let target = CursorPaster.PasteTargetSnapshot(bundleId: "com.google.Chrome", focusedElement: nil)
        let selection = CursorPaster.SelectionSnapshot(target: target, text: "world", fullText: "",
                                                       range: CFRange(location: -1, length: 0), viaCopy: true,
                                                       method: "cmd_c", pid: -42)
        XCTAssertFalse(CursorPaster().replaceUnverifiedSelection(with: "World", expected: selection))
    }
}
