import Testing
import AppKit
@testable import Voice

@Suite("Pill overlay logic")
struct PillOverlayLogicTests {
    // MARK: Phase resolution

    private func phase(recording: Bool = false, locked: Bool = false, pending: Bool = false,
                       transcribing: Bool = false, polishing: Bool = false,
                       cancelled: Bool = false, undo: Bool = false) -> PillPhase {
        PillPhaseResolver.phase(isRecording: recording, isLocked: locked, pendingStart: pending,
                                isTranscribing: transcribing, isPolishingSelection: polishing,
                                showingCancelled: cancelled, showingUndoPaste: undo)
    }

    @Test("Every flag combination resolves to one phase, idle only when nothing is active")
    func phasePrecedence() {
        #expect(phase() == .idle)
        #expect(phase(pending: true) == .starting)
        #expect(phase(recording: true) == .recording)
        #expect(phase(recording: true, locked: true) == .locked)
        #expect(phase(transcribing: true) == .transcribing)
        #expect(phase(polishing: true) == .polishingSelection)
        #expect(phase(cancelled: true) == .cancelled)
        #expect(phase(undo: true) == .undoPaste)
    }

    @Test("A new recording wins over a transcription that is still finishing")
    func recordingBeatsTranscribing() {
        #expect(phase(recording: true, transcribing: true) == .recording)
        #expect(phase(pending: true, transcribing: true) == .starting)
        #expect(phase(recording: true, transcribing: true, cancelled: true, undo: true) == .recording)
    }

    @Test("A latched lock stays visible even if the engine stopped, so it can be cancelled")
    func lockWithoutRecording() {
        #expect(phase(recording: false, locked: true) == .locked)
        #expect(phase(locked: true, transcribing: true) == .locked)
    }

    @Test("Cancel and undo toasts do not hide processing")
    func toastsYieldToProcessing() {
        #expect(phase(transcribing: true, cancelled: true) == .transcribing)
        #expect(phase(transcribing: true, undo: true) == .transcribing)
        #expect(phase(cancelled: true, undo: true) == .cancelled)
    }

    // MARK: Timing

    @Test("Timing constants match the backend dismiss timers")
    func timing() {
        #expect(PillTiming.cancelToastSeconds == 3.0)      // VoiceApp.showCancelledToast sleeps 3 s
        #expect(PillTiming.undoPasteToastSeconds == 3.5)   // VoiceApp.showUndoPasteToast sleeps 3.5 s
        #expect(PillTiming.idleSettleDelay == 0)
        #expect(PillTiming.frameMoveDuration(heightChanged: true, reduceMotion: false) == 0.18)
        #expect(PillTiming.frameMoveDuration(heightChanged: false, reduceMotion: false) < 0.05)
    }

    @Test("Reduce Motion makes pill frame moves instant")
    func reduceMotionInstant() {
        #expect(PillTiming.frameMoveDuration(heightChanged: true, reduceMotion: true) == 0)
        #expect(PillTiming.frameMoveDuration(heightChanged: false, reduceMotion: true) == 0)
    }

    @Test("Permission notices open the privacy pane for their specific request")
    func currentPermissionNotices() {
        let cases = [
            ("Enable Flow under Privacy → Microphone, then try again.", "flow.openMicrophonePrivacy"),
            ("Accessibility access required for Polish", "flow.openAccessibilityPrivacy"),
            ("Allow Flow in System Settings → Privacy & Security → Screen Recording to capture meeting audio.",
             "flow.openScreenRecordingPrivacy"),
        ]
        for (message, notification) in cases {
            let notice = FlowPillNotice.wispr(forToast: message)
            #expect(notice?.variant == .standard)
            #expect(notice?.actions == [.init(title: "Open System Settings", notification: notification)])
        }
        #expect(FlowPillNotice.permissionNotice(for: "Microphone disconnected") == nil)
    }

    @Test("Speech readiness differentiates active preparation from errors that need settings")
    func speechReadinessNotices() {
        let download = FlowPillNotice.speechNotReady(.downloading(progress: 0.45))
        let load = FlowPillNotice.speechNotReady(.loading)
        #expect(download.kind == .preparing && load.kind == .preparing)
        #expect(download.message != load.message)
        #expect(download.actions.isEmpty && load.actions.isEmpty)
        #expect(download.quiet && load.quiet)
        for state: ModelState in [.notDownloaded, .error("network failure")] {
            let notice = FlowPillNotice.speechNotReady(state)
            #expect(notice.kind == .modelUnavailable)
            #expect(notice.actions.map(\.notification) == ["flow.openSpeechModels"])
        }
    }

    @Test("An app switch reports where dictation went without suggesting an unsafe paste")
    func appSwitchNotices() {
        let copied = FlowPillNotice.appSwitchNotice(for: "You switched apps. Dictation copied.")
        #expect(copied?.variant == .mini)
        #expect(copied?.title == "You switched apps. Dictation copied.")
        #expect(copied?.actions.isEmpty == true)

        let history = FlowPillNotice.appSwitchNotice(for: "You switched apps. Dictation is in history.")
        #expect(history?.variant == .standard)
        #expect(history?.message == "You switched apps. Your text is in Dictations.")
        #expect(history?.actions == [.init(title: "Open Dictations", notification: "flow.openHistory")])
        #expect(FlowPillNotice.appSwitchNotice(for: "Unable to paste") == nil)
    }

    @Test("A rejected edit explains that the original was kept")
    func polishSafetyNotice() {
        let notice = FlowPillNotice.wispr(forToast: "Couldn't improve this text. It would drop or add a negation.")
        #expect(notice?.variant == .mini)
        #expect(notice?.title == "Kept your text as written.")
    }

    @Test("Phases with words are the ones that show a caption beside a side-docked pill")
    func phasesWithWords() {
        for phase: PillPhase in [.polishingSelection, .polishDone, .cancelled, .undoPaste, .transcribing, .starting] {
            #expect(phase.hasWords)
        }
        for phase: PillPhase in [.idle, .recording, .locked] {
            #expect(!phase.hasWords)
        }
    }

    @Test("Bad side fractions fall back to the middle or clamp")
    func fraction() {
        #expect(PillLayout.clampedFraction(nil) == 0.5)
        #expect(PillLayout.clampedFraction(.nan) == 0.5)
        #expect(PillLayout.clampedFraction(.infinity) == 0.5)
        #expect(PillLayout.clampedFraction(-1) == 0)
        #expect(PillLayout.clampedFraction(2) == 1)
        #expect(PillLayout.clampedFraction(0.3) == 0.3)
    }

    @Test("A measured clickable area flips to the panel's bottom-based coordinates")
    func measuredBand() {
        let native = CGPoint(x: 150, y: 190)
        let flipped = PillHitBand.bottomPoint(native, height: 210, flipped: true)
        #expect(flipped == CGPoint(x: 150, y: 20))
        #expect(PillHitBand.bottomPoint(flipped, height: 210, flipped: false) == flipped)
        let band = PillHitBand.measured(CGRect(x: 120, y: 170, width: 60, height: 30), boundsHeight: 210, margin: 0)
        #expect(band?.contains(flipped) == true)
        #expect(band?.contains(native) == false)
    }
}
