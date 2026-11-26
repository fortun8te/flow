import Foundation
import XCTest
@testable import Voice

final class TextFormatterLineBreakTests: XCTestCase {
    private func formatter(paragraphs: Bool = true, commands: Bool = true) -> TextFormatter {
        var config = TextFormatterConfig()
        config.detectParagraphs = paragraphs
        config.interpretVoiceCommands = commands
        return TextFormatter(config: config)
    }

    func testFillerAtEndOfLineDoesNotConsumeTheBreak() {
        XCTAssertEqual(formatter().format("Check the gate um\nCall the station"),
                       "Check the gate\nCall the station.")
        XCTAssertEqual(formatter().format("Check the gate um new line call the station"),
                       "Check the gate\nCall the station.")
    }

    func testFillerOnlyLineKeepsBothRequestedBreaks() {
        XCTAssertEqual(formatter().format("Check the gate new line um new line call the station"),
                       "Check the gate\n\nCall the station.")
    }

    func testLeadingPunctuationDoesNotPullTheNextLineUp() {
        XCTAssertEqual(formatter().format("Check the gate.\n, Call the station."),
                       "Check the gate.\n, Call the station.")
    }

    func testLongPassageKeepsEveryExistingSingleLineBreak() {
        let sentence = "The gardener put the wooden box beside the door before she went around the side to check the loose gate."
        let source = Array(repeating: sentence, count: 7).joined(separator: "\n")
        XCTAssertEqual(formatter().format(source), source)
    }

    func testDisabledParagraphDetectionAppliesToLongAndMediumTimedGaps() {
        let f = formatter(paragraphs: false)
        XCTAssertEqual(f.formatSegments([("Please put it", 0, 1), ("on the desk", 3, 4)]),
                       "Please put it on the desk.")
        XCTAssertEqual(f.formatSegments([("Bring the notes;", 0, 1), ("Call the station", 2, 3)]),
                       "Bring the notes; Call the station.")
    }

    func testDisabledParagraphDetectionAppliesToAutomaticTextPasses() {
        let first = "I went to the store this morning before work because we ran out of almost everything we need at home, again."
        let second = "Anyway, I bought milk, eggs, bread and coffee, and then I walked back the long way through the park with the dog."
        let f = formatter(paragraphs: false)
        XCTAssertFalse(f.format(first + " " + second).contains("\n"))
        XCTAssertFalse(f.format(Array(repeating: first, count: 7).joined(separator: " ")).contains("\n"))
        XCTAssertFalse(f.format("Dear Noor I hope your trip went well").contains("\n"))
    }

    func testExplicitBreaksStillWorkWhenAutomaticParagraphsAreDisabled() {
        XCTAssertEqual(formatter(paragraphs: false).format("Check the gate new paragraph call the station"),
                       "Check the gate\n\nCall the station.")
    }

    func testDisabledCommandsLeaveSpokenLayoutWordsAlone() {
        let output = formatter(paragraphs: false, commands: false).format("Check the gate new line call the station")
        XCTAssertTrue(output.contains("new line"), output)
        XCTAssertFalse(output.contains("\n"), output)
    }

    func testStandaloneAndBoundaryCommandsSurviveFormatting() {
        let cases = [
            ("new line", "\n"), ("new paragraph", "\n\n"),
            ("next paragraph", "\n\n"), ("line break", "\n"),
            ("New line!", "\n"), ("Next line.", "\n"),
            ("new line hello", "\nHello."), ("hello new line", "Hello.\n"),
            ("new paragraph hello new paragraph", "\n\nHello.\n\n"),
            ("new line new line", "\n\n")
        ]
        for (source, expected) in cases {
            XCTAssertEqual(formatter().format(source), expected, source)
        }
    }

    func testExistingBoundaryNewlinesSurviveFormattingAndStayIdempotent() {
        for source in ["\nHello.\n", "\n\nHello.\n\n", "\n", "\n\n"] {
            let f = formatter()
            XCTAssertEqual(f.format(source), source)
            XCTAssertEqual(f.format(f.format(source)), source)
        }
    }

