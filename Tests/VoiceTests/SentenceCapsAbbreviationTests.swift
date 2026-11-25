import Testing
@testable import Voice

/// 22 Nov 2026 replay: 12 of 296 cleanups came out as "etc., And all the pages" because the sentence-start
/// pass capitalised the word after any full stop, even with a comma between.
@Suite("Sentence-start capitals skip abbreviations and commas")
struct SentenceCapsAbbreviationTests {
    @Test("etc., e.g. and i.e. do not start a sentence")
    func abbreviations() {
        #expect(PolishPostprocessor.sentenceStartCapsPass("paper maps, etc., and several old compasses")
                == "Paper maps, etc., and several old compasses")
        #expect(PolishPostprocessor.sentenceStartCapsPass("we need it etc. and more") == "We need it etc. and more")
        #expect(PolishPostprocessor.sentenceStartCapsPass("pick one, e.g. the red one") == "Pick one, e.g. the red one")
        #expect(PolishPostprocessor.sentenceStartCapsPass("the big one, i.e. this") == "The big one, i.e. this")
    }

    @Test("Real sentence ends still capitalise")
    func realSentences() {
        #expect(PolishPostprocessor.sentenceStartCapsPass("done. next one? yes! ok\nnew line")
                == "Done. Next one? Yes! Ok\nNew line")
        #expect(PolishPostprocessor.sentenceStartCapsPass("version 2.1 is out. it works") == "Version 2.1 is out. It works")
        #expect(PolishPostprocessor.sentenceStartCapsPass("see example.com for it") == "See example.com for it")
    }
}
