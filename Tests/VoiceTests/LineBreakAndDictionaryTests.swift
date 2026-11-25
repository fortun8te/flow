import XCTest
@testable import Voice

/// Line breaks, lists and the dictionary (22 Nov 2026: "It still really doesn't do proper line breaks").
final class LineBreakAndDictionaryTests: XCTestCase {
    private func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    // MARK: Readable paragraphs

    func testMediumDictationBecomesShortParagraphs() {
        let a = "The new bridge has a wider railing than the old one, which gives cyclists more room when they meet near the bend."
        let b = "Also, the museum opens at nine on Saturdays, and the clerk will have printed maps ready beside the front door."
        let out = DictationParagraphs.formatDictation(a + " " + b)
        XCTAssertEqual(out, a + "\n\n" + b)
    }

    func testLongDictationSplitsIntoSeveralParagraphsAndKeepsEveryWord() {
        let input = """
        The library opens two hours early on Saturday. A volunteer will count the returned books before anyone enters. \
        A sign near the desk explains where to leave damaged covers, and a basket holds loose bookmarks. \
        The reading room upstairs has six tables, with a chess board near the window. In the afternoon the garden \
        club meets behind the library. They plan to sketch the old pear tree and count the empty beds. \
        Because the paths get muddy after rain, visitors should bring boots and avoid the patch near the gate.
        """
        let out = DictationParagraphs.formatDictation(input)
        let paragraphs = out.components(separatedBy: "\n\n")
        XCTAssertGreaterThanOrEqual(paragraphs.count, 2)
        XCTAssertLessThanOrEqual(paragraphs.count, 4)
        XCTAssertEqual(words(out), words(input))
        // A sentence that carries on the last one never opens a paragraph.
        XCTAssertFalse(paragraphs.contains { $0.hasPrefix("Because") })
        XCTAssertTrue(paragraphs.allSatisfy { words($0).count >= 10 })
    }

    func testShortMessagesStayOneLine() {
        for text in ["Just refine it even more.",
                     "Make sure it works. Also, ship it. Then tell me.",
                     "Also, the red door sticks during the winter. Try the side entrance.",
                     "The first one is better than the second one, I think."] {
            XCTAssertEqual(DictationParagraphs.formatDictation(text), text)
        }
    }

    func testThirtyWordsWithoutATopicChangeStayOneParagraph() {
        let text = "The small brass latch sticks whenever the wood swells in damp weather. The hinge on the far side of the same gate sticks in damp weather too."
        XCTAssertEqual(DictationParagraphs.formatDictation(text), text)
    }

    func testEnumerationWithLeadInBecomesAList() {
        let input = "There are three things I want you to fix today. First, the Routines page. Second, the meetings tab. Third, the storage view."
        XCTAssertEqual(DictationParagraphs.formatDictation(input),
                       "There are three things I want you to fix today.\n\n1. The Routines page.\n2. The meetings tab.\n3. The storage view.")
    }

    // MARK: Formatter

    func testTabIsAWordNotAKey() {
        let out = TextFormatter().format("the meetings tab is empty and the voice tab looks fine")
        XCTAssertTrue(out.contains("meetings tab is empty"), out)
        XCTAssertTrue(out.contains("voice tab looks fine"), out)
    }

    func testNewLineCommandKeepsItsBreakAfterAFullStop() {
        XCTAssertEqual(TextFormatter().format("Make the pill smaller. New line. Make the card wider."),
                       "Make the pill smaller.\nMake the card wider.")
        XCTAssertEqual(TextFormatter().format("Hey Noor new line can you send me the file new line thanks"),
                       "Hey Noor\nCan you send me the file\nThanks.")
    }

    func testSpokenAndBeforeTheLastMarkerStaysOutOfTheItem() {
        let out = TextFormatter().format("First, check the logs. Second, restart Flow and see if it comes back. And third, tell me what broke.")
        XCTAssertFalse(out.contains(" And\n"), out)
        XCTAssertFalse(out.hasSuffix("And"), out)
        XCTAssertTrue(out.contains("2. Restart Flow and see if it comes back\n3. Tell me what broke"), out)
    }

    func testAtHomeAtASentenceEndIsNotAnEmail() {
        XCTAssertEqual(TextFormatter().format("we ran out of everything at home. So I went out"),
                       "We ran out of everything at home. So I went out.")
    }

