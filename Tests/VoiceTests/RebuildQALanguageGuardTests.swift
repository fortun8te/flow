import Testing
@testable import Voice

@Suite("Polish language guard")
struct RebuildQALanguageGuardTests {
    @Test("Ordinary Dutch bypasses English-only processing")
    func dutch() {
        #expect(Qwen3Polisher.isNonEnglish("Ik wil graag morgen afspreken"))
        #expect(Qwen3Polisher.isNonEnglish("Dat is eigenlijk gewoon een goed idee"))
    }

    @Test("A mixed Dutch and English sentence is protected")
    func mixedLanguage() {
        #expect(Qwen3Polisher.isNonEnglish("Can you send that tomorrow, ik wil graag morgen afspreken"))
    }

    @Test("Common English words and substrings do not trigger Dutch detection")
    func english() {
        #expect(!Qwen3Polisher.isNonEnglish("Please ship the draft tomorrow"))
        #expect(!Qwen3Polisher.isNonEnglish("We have enough time to announce the release"))
    }
}
