import Testing
@testable import Voice

@Suite("Wispr replacement safety")
struct RebuildQAWisprBlankTriggerTests {
    @Test("Whitespace-only triggers do not change dictation")
    func whitespaceTriggersAreIgnored() {
        let rules = [WisprImportService.Replacement(from: " ", to: "oops"),
                     WisprImportService.Replacement(from: "\n", to: "oops")]
        #expect(WisprImportService.applyReplacements(to: "hello there\nfriend", using: rules) == "hello there\nfriend")
    }
}