    func testFormatterDoesNotBreakAShortMessage() {
        XCTAssertFalse(TextFormatter().format("That was strange. Anyway, here's the news.").contains("\n"))
        XCTAssertFalse(TextFormatter().format("It works now. Also, make the pill smaller.").contains("\n"))
    }

    // MARK: Opt+1 layout

    func testOptOneLaysOutOneLongBlock() {
        let a = "I found a spare coil of copper wire in the shed behind the orchard. The coil has a paper label on it."
        let b = "But the end of the wire has a rough edge. Please file that edge before you thread it through the hole."
        let c = "Also, the greenhouse vents need a new handle, so ask the hardware shop if they have a spare."
        let source = [a, b, c].joined(separator: " ")
        let out = OptOneLayout.apply(source: source, edited: source)
        XCTAssertTrue(out.contains("\n\n"), out)
        XCTAssertEqual(words(out), words(source))
    }

    func testOptOneKeepsHisOwnLayoutAndShortText() {
        let typed = "stuff to fix:\n- the pill\n- the dictionary"
        XCTAssertEqual(OptOneLayout.apply(source: typed, edited: typed), typed)
        let short = "Ok so can you check if the ferry takes bicycles?"
        XCTAssertEqual(OptOneLayout.apply(source: short, edited: short), short)
        let code = String(repeating: "let a = b; let c = d; call it { x } and more words here ", count: 4)
        XCTAssertEqual(OptOneLayout.apply(source: code, edited: code), code)
    }

    func testOptOneTurnsATypedEnumerationIntoAList() {
        let source = "So I looked at the pill again and there are a few things that still bother me. First, it is too wide on the side monitor. Second, the text wraps weirdly. Third, the card overlaps the menu bar."
        let out = OptOneLayout.apply(source: source, edited: source)
        XCTAssertTrue(out.contains("\n\n1. It is too wide on the side monitor.\n2. The text wraps weirdly.\n3. The card overlaps the menu bar."), out)
    }

    // MARK: Dictionary

    func testHeardNamesUsePublicProductSpellings() {
        let fix = ProperNounVocabulary.applyHeardNameFixes
        XCTAssertEqual(fix("Open Quen and Clod Code."), "Open Qwen and Claude Code.")
        XCTAssertEqual(fix("I use Whisper Flow."), "I use Wispr Flow.")
    }

    func testHeardNameFixesLeaveOrdinaryWordsAndLinksAlone() {
        let fix = ProperNounVocabulary.applyHeardNameFixes
        for text in ["it's in the cloud", "a dolly shot on set", "I whisper flowers", "see https://x.com/quen now",
                     "the codecs are fine", "Kira said hi", "a super application", "mail quen@example.com"] {
            XCTAssertEqual(fix(text), text)
        }
    }

    func testDictationSpellingPassAppliesHeardNames() {
        XCTAssertEqual(ProperNounVocabulary.applyPreferredSpelling("ask Quen about Whisper Flow", terms: ["Wispr Flow"]),
                       "ask Qwen about Wispr Flow")
    }

    func testOptOneSnapsHeardAndTypedNames() {
        XCTAssertEqual(TypoRepair.shared.snapVocabulary("can qwen run on whisper flow in t3 code"),
                       "can Qwen run on Wispr Flow in T3 Code")
    }

    func testExampleTypoEntriesApply() {
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("Set the metronmoe beside the telesopce.",
                                                          dictionary: TypoRepair.personalDictionary),
                       "Set the metronome beside the telescope.")
    }

    // MARK: Fillers still go, unless they are the subject

    func testFillersStillRemovedAfterLayoutAndKeptWhenTalkedAbout() {
        let spoken = "Um, so the pill is better now. Uh, I think the dictionary works, um, but I'm not sure yet, so please check it again tomorrow and tell me what you find."
        let out = DictationParagraphs.formatDictation(DictationFinalPass.apply(spoken))
        XCTAssertNil(out.range(of: #"(?i)\b(um|uh)\b"#, options: .regularExpression), out)
        let mention = "If I'm talking about ums and uhs, they have to stay, and the word um too."
        XCTAssertEqual(DictationParagraphs.formatDictation(DictationFinalPass.apply(mention)), mention)
    }
}