    func testRepeatedInternalCommandsKeepEveryRequestedBreak() {
        XCTAssertEqual(formatter().format("hello new line new line new line there"), "Hello\n\n\nThere.")
        let source = "Hello.\n\n\nThere."
        XCTAssertEqual(formatter().format(source), source)
        XCTAssertEqual(formatter().format(formatter().format(source)), source)
    }

    func testSharedCommandPassConsumesOnlyCommandPunctuation() {
        XCTAssertEqual(TextFormatter.interpretLineBreakCommands("Check the gate. New line. Call the station."),
                       "Check the gate.\nCall the station.")
        XCTAssertEqual(TextFormatter.interpretLineBreakCommands("Hello, new paragraph thanks."),
                       "Hello\n\nthanks.")
        XCTAssertEqual(TextFormatter.interpretLineBreakCommands("hello next\tline goodbye"),
                       "hello\ngoodbye")
    }

    func testSharedCommandPassPreservesQuotedAndCodeLiterals() {
        let cases = [
            "Keep \"new line\" in the guide", "Keep 'new line' in the guide",
            "Keep “new paragraph” in the guide", "Keep ‘next line’ in the guide",
            "Keep `new line` in the guide", "Keep ``new line`` in the guide", "```text\nnew paragraph\n```",
            "````text\n```\nnew line\n```\n````", "~~~~text\n~~~\nnew line\n~~~\n~~~~",
            "~~~text\nnext line\n~~~", "```\nnew line", "\"new line",
            "quote new line end quote", "open quote next paragraph close quote"
        ]
        for source in cases {
            XCTAssertEqual(TextFormatter.interpretLineBreakCommands(source), source)
        }
    }

    func testSharedCommandPassHandlesEscapedQuotesBeforeARealCommand() {
        let source = "Keep \"the \\\"new line command\" new line continue"
        XCTAssertEqual(TextFormatter.interpretLineBreakCommands(source),
                       "Keep \"the \\\"new line command\"\ncontinue")
    }

    func testSharedCommandPassPreservesMentionsAndWordBoundaries() {
        for source in ["Keep the new line command in the guide", "The phrase new paragraph should remain",
                       "Use a new line for each item", "The next line is a heading", "Say new line clearly",
                       "Keep a line break here", "The line break is missing", "The next paragraph needs work",
                       "A new lineage is recorded", "The new paragraphing behavior is good"] {
            XCTAssertEqual(TextFormatter.interpretLineBreakCommands(source), source)
        }
    }

    func testSharedCommandPassKeepsUnicodeAndItsOffsets() {
        XCTAssertEqual(TextFormatter.interpretLineBreakCommands("🙂 Check the café new line call Zoë"),
                       "🙂 Check the café\ncall Zoë")
    }

    func testNumberAndTimeConversionsCannotJoinSeparateLines() {
        let cases = [
            ("three\ntwo\none", "Three\nTwo\nOne."),
            ("fifty\npercent", "50\nPercent."),
            ("version two\npoint one", "Version two\nPoint one."),
            ("9\n30 PM", "9\n30 PM."),
            ("Keep twenty and\nthree", "Keep 20 and\nThree.")
        ]
        for (source, expected) in cases {
            XCTAssertEqual(formatter().format(source), expected, source)
        }
    }

    func testSingleLineNumberAndTimeConversionsStillWork() {
        for (source, expected) in [("three two one", "3, 2, 1."), ("fifty percent", "50%."),
                                   ("9 30 PM", "9:30 PM."), ("twenty three", "23.")] {
            XCTAssertEqual(formatter().format(source), expected, source)
        }
    }

    func testGreetingInferenceDoesNotRearrangeExistingLayout() {
        let source = "Hi Noor, Please check the logs.\n\nThanks."
        XCTAssertEqual(formatter().format(source), source)
    }

