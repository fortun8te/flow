import XCTest
@testable import Voice

final class PasteReadbackTests: XCTestCase {
    private func look(_ value: String?, caret: NSRange?, same: Bool = true) -> PasteFieldLook {
        PasteFieldLook(value: value, caret: caret, sameTarget: same)
    }

    // MARK: - Verdicts

    func testExactEditWithCaretAfterInsertionIsVerified() {
        // "Hello " + "world" inserted at the caret (location 6)
        let before = look("Hello ", caret: NSRange(location: 6, length: 0))
        let after = look("Hello world", caret: NSRange(location: 11, length: 0))
        XCTAssertEqual(PasteReadback.verdict(before: before, after: after, inserted: "world",
                                             replacing: NSRange(location: 6, length: 0)), .verified)
    }

    func testReplacedSelectionIsVerifiedWhenExactlyEdited() {
        // "one two three", "two" selected (4..<7), replaced by "2"
        let before = look("one two three", caret: NSRange(location: 4, length: 3))
        let after = look("one 2 three", caret: NSRange(location: 5, length: 0))
        XCTAssertEqual(PasteReadback.verdict(before: before, after: after, inserted: "2",
                                             replacing: NSRange(location: 4, length: 3)), .verified)
    }

    func testUnchangedTextAndCaretIsNotLanded() {
        let before = look("Hello ", caret: NSRange(location: 6, length: 0))
        let after = look("Hello ", caret: NSRange(location: 6, length: 0))
        XCTAssertEqual(PasteReadback.verdict(before: before, after: after, inserted: "world",
                                             replacing: NSRange(location: 6, length: 0)), .notLanded)
    }

    func testChangedTextThatIsNotOurEditIsUnknown() {
        // The user typed something else in between: never a reason to paste again.
        let before = look("Hello ", caret: NSRange(location: 6, length: 0))
        let after = look("Hello x", caret: NSRange(location: 7, length: 0))
        XCTAssertEqual(PasteReadback.verdict(before: before, after: after, inserted: "world",
                                             replacing: NSRange(location: 6, length: 0)), .unknown)
    }

    func testCaretMovedWithoutTextChangeIsUnknown() {
        let before = look("Hello ", caret: NSRange(location: 6, length: 0))
        let after = look("Hello ", caret: NSRange(location: 2, length: 0))
        XCTAssertEqual(PasteReadback.verdict(before: before, after: after, inserted: "world",
                                             replacing: NSRange(location: 6, length: 0)), .unknown)
    }

    func testNoReadableTextIsUnknownBeforeOrAfter() {
        let caret = NSRange(location: 0, length: 0)
        XCTAssertEqual(PasteReadback.verdict(before: look(nil, caret: caret), after: look("x", caret: caret),
                                             inserted: "x", replacing: caret), .unknown)
        XCTAssertEqual(PasteReadback.verdict(before: look("", caret: caret), after: look(nil, caret: caret),
                                             inserted: "x", replacing: caret), .unknown)
    }

    func testNoReadableCaretIsUnknownEvenWhenTextMatches() {
        // Electron-style fields that expose text but not the selection never prove or disprove.
        XCTAssertEqual(PasteReadback.verdict(before: look("", caret: nil), after: look("", caret: nil),
                                             inserted: "x", replacing: nil), .unknown)
        XCTAssertEqual(PasteReadback.verdict(before: look("", caret: NSRange(location: 0, length: 0)),
                                             after: look("x", caret: nil),
                                             inserted: "x", replacing: nil), .unknown)
    }

    func testDifferentTargetIsUnknownEvenWhenTextIsUnchanged() {
        // Focus moved: the text may have landed elsewhere, so no fallback.
        let before = look("Hello ", caret: NSRange(location: 6, length: 0))
        let after = look("Hello ", caret: NSRange(location: 6, length: 0), same: false)
        XCTAssertEqual(PasteReadback.verdict(before: before, after: after, inserted: "world",
                                             replacing: NSRange(location: 6, length: 0)), .unknown)
    }

    func testEmptyInsertionIsUnknown() {
        let caret = NSRange(location: 0, length: 0)
        XCTAssertEqual(PasteReadback.verdict(before: look("", caret: caret), after: look("", caret: caret),
                                             inserted: "", replacing: caret), .unknown)
    }

