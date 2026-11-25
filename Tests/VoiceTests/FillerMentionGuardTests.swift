import Foundation
import Testing
@testable import Voice

/// Fillers go, except when the dictation is about the filler itself (22 Nov 2026 replay probes: the model
/// turned "the word um and the word uh" into "um" twice, and dropped "um" from "when I say um on purpose").
@Suite("Filler mentions survive cleanup")
struct FillerMentionGuardTests {
    @Test("Mentions are found; ordinary hesitations are not mentions")
    func findsMentions() {
        #expect(DictationFinalPass.fillerMentions("remove the word um and the word uh but keep the rest") == ["um", "uh"])
        #expect(DictationFinalPass.fillerMentions("Wispr keeps saying um when I say um on purpose") == ["um"] ||
                DictationFinalPass.fillerMentions("Wispr keeps saying um when I say um on purpose") == ["um", "um"])
        #expect(DictationFinalPass.fillerMentions("Remove the ums and uhs from the output.") == ["ums", "uhs"])
        #expect(DictationFinalPass.fillerMentions("um so I think uh we should ship it").isEmpty)
        // "saying um" before a new clause is a hesitation (22 Nov 2026 replay false trip).
        #expect(DictationFinalPass.fillerMentions("so i checked the rack um another oar is missing").isEmpty)
        #expect(DictationFinalPass.apply("So I checked the rack um another oar is missing.") == "So I checked the rack another oar is missing.")
        #expect(DictationFinalPass.fillerMentions("No fillers here at all.").isEmpty)
    }

    @Test("A cleanup that drops or swaps a mentioned filler is caught")
    func catchesDroppedMention() {
        let source = "in the transcript you should remove the word um and the word uh but keep everything else"
        #expect(DictationFinalPass.dropsFillerMention(source: source,
            output: "In the transcript, you should remove the word \"um\" and the word \"um,\" but keep everything else."))
        #expect(!DictationFinalPass.dropsFillerMention(source: source,
            output: "In the transcript, you should remove the word \"um\" and the word \"uh\" but keep everything else."))
        #expect(DictationFinalPass.dropsFillerMention(source: "when I say um on purpose", output: "When I say on purpose."))
        // Plain hesitations may go.
        #expect(!DictationFinalPass.dropsFillerMention(source: "um so I think uh we ship", output: "So I think we ship."))
    }

    @Test("The model's answer is refused and the fallback keeps the mention")
    func decisionKeepsMention() async {
        let source = "in the transcript you should remove the word um and the word uh but keep everything else"
        let bad = "In the transcript, you should remove the word \"um\" and the word \"um,\" but keep everything else."
        let decided = await WhisperNowCleanupDecision.decide(source: source, reply: .success(.text(bad))) { nil }
        #expect(decided.outcome == .stripped(reason: "filler-mention"))
        #expect(decided.text.lowercased().contains("the word um"))
        #expect(decided.text.lowercased().contains("the word uh"))
        #expect(decided.text.first == "I")
    }

    @Test("A good answer that keeps the mentions is used")
    func goodAnswerIsUsed() async {
        let source = "um can you remove the word uh from my notes"
        let good = "Can you remove the word \"uh\" from my notes?"
        let decided = await WhisperNowCleanupDecision.decide(source: source, reply: .success(.text(good))) { nil }
        #expect(decided.outcome == .model)
        #expect(decided.text == good)
    }

    @Test("Removing a leading Dutch hesitation capitalises the sentence (the formatter capitalises the start)")
    func dutchLeadingHesitation() {
        #expect(DictationFinalPass.apply("Eh ik denk dat we morgen kunnen beginnen, uh, als dat goed is")
                    == "Ik denk dat we morgen kunnen beginnen, als dat goed is")
    }
}
