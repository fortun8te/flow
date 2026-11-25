#if canImport(MLXLLM) && canImport(MLXLMCommon)
import Testing
import MLXLMCommon
@testable import Voice

@Suite("Dictation model input")
struct DictationModelInputTests {
    @Test("Preserves system instructions and disables thinking")
    func explicitRoles() {
        let input = Qwen3Polisher.dictationModelInput(prompt: "example request")
        guard case let .chat(messages) = input.prompt else {
            Issue.record("Expected structured chat input")
            return
        }
        #expect(messages.count == 2)
        guard messages.count == 2 else { return }
        #expect(messages[0].role == .system)
        #expect(messages[0].content.contains("NEVER invent content"))
        #expect(messages[1].role == .user)
        #expect(messages[1].content == "example request")
        #expect(input.additionalContext?["enable_thinking"] as? Bool == false)
    }
}
#endif