    func testUTF16OffsetsWithEmojiAreExact() {
        // "😀 " is 3 UTF-16 units; the insertion sits after it.
        let before = look("😀 ", caret: NSRange(location: 3, length: 0))
        let after = look("😀 hi", caret: NSRange(location: 5, length: 0))
        XCTAssertEqual(PasteReadback.verdict(before: before, after: after, inserted: "hi",
                                             replacing: NSRange(location: 3, length: 0)), .verified)
    }

    func testCanonicallyEquivalentTextIsNotTreatedAsOurEdit() {
        // "é" composed vs decomposed is not the exact edit (matches TrailingPressEnter's rule).
        let before = look("", caret: NSRange(location: 0, length: 0))
        let after = look("e\u{301}", caret: NSRange(location: 2, length: 0))
        XCTAssertEqual(PasteReadback.verdict(before: before, after: after, inserted: "é",
                                             replacing: NSRange(location: 0, length: 0)), .unknown)
    }

    // MARK: - Steps: one look, two looks, one fallback, never twice

    func testVerifiedFinishesWithoutAnotherLook() {
        XCTAssertEqual(PasteReadback.nextStep(verdict: .verified, firstVerdict: nil, canType: true),
                       .finish(.verified))
    }

    func testTransientUnknownCanBeVerifiedOnTheSecondLook() {
        let before = look("Hello ", caret: NSRange(location: 6, length: 0))
        let early = look(nil, caret: nil)
        let settled = look("Hello world", caret: NSRange(location: 11, length: 0))
        let first = PasteReadback.verdict(before: before, after: early, inserted: "world", replacing: nil)
        let second = PasteReadback.verdict(before: before, after: settled, inserted: "world", replacing: nil)
        XCTAssertEqual(PasteReadback.nextStep(verdict: first, firstVerdict: nil, canType: true), .lookAgain)
        XCTAssertEqual(PasteReadback.nextStep(verdict: second, firstVerdict: first, canType: true), .finish(.verified))
    }

    func testUncertainReadsNeverAuthorizeAnotherInsertion() {
        for (first, second) in [(PasteVerdict.unknown, PasteVerdict.unknown),
                                (.notLanded, .unknown)] {
            XCTAssertEqual(PasteReadback.nextStep(verdict: second, firstVerdict: first, canType: true),
                           .finish(.unknown))
        }
    }

    func testFirstNotLandedLookWaitsForTheSecond() {
        XCTAssertEqual(PasteReadback.nextStep(verdict: .notLanded, firstVerdict: nil, canType: true), .lookAgain)
    }

    func testTwoConfirmedMissesCanTypeOnce() {
        XCTAssertEqual(PasteReadback.nextStep(verdict: .notLanded, firstVerdict: .notLanded, canType: true), .typeOnce)
    }

    func testConfirmedMissesWithoutTypingEligibilityFinishWithoutTyping() {
        XCTAssertEqual(PasteReadback.nextStep(verdict: .notLanded, firstVerdict: .notLanded, canType: false),
                       .finish(.notLanded))
    }

    func testReadableMissAfterInconclusiveLookKeepsRecoveryWithoutTyping() {
        let step = PasteReadback.nextStep(verdict: .notLanded, firstVerdict: .unknown, canType: true)
        XCTAssertEqual(step, .finish(.notLanded))
    }

    // MARK: - Copied notice: only likely failures

    func testTheReadbackWindowEndsWithinThreeHundredMilliseconds() {
        XCTAssertLessThanOrEqual(PasteReadback.secondLookDelay, 0.3)
        XCTAssertLessThan(PasteReadback.firstLookDelay, PasteReadback.secondLookDelay)
    }

    private func notice(_ verdict: PasteVerdict, typed: Bool = false, editable: Bool = true,
                        focusAway: Bool = false, verifiedBefore: Bool = false) -> Bool {
        PasteReadback.needsCopiedNotice(final: verdict, typed: typed, editableAtPaste: editable,
                                        focusAway: focusAway, appVerifiedBefore: verifiedBefore)
    }

    func testVerifiedPasteShowsNoNotice() {
        XCTAssertFalse(notice(.verified))
        XCTAssertFalse(notice(.verified, verifiedBefore: true))
    }

