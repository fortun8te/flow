import Foundation
import Testing
@testable import Voice

struct WisprSelectedTextPolishTests {
    @Test func privacyAlwaysOverridesCloudOptIn() {
        #expect(!Qwen3Polisher.cloudAllowed(optIn: true, privacyMode: true))
        #expect(!Qwen3Polisher.cloudAllowed(optIn: false, privacyMode: true))
        #expect(!Qwen3Polisher.cloudAllowed(optIn: false, privacyMode: false))
        #expect(Qwen3Polisher.cloudAllowed(optIn: true, privacyMode: false))
    }

    @Test func equivalentNegationAndNumbersPreserveMeaning() {
        #expect(Qwen3Polisher.selectedTextResultIsSafe("Do not send 2 files.", original: "Don't send two files."))
        #expect(!Qwen3Polisher.selectedTextResultIsSafe("Send 2 files.", original: "Don't send two files."))
        #expect(!Qwen3Polisher.selectedTextResultIsSafe("Use 2 g.", original: "Use 2 mg."))
        #expect(!Qwen3Polisher.selectedTextResultIsSafe("Meet at 30:10.", original: "Meet at 10:30."))
    }

    @Test func importedInstructionsControlSelectedTextPrompt() {
        let data = Data(#"{"schema_version":1,"polish_instructions":{"default":{"Make more concise":true,"Reword for clarity":true,"Reorder for readability":false,"Add structure for readability":false}}}"#.utf8)
        let profile = WisprPersonalizationProfile.decode(data)!
        let prompt = Qwen3Polisher.buildPolishInPlacePrompt(preset: "fix", instructions: profile.instructions)
        #expect(prompt.contains("Make the text more concise"))
        #expect(prompt.contains("Reword where needed"))
        #expect(prompt.contains("Keep the original order"))
        #expect(prompt.contains("Keep the original structure"))
    }

    @Test func safetyChecksRejectAlteredNumbersNegationsAndEntities() {
        let original = "Please don't send Qwen 3.8 to Maya."
        #expect(Qwen3Polisher.selectedTextResultIsSafe("Please don't send Qwen 3.8 to Maya.", original: original))
        #expect(!Qwen3Polisher.selectedTextResultIsSafe("Please send Qwen 3.8 to Maya.", original: original))
        #expect(!Qwen3Polisher.selectedTextResultIsSafe("Please don't send Qwen 4.8 to Maya.", original: original))
        #expect(!Qwen3Polisher.selectedTextResultIsSafe("Please don't send Qwen 3.8 to Sam.", original: original))
        #expect(!Qwen3Polisher.selectedTextResultIsSafe("Here is the polished version.", original: original))
        #expect(!Qwen3Polisher.selectedTextResultIsSafe("<think>Draft</think> Please don't send Qwen 3.8 to Maya.", original: original))
    }
}
