import XCTest
@testable import Voice

/// "Still leaving in too many fillers" (21 Nov 2026). Inputs are his own recent dictations
/// from voice.db where the pasted text still had them.
final class DictationFinalPassTests: XCTestCase {
    private func clean(_ s: String) -> String { DictationFinalPass.apply(s) }

    func testDictationLosesHesitations() {
        XCTAssertEqual(clean("the tide is rising.\n\nUh the ferry leaves at dusk."),
                       "the tide is rising.\n\nThe ferry leaves at dusk.")
        XCTAssertEqual(clean("The rope feels loose. Uh, the stern rope. Um also please bring gloves."),
                       "The rope feels loose. The stern rope. Also please bring gloves.")
        XCTAssertEqual(clean("I counted six lanterns by the door but um the red lantern is missing"),
                       "I counted six lanterns by the door but the red lantern is missing")
        XCTAssertEqual(clean("And I cannot tell why the uh brass latch is jammed."),
                       "And I cannot tell why the brass latch is jammed.")
        XCTAssertEqual(clean("Keep the uh side gate closed."), "Keep the side gate closed.")
        XCTAssertEqual(clean("leave the spare key so we can uh open the shed."),
                       "leave the spare key so we can open the shed.")
    }

    func testCommaFramedHesitationKeepsOneComma() {
        XCTAssertEqual(clean("So, um, we should ship it."), "So, we should ship it.")
        XCTAssertEqual(clean("And um, we should ship it."), "And we should ship it.")
        // Nothing but hesitations: nothing to paste (the caller reports no speech). Was "Um." -> "Um." (22 Nov 2026).
        XCTAssertEqual(clean("Um."), "")
        XCTAssertEqual(clean("Uh, um."), "")
        XCTAssertEqual(clean("I think, uh, yes. Uh. Then we go."), "I think, yes. Then we go.")
    }

    func testDutchHesitationsGo() {
        XCTAssertEqual(clean("Ehm, ik denk dat we eh morgen gaan."), "Ik denk dat we morgen gaan.")
        XCTAssertEqual(clean("Er is euh nog een ding."), "Er is nog een ding.")
    }

    func testTalkingAboutTheFillersKeepsThem() {
        XCTAssertEqual(clean("Remove the ums and uhs from the output."), "Remove the ums and uhs from the output.")
        // 21 Nov 14:59 (real): the first Uh is a hesitation, the rest is a mention.
        XCTAssertEqual(clean("Uh, but when the glossary quotes ums and uh's, retain both words."),
                       "But when the glossary quotes ums and uh's, retain both words.")
        XCTAssertEqual(clean("The word um should stay here."), "The word um should stay here.")
        XCTAssertEqual(clean("Can you remove the um and uh?"), "Can you remove the um and uh?")
        XCTAssertEqual(clean("Never write \"uh\" in a reply."), "Never write \"uh\" in a reply.")
    }

    func testProtectedDetailsAreUntouched() {
        XCTAssertEqual(clean("Open https://example.com/um/uh and run `uh --um` now."),
                       "Open https://example.com/um/uh and run `uh --um` now.")
        XCTAssertEqual(clean("Send $4,500 to Ahmed, not $4,050."), "Send $4,500 to Ahmed, not $4,050.")
        XCTAssertEqual(clean("I don't want that that way."), "I don't want that that way.")
        XCTAssertEqual(clean("The umbrella and the uhlan stay."), "The umbrella and the uhlan stay.")
        XCTAssertEqual(clean("Yeah yeah, no no, bye bye."), "Yeah yeah, no no, bye bye.")
        XCTAssertEqual(clean("It is not not working."), "It is not not working.")
    }

    func testStuttersAndRestartsGo() {
        // Real lines from voice.db (20-21 Nov).
        XCTAssertEqual(clean("Why why is it so brightly painted?"), "Why is it so brightly painted?")
        XCTAssertEqual(clean("And I I'd hang the bell beside the porch"), "And I'd hang the bell beside the porch")
        XCTAssertEqual(clean("just really enjoy sorting sorting ceramic beads"), "just really enjoy sorting ceramic beads")
        XCTAssertEqual(clean("is it time to open another another crate"), "is it time to open another crate")
        XCTAssertEqual(clean("When should we paint when should we paint fences?"), "When should we paint fences?")
        XCTAssertEqual(clean("We we're almost done."), "We're almost done.")
    }