    func testTopicInferenceDoesNotUpgradeAnExplicitSingleBreak() {
        let first = "Check the old wooden gate beside the barn before we drive back to the village this evening and make sure the latch closes."
        let second = "Also check the new lock on the small blue door near the greenhouse before the sun sets and bring the spare key."
        XCTAssertEqual(formatter().format(first + "\n" + second), first + "\n" + second)
    }

    func testDeduplicationCannotDeleteRepeatedMaterialAcrossLines() {
        let f = formatter()
        for source in ["go\ngo go\ngo", "read\nnow we read\nnow we"] {
            let output = f.format(source)
            XCTAssertEqual(output.filter(\.isNewline).count, source.filter(\.isNewline).count, output)
            XCTAssertEqual(output.lowercased().filter(\.isLetter), source.lowercased().filter(\.isLetter), output)
        }
    }

    func testGeneratedBulletPaddingStillTrimsNormally() {
        XCTAssertEqual(formatter().format("bullet buy milk"), "- Buy milk.")
    }

    func testTimedSegmentsDoNotAddABreakBesideAnExistingOne() {
        let f = formatter()
        XCTAssertEqual(f.formatSegments([("Check the gate.\n", 0, 1), ("Call the station.", 3, 4)]),
                       "Check the gate.\nCall the station.")
        XCTAssertEqual(f.formatSegments([("Check the gate.", 0, 1), ("\nCall the station.", 3, 4)]),
                       "Check the gate.\nCall the station.")
        let padded = f.formatSegments([("Check the gate.\n ", 0, 1), ("Call the station.", 3, 4)])
        XCTAssertEqual(padded.filter(\.isNewline).count, 1, padded)
    }

    func testEmptyRecognitionWindowsDoNotInsertBlankParagraphs() {
        let f = formatter()
        XCTAssertEqual(f.formatSegments([(" ", 0, 1), ("Hello.", 3, 4), ("", 6, 7)]), "Hello.")
        XCTAssertEqual(f.formatSegments([("", 0, 1), (" ", 3, 4)]), "")
    }

    func testSpokenBoundaryAtEitherSideOfPauseOverridesTheInferredBreak() {
        let f = formatter()
        XCTAssertEqual(f.formatSegments([("Hello new line", 0, 1), ("Call the station", 3, 4)]),
                       "Hello\nCall the station.")
        XCTAssertEqual(f.formatSegments([("Hello", 0, 1), ("new line call the station", 3, 4)]),
                       "Hello\nCall the station.")
        XCTAssertEqual(f.formatSegments([("🙂 Hello new line.", 0, 1), ("Call the station", 3, 4)]),
                       "🙂 Hello\nCall the station.")
    }

    func testRepeatedExplicitCommandsAreNotDeduplicatedWithPause() {
        let f = formatter()
        let twice = f.formatSegments([("Hello new line", 0, 1), ("new line call the station", 3, 4)])
        XCTAssertEqual(twice, "Hello.\n\nCall the station.")
        let threeTimes = f.formatSegments([("Hello new line new line", 0, 1), ("new line call the station", 3, 4)])
        XCTAssertEqual(threeTimes.filter(\.isNewline).count, 3, threeTimes)
    }

    func testQuotedCommandAcrossSegmentsIsNeverInterpretedAgain() {
        let f = formatter()
        let output = f.formatSegments([("Keep \"the command", 0, 1), ("new line\" in the guide", 3, 4)])
        XCTAssertTrue(output.lowercased().contains("new line"), output)
        XCTAssertEqual(output.filter(\.isNewline).count, 2, output)
    }

    func testCommandAwareTimedAssemblyStillRespectsDisabledCommands() {
        let f = formatter(commands: false)
        let output = f.formatSegments([("Hello new line", 0, 1), ("Call the station", 3, 4)])
        XCTAssertTrue(output.contains("new line"), output)
        XCTAssertEqual(output.filter(\.isNewline).count, 2, output)
    }
}
