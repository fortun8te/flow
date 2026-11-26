import Testing
@testable import Voice

@Suite("Paste last transcript store")
struct LastTranscriptStoreTests {
    @Test("Nothing to paste before the first successful dictation")
    func emptyStore() {
        let store = LastTranscriptStore()
        #expect(store.text == nil)
        #expect(!store.shouldHandlePasteLast(isRecording: false))
    }

    @Test("Remembers the latest final text and replaces the older one")
    func remembersLatest() {
        var store = LastTranscriptStore()
        store.remember("First thought.")
        store.remember("Second thought.")
        #expect(store.text == "Second thought.")
        #expect(store.shouldHandlePasteLast(isRecording: false))
    }

    @Test("Empty results or horizontal padding never replace a remembered transcript")
    func ignoresBlank() {
        var store = LastTranscriptStore()
        store.remember("Keep me.")
        store.remember("")
        store.remember("   \t ")
        #expect(store.text == "Keep me.")
    }

    @Test("A standalone line-break command is the latest pasteable dictation")
    func remembersLayoutCommand() {
        var store = LastTranscriptStore()
        store.remember("Older text.")
        store.remember("\n\n")
        #expect(store.text == "\n\n")
        #expect(store.shouldHandlePasteLast(isRecording: false))
    }

    @Test("Never handled while a recording is in progress")
    func recordingBlocks() {
        var store = LastTranscriptStore()
        store.remember("Pasteable.")
        #expect(!store.shouldHandlePasteLast(isRecording: true))
        #expect(store.shouldHandlePasteLast(isRecording: false))
    }
}
