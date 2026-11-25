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

    @Test("Empty or whitespace-only results never replace a remembered transcript")
    func ignoresBlank() {
        var store = LastTranscriptStore()
        store.remember("Keep me.")
        store.remember("")
        store.remember("   \n ")
        #expect(store.text == "Keep me.")
    }

    @Test("Never handled while a recording is in progress")
    func recordingBlocks() {
        var store = LastTranscriptStore()
        store.remember("Pasteable.")
        #expect(!store.shouldHandlePasteLast(isRecording: true))
        #expect(store.shouldHandlePasteLast(isRecording: false))
    }
}
