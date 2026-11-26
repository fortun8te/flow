import XCTest
@testable import Voice

// List items are capitalised as Wispr writes them (21 Nov 2026).
final class DictationLayoutTests: XCTestCase {
    func testExplicitListPreservesItemTextAndProtectedDetails() {
        let input = "Three things. First, check v2.1. Second, keep https://example.com/brief. Third, ask Noor."
        XCTAssertEqual(
            DictationParagraphs.formatDictation(input),
            "Three things.\n\n1. Check v2.1.\n2. Keep https://example.com/brief.\n3. Ask Noor."
        )
    }

    func testExplicitListSupportsTwoItemsAndDutchMarkers() {
        XCTAssertEqual(
            DictationParagraphs.formatDictation("Twee punten. Eerste, stuur de notities. Tweede, laat de link staan."),
            "Twee punten.\n\n1. Stuur de notities.\n2. Laat de link staan."
        )
        XCTAssertEqual(
            DictationParagraphs.formatDictation("Number one keep the draft number two call Kai"),
            "1. Keep the draft\n2. Call Kai"
        )
    }

    func testDifferentTopicSplitsAnOrdinaryLengthDictation() {
        let first = "Please keep the existing booking for Thursday and send me the confirmation once the office opens."
        let second = "Separately, please ask Noor whether the draft is ready and tell me what she says."
        let input = first + " " + second
        XCTAssertEqual(DictationParagraphs.formatDictation(input), first + "\n\n" + second)
        XCTAssertEqual(DictationParagraphs.format(input), input)
    }

    func testShortTopicShiftDoesNotIsolateATinyFirstParagraph() {
        let input = "Done. On another note, please check the blue gate near the old barn before you leave for the station and bring the spare key back tomorrow."
        XCTAssertGreaterThanOrEqual(input.split(whereSeparator: \.isWhitespace).count, 25)
        XCTAssertLessThan(input.split(whereSeparator: \.isWhitespace).count, 40)
        XCTAssertEqual(DictationParagraphs.formatDictation(input), input)
    }

    func testProseAndExistingLayoutAreKept() {
        let passages = [
            "Item number one is at the back and number two is on the shelf.",
            "First of all, ask Noor if this works. The second time might be easier.",
            "Task 2. Tell Noor. Task 3. Ask Kai.",
            "First, check the file. Third, keep a copy.",
            "1. Check the list.\n2. Save a copy.",
            "Already formatted.\n\nLeave this paragraph alone."
        ]
        for passage in passages {
            XCTAssertEqual(DictationParagraphs.formatDictation(passage), passage)
        }
    }

    func testCountedListKeepsNamesAndQuantities() {
        let input = "Give me three tasks: send $1,000 to Noor, check the budget, and keep the original v2.1."
        XCTAssertEqual(
            DictationParagraphs.formatDictation(input),
            "Give me three tasks:\n\n1. Send $1,000 to Noor\n2. Check the budget\n3. Keep the original v2.1."
        )
        let ambiguous = "There were three things: a red pen, a blue pen."
        XCTAssertEqual(DictationParagraphs.formatDictation(ambiguous), ambiguous)
    }

    func testCountedSpokenListWithoutPunctuationAfterOrdinals() {
        XCTAssertEqual(
            DictationParagraphs.formatDictation("Three things: first send $1,000 to Noor second check v2.1 third keep the spare key."),
            "Three things:\n\n1. Send $1,000 to Noor\n2. Check v2.1\n3. Keep the spare key."
        )
        XCTAssertEqual(
            DictationParagraphs.formatDictation("Twee punten: ten eerste stuur de notities ten tweede laat de link staan."),
            "Twee punten:\n\n1. Stuur de notities\n2. Laat de link staan."
        )
        let ambiguous = "Two things: first read the second paragraph second save the draft."
        XCTAssertEqual(DictationParagraphs.formatDictation(ambiguous), ambiguous)
    }

    func testEmailLayoutKeepsGreetingBodyAndSignoff() {
        let input = "Hi Carlos, can you confirm invoice #8841? Thanks."
        XCTAssertEqual(DictationParagraphs.formatDictation(input), input)
        XCTAssertEqual(
            DictationParagraphs.formatDictation(input, isEmail: true),
            "Hi Carlos,\n\ncan you confirm invoice #8841?\n\nThanks."
        )
        XCTAssertEqual(DictationParagraphs.formatDictation("Hey, thanks.", isEmail: true), "Hey,\n\nthanks.")
    }

    func testExistingLineBreaksDoNotDisableLayoutOfLaterProse() {
        let first = "Bewaar de bestaande afspraak voor donderdag en stuur me de bevestiging zodra het kantoor open is."
        let second = "Los daarvan, vraag Noor even of de eerste versie van het document inmiddels klaar is."
        let prefix = "Een korte inleiding.\r\n\r\n"
        XCTAssertEqual(DictationParagraphs.formatDictation(prefix + first + " " + second),
                       prefix + first + "\n\n" + second)
        let structured = "1. First, keep the draft. Second, check the link.\n"
            + "~~~\nThree things: a, b and c.\n~~~\n"
            + "   Three things: a, b and c."
        XCTAssertEqual(DictationParagraphs.formatDictation(structured), structured)
    }

    func testShorterInnerFencesDoNotExposeCodeToListFormatting() {
        let literal = "First, keep this literal. Second, keep this literal too."
        for (opening, inner, closing) in [("````markdown", "```", "````"), ("~~~~text", "~~~", "~~~~")] {
            let source = [opening, inner, literal, inner, closing].joined(separator: "\n")
            XCTAssertEqual(DictationParagraphs.formatDictation(source), source)
        }
    }

    func testFenceCloserMustHaveNoTrailingContentAndRealCloserRestoresLayout() {
        let literal = "First, keep this literal. Second, keep this literal too."
        let fenced = ["```text", "```still-code", literal, "````   "].joined(separator: "\n")
        let outside = "First, check the gate. Second, call the station."
        XCTAssertEqual(DictationParagraphs.formatDictation(fenced + "\n" + outside),
                       fenced + "\n1. Check the gate.\n2. Call the station.")
    }

    func testCountedListsWithoutOxfordCommaKeepNamesNumbersAndLineBreaks() {
        let english = "Next up.\nThree tasks: send $1,000 to Noor, check v2.1 and keep the original."
        XCTAssertEqual(DictationParagraphs.formatDictation(english),
                       "Next up.\nThree tasks:\n\n1. Send $1,000 to Noor\n2. Check v2.1\n3. Keep the original.")
        let dutch = "Drie stappen: stuur Noor €1.000, controleer v2.1 en bewaar de link."
        XCTAssertEqual(DictationParagraphs.formatDictation(dutch),
                       "Drie stappen:\n\n1. Stuur Noor €1.000\n2. Controleer v2.1\n3. Bewaar de link.")
        for prose in [
            "I left number one on page 2. Number two is on page 3.",
            "Drie taken: stuur Noor, controleer de versie en prijs en bewaar de link.",
            "Three things: one folder, and a link."
        ] {
            XCTAssertEqual(DictationParagraphs.formatDictation(prose), prose)
        }
    }
}