    func testUnknownInAnAppThatNeverGaveAReadbackIsTrustedWhenEditable() {
        XCTAssertFalse(notice(.unknown, editable: true, verifiedBefore: false))
    }

    func testUnknownInAnAppWhoseReadbackHasVerifiedBeforeIsALikelyFailure() {
        XCTAssertTrue(notice(.unknown, editable: true, verifiedBefore: true))
    }

    func testNoEditableElementAtPasteTimeShowsTheNotice() {
        XCTAssertTrue(notice(.unknown, editable: false, verifiedBefore: false))
        XCTAssertTrue(notice(.unknown, editable: false, verifiedBefore: true))
    }

    func testFocusMovingAwayShowsTheNotice() {
        XCTAssertTrue(notice(.unknown, focusAway: true))
        XCTAssertTrue(notice(.notLanded, focusAway: true))
    }

    func testNotLandedShowsTheNotice() {
        XCTAssertTrue(notice(.notLanded))
    }

    func testATypedInsertionThatWentInShowsNoNotice() {
        XCTAssertFalse(notice(.unknown, typed: true, verifiedBefore: true))
    }

    func testUnknownOnBothLooksFinishesUnknown() {
        XCTAssertEqual(PasteReadback.nextStep(verdict: .unknown, firstVerdict: .unknown, canType: true),
                       .finish(.unknown))
    }

    func testAFieldThatNeverReportsTheTextIsUnknownNotVerified() {
        let before = look("Hello ", caret: NSRange(location: 6, length: 0))
        let noField = PasteFieldLook(value: nil, caret: nil, sameTarget: false)
        XCTAssertEqual(PasteReadback.verdict(before: before, after: noField, inserted: "world", replacing: nil), .unknown)
    }

    // MARK: - Per-app memory of verified readbacks

    func testAnAppIsRememberedOnlyAfterAVerifiedPaste() {
        let suite = "PasteReadbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(PasteReadback.appHasVerified(bundleID: "com.example.notes", defaults: defaults))
        PasteReadback.recordVerified(bundleID: "com.example.notes", defaults: defaults)
        PasteReadback.recordVerified(bundleID: "com.example.notes", defaults: defaults)
        XCTAssertTrue(PasteReadback.appHasVerified(bundleID: "com.example.notes", defaults: defaults))
        XCTAssertFalse(PasteReadback.appHasVerified(bundleID: "com.example.electron", defaults: defaults))
        XCTAssertFalse(PasteReadback.appHasVerified(bundleID: nil, defaults: defaults))
    }

    // MARK: - Typing eligibility and chunks

    func testNewlinesAndTabsAreNeverTyped() {
        XCTAssertFalse(PasteReadback.canType("line one\nline two"))
        XCTAssertFalse(PasteReadback.canType("col\tcol"))
        XCTAssertFalse(PasteReadback.canType("a\r\nb"))
        XCTAssertFalse(PasteReadback.canType("a\u{2028}b"))
    }

    func testEmptyAndLongInsertionsAreNotTyped() {
        XCTAssertFalse(PasteReadback.canType(""))
        XCTAssertFalse(PasteReadback.canType(String(repeating: "a", count: PasteReadback.maxTypedUnits + 1)))
        XCTAssertTrue(PasteReadback.canType("Short sentence, typed."))
        XCTAssertTrue(PasteReadback.canType(String(repeating: "a", count: PasteReadback.maxTypedUnits)))
    }

    func testTypingChunksRebuildTheTextExactly() {
        let text = "Hello 😀 wörld, this is a longer line of dictated text with 👩🏽‍💻 emoji."
        let chunks = PasteReadback.typingChunks(text, maxUnits: 20)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.utf16.count, 20)
        }
    }

    func testTypingChunksNeverSplitACharacter() {
        // A family emoji is one Character made of many scalars; it must stay whole.
        let family = "👨‍👩‍👧‍👦"
        let chunks = PasteReadback.typingChunks(String(repeating: "x", count: 19) + family + "y")
        XCTAssertTrue(chunks.contains { $0.contains(family) })
        XCTAssertEqual(chunks.joined(), String(repeating: "x", count: 19) + family + "y")
    }

    func testTypingChunksEmptyText() {
        XCTAssertEqual(PasteReadback.typingChunks(""), [])
    }
}
