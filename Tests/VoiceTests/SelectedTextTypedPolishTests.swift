import Testing
import Foundation
@testable import Voice

// Exercise selected-text cleanup with an invented paragraph and a stubbed model reply.

@MainActor
@Suite(.serialized) struct SelectedTextTypedPolishTests {

    static let bugRaw = "hey so i left a blittle note by the greenhous door but i forgot to say where the spar key is, its in the bluu pot, dont move the botles on the shelf becuase theyre labeled for tomorrows class"
    static let bugWispr = "Hey, so I left a little note by the greenhouse door, but I forgot to say where the spare key is. It's in the blue pot. Don't move the bottles on the shelf because they're labeled for tomorrow's class."

    /// A second messy typed paragraph, written differently, so the fix is not tuned to one example.
    static let otherRaw = "ok so the meeting thing got moved to thurs i think, idk if ppl can make it tho, dont wanna rush them honestly, can u check w sarah and lmk"
    static let otherRewrite = "OK, so the meeting got moved to Thursday, I think. I don't know if people can make it, but I don't want to rush them. Can you check with Sarah and let me know?"

    /// Runs `body` with the replay answer as the cloud model's reply, then restores the settings.
    private func withRecordedAnswer(_ answer: String?, _ body: () async -> Void) async {
        let defaults = UserDefaults.standard
        let keys = ["voice.evalCloudOnly", "voice.allowCloudPolishing", "voice.privacyMode", "cerebrasEnabled"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defaults.set(true, forKey: "voice.evalCloudOnly")
        defaults.set(true, forKey: "voice.allowCloudPolishing")
        defaults.set(false, forKey: "voice.privacyMode")
        defaults.set(true, forKey: "cerebrasEnabled")
        CerebrasPolisher.replayResponder = { _ in answer }
        await body()
        CerebrasPolisher.replayResponder = nil
        for (key, value) in zip(keys, previous) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    private func polish(_ raw: String, answer: String?, preset: String = "fix", level: PolishLevel? = .light) async -> String? {
        var result: String? = nil
        await withRecordedAnswer(answer) {
            result = await Qwen3Polisher.shared.polishInPlace(raw, preset: preset, level: level)
        }
        return result
    }

    // MARK: - The reported no-op

    @Test func theReportedRewriteIsAcceptedAndReplacesTheSelection() async {
        let out = await polish(Self.bugRaw, answer: Self.bugWispr)
        #expect(out == Self.bugWispr)
    }

    @Test func aDifferentlyWrittenMessyParagraphIsAlsoAccepted() async {
        let out = await polish(Self.otherRaw, answer: Self.otherRewrite)
        #expect(out == Self.otherRewrite)
    }

    @Test func typedShorthandNegationIsAllowedToBeSpelledOut() {
        // "idk" was written as shorthand for "I don't know", so the expansion is not a new negation.
        #expect(MeaningIntegrity.selectedNegationsKept(original: "so idk if ppl can make it", candidate: "So I don't know if people can make it."))
        #expect(MeaningIntegrity.selectedNegationsKept(original: "dont wanna rush them", candidate: "I don't want to rush them."))
    }

    // MARK: - Guards that must still reject

    @Test func droppedNegationIsRejectedAndTheSelectionIsLeftAlone() async {
        #expect(await polish("I don't think we should send the contract yet lol", answer: "I think we should send the contract yet.") == nil)
    }

    @Test func swappedNumberIsRejected() async {
        #expect(await polish("the budget is 4500 euros ish", answer: "The budget is 4050 euros.") == nil)
    }

    @Test func swappedCapitalisedNameIsRejected() async {
        #expect(await polish("Talk to Priya tmrw about the deck", answer: "Talk to Pria tomorrow about the deck.") == nil)
    }

    @Test func rejectionReasonIsRecordedForTheUser() async {
        _ = await polish("I don't think we should send the contract yet lol", answer: "I think we should send the contract yet.")
        #expect(Qwen3Polisher.lastSelectedRejection?.contains("negation") == true)
    }

    // MARK: - The instruction must allow reconstruction for typed text

    @Test func lightLevelInstructionAllowsRepairingTypos() {
        let prompt = Qwen3Polisher.buildPolishInPlacePrompt(preset: "fix", instructions: nil, level: .light)
        #expect(prompt.contains("typo"))
        #expect(prompt.contains("shorthand"))
        #expect(prompt.contains("negation"))
    }
}
