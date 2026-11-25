import Testing
@testable import Voice

@Suite("Media-leak guard (lyrics / video bleed)")
struct MediaLeakGuardTests {
    @Test("Short, low-share transcript while media plays is dropped")
    func dropsShortBleed() {
        let reason = SpeechPresenceGate.mediaLeakDropReason(
            joinedText: "oh baby baby", voicedSeconds: 0.5, capturedSeconds: 4.0, mediaPlaying: true)
        #expect(reason != nil)
    }

    @Test("Nothing is dropped when no media is playing")
    func keepsWhenNoMedia() {
        #expect(SpeechPresenceGate.mediaLeakDropReason(
            joinedText: "send it", voicedSeconds: 0.5, capturedSeconds: 4.0, mediaPlaying: false) == nil)
    }

    @Test("Long dictation is never dropped, even at low speech share")
    func keepsLongDictation() {
        #expect(SpeechPresenceGate.mediaLeakDropReason(
            joinedText: "this is a longer dictation with several words in it",
            voicedSeconds: 0.5, capturedSeconds: 4.0, mediaPlaying: true) == nil)
    }

    @Test("Short transcript with a high speech share is kept")
    func keepsWhenSpeechDominates() {
        #expect(SpeechPresenceGate.mediaLeakDropReason(
            joinedText: "yes please", voicedSeconds: 3.0, capturedSeconds: 4.0, mediaPlaying: true) == nil)
    }

    @Test("Word limit is inclusive at the boundary and exclusive above it")
    func wordBoundary() {
        let atLimit = (1...SpeechPresenceGate.mediaLeakMaxWords).map { "w\($0)" }.joined(separator: " ")
        let overLimit = atLimit + " extra"
        #expect(SpeechPresenceGate.mediaLeakDropReason(
            joinedText: atLimit, voicedSeconds: 0.1, capturedSeconds: 4.0, mediaPlaying: true) != nil)
        #expect(SpeechPresenceGate.mediaLeakDropReason(
            joinedText: overLimit, voicedSeconds: 0.1, capturedSeconds: 4.0, mediaPlaying: true) == nil)
    }

    @Test("A confidently decoded faint phrase can clear the quiet speech gate")
    func keepsDecodedWhisper() {
        #expect(SpeechPresenceGate.dropReason(joinedText: "Please check the microphone level",
            voicedSeconds: 0, peakRMS: 0.0049, quietVoicedSeconds: 1.024,
            recognitionConfidence: 0.92) == nil)
    }

    @Test("Quiet recovery requires sustained input and confidence and still rejects possible media")
    func quietSpeechDoesNotAdmitNoiseAndMedia() {
        let phrase = "Please check the microphone level"
        #expect(SpeechPresenceGate.dropReason(joinedText: phrase,
            voicedSeconds: 0, peakRMS: 0, quietVoicedSeconds: 0, recognitionConfidence: 0.99) != nil)
        #expect(SpeechPresenceGate.dropReason(joinedText: phrase,
            voicedSeconds: 0, peakRMS: 0.0049, quietVoicedSeconds: 0.2, recognitionConfidence: 0.99) != nil)
        #expect(SpeechPresenceGate.dropReason(joinedText: phrase,
            voicedSeconds: 0, peakRMS: 0.0049, quietVoicedSeconds: 1.024, recognitionConfidence: 0.4) != nil)
        #expect(SpeechPresenceGate.dropReason(joinedText: "Thanks for watching.",
            voicedSeconds: 0, peakRMS: 0.0049, quietVoicedSeconds: 1.024, recognitionConfidence: 0.99) != nil)
        #expect(SpeechPresenceGate.dropReason(joinedText: phrase,
            voicedSeconds: 0, peakRMS: 0.0049, quietVoicedSeconds: 1.024,
            recognitionConfidence: 0.99, mediaPlaying: true) != nil)
    }

    @Test("Zero capture or empty text never drops")
    func degenerateInputs() {
        #expect(SpeechPresenceGate.mediaLeakDropReason(
            joinedText: "hi", voicedSeconds: 0, capturedSeconds: 0, mediaPlaying: true) == nil)
        #expect(SpeechPresenceGate.mediaLeakDropReason(
            joinedText: "  ", voicedSeconds: 0, capturedSeconds: 4, mediaPlaying: true) == nil)
    }
}
