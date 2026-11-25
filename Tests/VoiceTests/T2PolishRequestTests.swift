import Foundation
import Testing
@testable import Voice

@Suite("T2 selected-text contract, no model")
struct T2PolishRequestTests {
    @Test func canonicalEnvelopeAndAllFiveSwitches() throws {
        var options = T2PolishOptions()
        options.maintainYourTone = false
        options.editingPrompt = "  Keep café / links.  "
        let prompt = try #require(options.userPrompt(text: "  hello there  "))
        #expect(prompt == "[Polish request v1] {\"contract\":\"t2-selected-text-polish-v1\",\"editing_prompt\":\"Keep café / links.\",\"settings\":{\"clarity\":true,\"concise\":true,\"maintain_your_tone\":false,\"reorder\":true,\"structure\":true}}\nhello there")
    }

    @Test func boundsAndRoleMarkers() {
        var options = T2PolishOptions()
        options.editingPrompt = String(repeating: "😀", count: 1000)
        #expect(options.userPrompt(text: "hello") != nil)
        options.editingPrompt += "x"
        #expect(options.userPrompt(text: "hello") == nil)
        for bad in ["a\u{0}b", "a\u{7f}b", "[INST]", "<|system", "<<SYS>>"] {
            options.editingPrompt = bad
            #expect(options.userPrompt(text: "hello") == nil)
            options.editingPrompt = ""
            #expect(options.userPrompt(text: bad) == nil)
        }
        #expect(options.userPrompt(text: String(repeating: "x", count: 4001)) == nil)
        #expect(options.userPrompt(text: " \n ") == nil)
    }

    @Test func capabilityBelongsToActiveFileOnly() {
        let data = Data(#"{"active":"t2.gguf","contracts":{"t2.gguf":["t2-selected-text-polish-v1"]}}"#.utf8)
        #expect(T2PolishOptions.supports(manifest: data, modelFilename: "t2.gguf"))
        #expect(!T2PolishOptions.supports(manifest: data, modelFilename: "model-Q8_0.gguf"))
        #expect(!T2PolishOptions.supports(manifest: Data(#"{"active":"t1.gguf"}"#.utf8), modelFilename: "t1.gguf"))
        #expect(!T2PolishOptions.supports(manifest: nil, modelFilename: "t2.gguf"))
    }

    @Test func savedFalseSurvivesAndProfileIsReused() throws {
        let defaults = try #require(UserDefaults(suiteName: "T2PolishTests.\(UUID().uuidString)"))
        defer { defaults.removeObject(forKey: T2PolishOptions.defaultsKey) }
        let profile = try #require(WisprPersonalizationProfile.decode(Data(#"{"schema_version":1,"polish_instructions":{"default":{"Make more concise":false,"Maintain your tone":false,"Customize your Polish prompt":"Keep slang"}}}"#.utf8)))
        var options = T2PolishOptions.load(defaults: defaults, instructions: profile.instructions)
        #expect(!options.concise && !options.maintainYourTone)
        #expect(options.editingPrompt == "Keep slang")
        options.clarity = false
        options.save(defaults: defaults)
        #expect(T2PolishOptions.load(defaults: defaults) == options)
        #expect(T2PolishOptions().maintainYourTone)
    }
}
