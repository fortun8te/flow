import Testing
@testable import Voice

@Suite("Styles change capitals and punctuation only (A3)")
struct StyleTransformTests {
    /// Lower-cased words with punctuation removed. Equal sequences mean the wording did not change.
    private func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
    }

    @Test("Formal: sentence capitals, a final full stop, I as a word; no wording change")
    func formal() {
        let input = "hey can u send maya a message saying we're running like really late"
        let out = StyleTransform.apply(input, style: .formal)
        #expect(out == "Hey can u send maya a message saying we're running like really late.")
        #expect(words(out) == words(input))
        #expect(StyleTransform.apply("i think i'm late", style: .formal) == "I think I'm late.")
    }

    @Test("Formal never adds an exclamation mark and keeps a question mark")
    func formalKeepsMarks() {
        #expect(StyleTransform.apply("send it!", style: .formal) == "Send it!")
        #expect(StyleTransform.apply("are you coming?", style: .formal) == "Are you coming?")
    }

    @Test("Casual: a capital at the start and no final full stop; the rest of the text is as written")
    func casual() {
        let input = "Send Maya a message. We're running really late."
        let out = StyleTransform.apply(input, style: .casual)
        #expect(out == "Send Maya a message. We're running really late")
        #expect(StyleTransform.apply("are you coming?", style: .casual) == "Are you coming?")
    }

    @Test("Very casual: all lower case, I and acronyms kept, sentence full stops removed")
    func veryCasual() {
        #expect(StyleTransform.apply("Hey, Can you send Maya a message? We're running late.", style: .veryCasual)
            == "hey, can you send maya a message? we're running late")
        #expect(StyleTransform.apply("Then I'm late. OK send it.", style: .veryCasual) == "then I'm late OK send it")
    }

    @Test("Excited: the last full stop becomes an exclamation mark, the rest is left alone")
    func excited() {
        #expect(StyleTransform.apply("Send Maya a message. We're running really late.", style: .excited)
            == "Send Maya a message. We're running really late!")
        #expect(StyleTransform.apply("Is it late?", style: .excited) == "Is it late?")
        #expect(StyleTransform.apply("Wait...", style: .excited) == "Wait...")
    }

    @Test("Numbers with a point are not full stops")
    func numbersKeepTheirPoint() {
        #expect(StyleTransform.apply("It costs 3.5.", style: .veryCasual) == "it costs 3.5")
        #expect(StyleTransform.apply("Pay 3.5 dollars.", style: .formal) == "Pay 3.5 dollars.")
    }

    @Test("Bullet lines get capitals but no added full stop")
    func listsAreNotFinished() {
        #expect(StyleTransform.apply("- buy milk\n- call mom", style: .formal) == "- Buy milk\n- Call mom")
    }

    @Test("Empty text and unknown style names are unchanged")
    func unchanged() {
        #expect(StyleTransform.apply("", style: .formal) == "")
        #expect(StyleTransform.apply("   ", style: .casual) == "   ")
        #expect(StyleTransform.apply("hello there", styleName: "something-else") == "hello there")
    }

    @Test("The old neutral setting reads as Casual and the four offered styles are the Wispr names")
    func settingNames() {
        #expect(PersonalityStyle.offered.map(\.displayName) == ["Formal", "Casual", "Very casual", "Excited"])
        #expect(StyleTransform.apply("hello there", style: .neutral) == StyleTransform.apply("hello there", style: .casual))
    }
}
