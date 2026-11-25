import Testing
@testable import Voice

struct WisprStyleFormatterTests {
    @Test func veryCasualUsesLightPresentationWithoutInventingWords() {
        #expect(WisprStyleFormatter.format("Hey, we're running late.", style: "veryCasual") == "hey, we're running late")
    }

    @Test func keepsProtectedTechnicalTermsAndMeaningfulPunctuation() {
        #expect(WisprStyleFormatter.format("Qwen 3.8 works? Yes!", style: "veryCasual", protectedTerms: ["Qwen"]) == "Qwen 3.8 works? yes!")
        #expect(WisprStyleFormatter.format("Check https://example.com.", style: "veryCasual") == "check https://example.com")
        #expect(WisprStyleFormatter.format("Wait...", style: "veryCasual") == "wait...")
    }

    @Test func otherStylesAreUntouched() {
        #expect(WisprStyleFormatter.format("Hello!", style: "excited") == "Hello!")
    }
}
