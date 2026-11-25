import Testing
import Foundation
@testable import Voice

@Suite struct CancelAndEscapeTests {
    let audio = URL(fileURLWithPath: "/tmp/kept.caf")

    @Test func undoPrefersKeptAudioOverPartialText() {
        #expect(CancelUndoPlan.make(text: " hello ", audioURL: audio, fileExists: { _ in true })
                == .transcribeAudio(audio, fallbackText: "hello"))
    }
    @Test func undoWithAudioOnlyStillRestores() {
        #expect(CancelUndoPlan.make(text: "", audioURL: audio, fileExists: { _ in true })
                == .transcribeAudio(audio, fallbackText: ""))
    }
    @Test func undoFallsBackToTextWhenAudioGone() {
        #expect(CancelUndoPlan.make(text: "hi there", audioURL: audio, fileExists: { _ in false }) == .pasteText("hi there"))
        #expect(CancelUndoPlan.make(text: "  ", audioURL: nil, fileExists: { _ in false }) == .nothing)
    }

    @Test func escapeGoesToDictationWhenNoOverlay() {
        #expect(EscapeRouting().dictationShouldHandleEscape())
    }
    @Test func escapeSkipsDictationWhileScreenshotOverlayIsUp() {
        var r = EscapeRouting(); let t = Date()
        r.overlayChanged(active: true, at: t)
        #expect(!r.dictationShouldHandleEscape(at: t.addingTimeInterval(5)))
    }
    @Test func escapeSkipsDictationForAMomentAfterOverlayCloses() {
        var r = EscapeRouting(); let t = Date()
        r.overlayChanged(active: true, at: t)
        r.overlayChanged(active: false, at: t.addingTimeInterval(3))
        #expect(!r.dictationShouldHandleEscape(at: t.addingTimeInterval(3.1)))
        #expect(r.dictationShouldHandleEscape(at: t.addingTimeInterval(3.5)))
    }
    @Test func lostEndMessageDoesNotSilenceEscapeForever() {
        var r = EscapeRouting(); let t = Date()
        r.overlayChanged(active: true, at: t)
        #expect(r.dictationShouldHandleEscape(at: t.addingTimeInterval(EscapeRouting.maxOverlaySeconds + 1)))
    }
}
