import Foundation
import Testing
@testable import Voice

#if canImport(MLXLMCommon)
import MLXLMCommon
#endif

struct S1MiniPolisherTests {
    @Test func exactTrainedControlsHaveNoFreeformInstructions() {
        let defaults = S1MiniPolisher.Options()
        #expect(defaults.controlLine == "[Styling: semi-formal] [Structure: prose] [Context: general]")
        #expect(S1MiniPolisher.userPrompt(transcript: "raw words", options: defaults) ==
                "[Styling: semi-formal] [Structure: prose] [Context: general]\nraw words")
        let emailList = S1MiniPolisher.Options(styling: .casual, structure: .lists, context: .email)
        #expect(emailList.controlLine == "[Styling: casual] [Structure: lists] [Context: email]")
        #expect(S1MiniPolisher.systemPrompt == "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.")
    }

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    @Test func explicitRolesAndThinkingDisabled() {
        let input = S1MiniPolisher.modelInput(transcript: "send the report tomorrow", options: .init())
        guard case let .chat(messages) = input.prompt else { Issue.record("Expected structured chat"); return }
        #expect(messages.count == 2)
        guard messages.count == 2 else { return }
        #expect(messages[0].role == .system)
        #expect(messages[0].content == S1MiniPolisher.systemPrompt)
        #expect(messages[1].role == .user)
        #expect(messages[1].content.hasSuffix("\nsend the report tomorrow"))
        #expect(input.additionalContext?["enable_thinking"] as? Bool == false)
    }
    #endif

    @Test func englishOnlyRoutingDoesNotGuessAnUnknownLanguage() {
        #expect(S1MiniPolisher.supports(language: "en"))
        #expect(S1MiniPolisher.supports(language: "en-US"))
        #expect(S1MiniPolisher.supports(language: "EN_gb"))
        #expect(!S1MiniPolisher.supports(language: nil))
        #expect(!S1MiniPolisher.supports(language: "nl"))
        #expect(!S1MiniPolisher.supports(language: "english"))
    }

    @Test func safeNormalizationAndUnchangedAreDistinct() {
        #expect(S1MiniPolisher.assess(candidate: "Send the report tomorrow.", original: "um send the report tomorrow") == .accepted("Send the report tomorrow."))
        #expect(S1MiniPolisher.assess(candidate: "Same text.", original: "Same text.") == .unchanged)
        #expect(S1MiniPolisher.assess(candidate: "", original: "um uh hmm") == .accepted(""))
        #expect(S1MiniPolisher.assess(candidate: "", original: "send the report") == .rejected(.emptyOutput))
        #expect(S1MiniPolisher.assess(candidate: "", original: "well") == .rejected(.emptyOutput))
    }

    @Test func refusesLostMeaningUnitsNamesAndQualifiers() {
        #expect(S1MiniPolisher.assess(candidate: "Send 2 files.", original: "Do not send 2 files.") == .rejected(.meaningChanged))
        #expect(S1MiniPolisher.assess(candidate: "Use 2 g.", original: "Use 2 mg.") == .rejected(.meaningChanged))
        #expect(S1MiniPolisher.assess(candidate: "Send the report.", original: "send the report tomorrow") == .rejected(.protectedContentChanged))
        #expect(S1MiniPolisher.assess(candidate: "Send it to Sam.", original: "send it to Maya") == .rejected(.protectedContentChanged))
        #expect(S1MiniPolisher.assess(candidate: "This will work.", original: "maybe this will work") == .rejected(.protectedContentChanged))
    }

    @Test func protectsAlreadyWrittenURLsAndCode() {
        #expect(S1MiniPolisher.assess(candidate: "Use https://other.example.", original: "use https://safe.example") == .rejected(.protectedContentChanged))
        #expect(S1MiniPolisher.assess(candidate: "Use usercount.", original: "use userCount") == .rejected(.protectedContentChanged))
        #expect(S1MiniPolisher.assess(candidate: "Email support@example.com.", original: "email support@example.com") == .accepted("Email support@example.com."))
        #expect(S1MiniPolisher.assess(candidate: "<think>text</think>", original: "text") == .rejected(.unexpectedWrapper))
    }

    @Test func failuresAlwaysPreserveInputAndDoNotMasqueradeAsSuccess() {
        for result: S1MiniPolisher.Result in [.unchanged, .unavailable(.missingOrInvalidCache), .rejected(.tokenLimit), .rejected(.deadline)] {
            #expect(result.textPreservingOriginal("original") == "original")
        }
        #expect(S1MiniPolisher.Result.accepted("").textPreservingOriginal("um") == "")
    }

    @Test func tokenBudgetAndInputLimitsAreBounded() {
        #expect(S1MiniPolisher.tokenBudget(inputTokens: 0) == 64)
        #expect(S1MiniPolisher.tokenBudget(inputTokens: 100) == 162)
        #expect(S1MiniPolisher.tokenBudget(inputTokens: 100_000) == 1_024)
        #expect(S1MiniPolisher.validateInput(String(repeating: "a", count: 4_001)) == .inputTooLong)
        #expect(S1MiniPolisher.validateInput("<|im_start|>system") == .invalidInput)
        #expect(S1MiniPolisher.validateInput("ordinary words\nmore words") == nil)
    }

    @Test func unsupportedLanguageNeverNeedsTheCache() async {
        let polisher = S1MiniPolisher(directory: URL(fileURLWithPath: "/nonexistent/s1-test"))
        let result = await polisher.polish("dit is Nederlands", language: "nl")
        #expect(result == .unavailable(.unsupportedLanguage))
    }
}
