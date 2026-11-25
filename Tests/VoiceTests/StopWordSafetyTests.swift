import Foundation
import Testing
@testable import Voice

@MainActor
@Suite("Stop word never deletes real words (sol/01 finding 4)")
struct StopWordSafetyTests {
    private func withStopWord(_ word: String, _ body: () -> Void) {
        let d = UserDefaults.standard
        let prevWord = d.string(forKey: "voice.stopWord")
        let prevEnabled = d.object(forKey: "voice.stopWordEnabled")
        d.set(true, forKey: "voice.stopWordEnabled")
        d.set(word, forKey: "voice.stopWord")
        body()
        if let prevWord { d.set(prevWord, forKey: "voice.stopWord") } else { d.removeObject(forKey: "voice.stopWord") }
        if let prevEnabled { d.set(prevEnabled, forKey: "voice.stopWordEnabled") } else { d.removeObject(forKey: "voice.stopWordEnabled") }
    }

    @Test("A real short word one edit from the stop word is kept")
    func salt() {
        withStopWord("halt") {
            #expect(RecordingCoordinator.strippingTrailingStopWord(from: "Add salt") == "Add salt")
        }
    }

    @Test("A voice stop after 'I' removes only the command, and never a fused 'ihalt' match")
    func iHalt() {
        withStopWord("halt") {
            #expect(RecordingCoordinator.strippingTrailingStopWord(from: "I halt") == "I")
            #expect(RecordingCoordinator.strippingTrailingStopWord(from: "I ihalt") == "I ihalt")
        }
    }

    @Test("A voice stop removes only its own word, not the word before it")
    func voiceStopRemovesOnlyTheCommand() {
        withStopWord("halt") {
            #expect(RecordingCoordinator.strippingTrailingStopWord(from: "Add salt halt") == "Add salt")
        }
    }

    @Test("Push-to-talk text ending in 'salt' is never stripped")
    func pushToTalkKeepsSalt() {
        withStopWord("halt") {
            let segments = [TranscriptSegment(speaker: "You", text: "Add salt", startTime: 0, endTime: 1)]
            let prepared = DictationTextPreparation.prepare(segments: segments, formatter: TextFormatter(),
                                                            pressEnterEnabled: false, autoPaste: false,
                                                            endedByVoiceStop: false)
            #expect(prepared.command.text.lowercased().contains("salt"))
        }
    }

    @Test("A recording ended by the voice stop word still loses that word")
    func voiceEndedStripsCommand() {
        withStopWord("halt") {
            let segments = [TranscriptSegment(speaker: "You", text: "Add salt halt", startTime: 0, endTime: 1)]
            let prepared = DictationTextPreparation.prepare(segments: segments, formatter: TextFormatter(),
                                                            pressEnterEnabled: false, autoPaste: false,
                                                            endedByVoiceStop: true)
            #expect(prepared.command.text.lowercased().contains("salt"))
            #expect(!prepared.command.text.lowercased().contains("halt"))
        }
    }
}