    func testOnlyCommaFramedLikeAndYouKnowGo() {
        XCTAssertEqual(clean("It was, like, huge."), "It was huge.")
        XCTAssertEqual(clean("Like, we should go."), "We should go.")
        XCTAssertEqual(clean("I like it a lot."), "I like it a lot.")
        XCTAssertEqual(clean("Where should we plant the last willow, you know?"), "Where should we plant the last willow?")
        XCTAssertEqual(clean("You know what I mean."), "You know what I mean.")
        XCTAssertEqual(clean("Do you know Noor?"), "Do you know Noor?")
    }

    func testModelListMarkupBecomesPlainLines() {
        XCTAssertEqual(clean("For the exhibit, pack:\n\n<ul><li>Lantern</li><li>Compass</li></ul>\n\nThen label the crate."),
                       "For the exhibit, pack:\n\n- Lantern\n- Compass\n\nThen label the crate.")
        XCTAssertEqual(clean("<ol><li>Send it</li><li>Call Kai</li></ol>"), "1. Send it\n2. Call Kai")
    }

    func testBrokenFullStopsFromTheRecogniserAreJoined() {
        // 18 Nov 12:13 and 20 Nov 13:16 raw transcripts.
        XCTAssertEqual(DictationFinalPass.joinBrokenSentences("the ferry can fit twelve bicycles. at once and then"),
                       "the ferry can fit twelve bicycles at once and then")
        XCTAssertEqual(DictationFinalPass.joinBrokenSentences("we filed the blue map. yesterday."),
                       "we filed the blue map yesterday.")
        XCTAssertEqual(DictationFinalPass.joinBrokenSentences("Bring pens, paper etc. and a laptop. Then go."),
                       "Bring pens, paper etc. and a laptop. Then go.")
        XCTAssertEqual(DictationFinalPass.joinBrokenSentences("Open v2. then quit"), "Open v2. then quit")
    }

    func testNormalTextIsUnchanged() {
        for s in ["Please keep the booking for Thursday.", "Ik heb er geen zin in.", "Hmm, not sure.",
                  "First line.\nSecond line."] {
            XCTAssertEqual(clean(s), s)
        }
    }

    /// Every output path ends in the same pass. Each case is a path's text, as it would leave that path.
    func testEveryOutputPathLosesHesitations() async {
        let said = "um so the uh plan is set, uh, and we ship"
        // Cleanup model output that kept hesitations (model path, timeout partial, Option+1 replacement).
        XCTAssertEqual(clean("Um, so the uh plan is set, uh, and we ship."), "So the plan is set, and we ship.")
        // Rules fallback (WhisperNow stripped) and the rules-only raw text.
        let fallback = WhisperNowContentGuard.stripHesitations(said)
        XCTAssertFalse(clean(fallback).lowercased().contains(" uh"))
        XCTAssertEqual(clean(fallback).lowercased(), "so the plan is set and we ship")
        let decided = await WhisperNowCleanupDecision.decide(source: said, reply: .success(.empty)) { nil }
        XCTAssertEqual(decided.outcome.label, "stripped")
        XCTAssertFalse(decided.text.lowercased().contains(" uh"))
        // Undo after cancel: the raw cancelled transcript.
        XCTAssertEqual(clean(said).lowercased(), "so the plan is set, and we ship")
    }

    func testMentionsSurviveEveryPath() async {
        let said = "the word um is a filler, so say uh less"
        XCTAssertEqual(clean(said), said)
        let decided = await WhisperNowCleanupDecision.decide(source: said, reply: .success(.text("The word um is a filler, so say uh less.")), s1: { nil })
        XCTAssertTrue(decided.text.lowercased().contains("the word um"))
        XCTAssertTrue(clean(WhisperNowContentGuard.stripHesitations(said)).contains("word um"))
    }
}

/// "Line breaks suck and lists too."
final class DictationListLayoutTests: XCTestCase {
    func testSentenceStartOrdinalsWithoutCommasBecomeAList() {
        XCTAssertEqual(DictationParagraphs.formatDictation("A few things. First we need milk. Second we need bread. Third call Noor."),
                       "A few things.\n\n1. We need milk.\n2. We need bread.\n3. Call Noor.")
        XCTAssertEqual(DictationParagraphs.formatDictation("Firstly, fix the pill. Secondly, keep the audio. Finally, ship it."),
                       "1. Fix the pill.\n2. Keep the audio.\n3. Ship it.")
        XCTAssertEqual(DictationParagraphs.formatDictation("First of all, check the log. Second, send it to Kai."),
                       "1. Check the log.\n2. Send it to Kai.")
    }

    func testOneOrdinalOrAnOrdinalInsideASentenceStaysProse() {
        for s in ["First, check the file. Then we go home.",
                  "This is the first time and the second time.",
                  "Finally, we are done.",
                  "First we went home. Then second thoughts came."] {
            XCTAssertEqual(DictationParagraphs.formatDictation(s), s)
        }
    }

    func testLongDictationDoesNotBreakBeforeAContinuingSentence() {
        let a = String(repeating: "The rowing team can store its spare oars under the bench beside the door. ", count: 7)
        let input = a + "And because the old rack is rusted through, put the oars on the new shelf."
        XCTAssertFalse(DictationParagraphs.formatDictation(input).contains("\n\nAnd because"))
    }
}

final class DictationFinalPassNameTests: XCTestCase {
    func testNamesAndTheWordIAreHandled() {
        XCTAssertEqual(DictationFinalPass.apply("We flew to Bora Bora last year."), "We flew to Bora Bora last year.")
        XCTAssertEqual(DictationFinalPass.apply("I I want it."), "I want it.")
        XCTAssertEqual(DictationFinalPass.apply("I love New York New York."), "I love New York New York.")
    }
}

/// Replayed over 1,500 saved dictations (21 Nov 2026): these must stay as spoken.
final class DictationFinalPassReplayTests: XCTestCase {
    func testEmphasisAndGrammarAreKept() {
        for s in ["polish each of those beads", "The paint seems very, very, very, very bright",
                  "Turn left, left of the lighthouse.", "Keep searching, and please, please mark it",
                  "poems and poems and poems and sketches", "The box holds maps and maps and maps",
                  "Three objects: bronze lantern, paper compass, glass bead", "Wait, wait!", "Wait wait!", "go go go go go.",
                  "fix that that'd be great"] {
            XCTAssertEqual(DictationFinalPass.apply(s), s)
        }
    }
}

final class DictationColonListTests: XCTestCase {
    func testColonEnumerationBecomesBullets() {
        let input = "For the picnic, pack: plates, napkins, cups, forks, spoons, and blankets. The basket is by the door."
        XCTAssertEqual(DictationParagraphs.formatDictation(input),
                       "For the picnic, pack:\n\n- Plates\n- Napkins\n- Cups\n- Forks\n- Spoons\n- Blankets\n\nThe basket is by the door.")
    }

    func testShortOrLongItemsStayProse() {
        for s in ["Note: red, blue and green.",
                  "The plan: we go home, we eat something nice with the family, we sleep for a long time, and we wake up.",
                  "Time: 10:30, 11:00, 12:00 and 13:00."] {
            XCTAssertEqual(DictationParagraphs.formatDictation(s), s)
        }
    }
}

final class DictationColonListReplayTests: XCTestCase {
    func testRealProseWithAColonStaysProse() {
        for s in ["The bake time changed: instead of 25, 1 minute on high, it is now 30 minutes and 0.8 on the dial. Then cool.",
                  "Inspect the timber carefully: every knot, every split, every nail, everything. Mark the damaged pieces."] {
            XCTAssertEqual(DictationParagraphs.formatDictation(s), s)
        }
    }
}
