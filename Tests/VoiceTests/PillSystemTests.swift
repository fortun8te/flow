import Testing
import CoreGraphics
@testable import Voice

@Suite("Pill state machine, skins and notices", .serialized) @MainActor
struct PillSystemTests {
    // MARK: Transitions

    @Test("The hotkey answers on the next frame: no animation from rest into capture")
    func hotkeyIsInstant() {
        for to: PillPhase in [.starting, .recording, .locked] {
            #expect(PillTransitions.motion(from: .idle, to: to) == .instant)
        }
        // A new dictation interrupts a status at once too.
        for from: PillPhase in [.polishDone, .cancelled, .undoPaste, .transcribing] {
            #expect(PillTransitions.motion(from: from, to: .recording) == .instant)
            #expect(PillTransitions.motion(from: from, to: .starting) == .instant)
        }
    }

    @Test("Every way back to rest settles; changes inside a dictation morph")
    func settleAndMorph() {
        for from in PillPhase.allCases where from != .idle {
            #expect(PillTransitions.motion(from: from, to: .idle) == .settle)
        }
        #expect(PillTransitions.motion(from: .starting, to: .recording) == .morph)
        #expect(PillTransitions.motion(from: .recording, to: .locked) == .morph)
        #expect(PillTransitions.motion(from: .locked, to: .transcribing) == .morph)
        #expect(PillTransitions.motion(from: .polishingSelection, to: .polishDone) == .morph)
    }

    @Test("Every pair of phases has exactly one defined motion")
    func everyPairDefined() {
        for from in PillPhase.allCases {
            for to in PillPhase.allCases {
                let motion = PillTransitions.motion(from: from, to: to)
                if from == to { #expect(motion == .instant) }
                #expect([PillMotion.instant, .morph, .settle].contains(motion))
            }
        }
    }

    @Test("Every step springs, and nothing animates with Reduce Motion")
    func motionAnimations() {
        let motion = PillSkin.standard.motion
        #expect(motion.spring(for: .instant, reduceMotion: false) != nil)
        #expect(motion.quick.response < motion.morph.response)
        #expect(motion.spring(for: .morph, reduceMotion: true) == nil)
        #expect(motion.spring(for: .settle, reduceMotion: true) == nil)
        #expect(motion.spring(for: .morph, reduceMotion: false) != nil)
    }

    // MARK: Skins

    @Test("Stored skin names map to skins; Jet is the default and retired names map forward")
    func skinNames() {
        #expect(PillSkin.named("default") == .standard)
        #expect(PillSkin.named("jet") == .jet)
        #expect(PillSkin.named("clear") == .clear)
        #expect(PillSkin.named("liquid") == .liquid)
        #expect(PillSkin.named("glassDark") == .jet)
        #expect(PillSkin.named("glassLight") == .liquid)
        for unknown in ["black", "niche", nil, ""] as [String?] {
            #expect(PillSkin.named(unknown) == .jet)
        }
        #expect(Set(PillSkin.all.map(\.id)).count == PillSkin.all.count)
        #expect(PillSkin.jet.isGlass && PillSkin.clear.isGlass && PillSkin.liquid.isGlass && !PillSkin.standard.isGlass)
    }

    @Test("See-through glass flips to dark ink over a bright screen; Jet and Default never do")
    func adaptiveInk() {
        #expect(PillSkin.liquid.adapted(toBackdropLuma: 0.9).palette.ink != PillSkin.liquid.palette.ink)
        #expect(PillSkin.clear.adapted(toBackdropLuma: 0.9).palette.ink != PillSkin.clear.palette.ink)
        #expect(PillSkin.liquid.adapted(toBackdropLuma: 0.2) == .liquid)
        #expect(PillSkin.jet.adapted(toBackdropLuma: 0.9) == .jet)
        #expect(PillSkin.standard.adapted(toBackdropLuma: 0.9) == .standard)
    }

    @Test("Every skin keeps the open pill and picker sizes the panel's hit testing uses")
    func skinsShareHitGeometry() {
        for skin in PillSkin.all {
            #expect(skin.metrics.readyLength == PillHitBand.idlePillSize.width)
            #expect(skin.metrics.thickness == PillHitBand.idlePillSize.height)
            #expect(skin.metrics.pickerSize == PillHitBand.pickerButtonSize)
            #expect(skin.metrics.pickerGap == PillHitBand.pickerGap)
        }
    }

    // MARK: Looks

    private func look(_ change: (inout PillLookInput) -> Void) -> PillLook {
        var input = PillLookInput()
        change(&input)
        return PillLookBuilder.look(input, skin: .standard)
    }

    @Test("One body for every state: each phase has one face, and open pills are one pill thick")
    func facesPerPhase() {
        #expect(look { _ in }.face == .resting)
        #expect(look { $0.hovered = true }.face == .ready(hovered: nil))
        #expect(look { $0.phase = .starting }.face == .starting)
        #expect(look { $0.phase = .recording }.face == .listening)
        #expect(look { $0.phase = .locked }.face == .handsFree)
        #expect(look { $0.phase = .transcribing }.face == .processing)
        #expect(look { $0.phase = .cancelled }.face == .cancelled)
        #expect(look { $0.phase = .undoPaste }.face == .pasted)
        #expect(look { $0.showingError = true }.face == .error)
        for phase: PillPhase in [.starting, .recording, .locked, .transcribing, .polishingSelection, .polishDone, .cancelled, .undoPaste] {
            #expect(look { $0.phase = phase }.size.height == PillSkin.standard.metrics.thickness)
        }
    }

    @Test("Notices grow out of the same body: lines replace an idle or busy face, cards replace everything")
    func noticesAreLooks() {
        let line = FlowPillNotice.wispr(forToast: "Select text first")
        #expect(look { $0.notice = line }.face == .line(text: "Select text to apply a transform", tone: .warning))
        // Processing and polishing show their own face: a line never replaces the spinner.
        #expect(look { $0.phase = .polishingSelection; $0.notice = line }.face == .polishing(title: "Polishing"))
        #expect(look { $0.phase = .transcribing; $0.notice = line }.face == .processing)
        // A dictation in progress is never covered by a line.
        #expect(look { $0.phase = .recording; $0.notice = line }.face == .listening)
        let card = FlowPillNotice.permission(.microphone)
        let cardLook = look { $0.phase = .recording; $0.notice = card }
        #expect(cardLook.face == .card(card))
        #expect(cardLook.size.width >= PillSkin.standard.metrics.cardMinWidth)
        #expect(cardLook.radius == PillSkin.standard.surface.cardCornerRadius)
    }

    @Test("Side docks keep every face upright; lines and cards fit beside the dock")
    func sideDockLooks() {
        let resting = look { $0.dock = .left }
        #expect(resting.size == CGSize(width: 8, height: 40))
        let long = FlowPillNotice.wispr(forToast: "This is a long notice that keeps going past the room beside a side dock")
        #expect(look { $0.dock = .left; $0.notice = long }.size.width <= PillLayout.sideAttachMaxWidth)
        let card = look { $0.dock = .right; $0.notice = FlowPillNotice.permission(.accessibility) }
        #expect(card.size.width <= PillLayout.sideCardMaxWidth)
    }

    @Test("Hover tips appear only for the open pill and hands-free")
    func tips() {
        #expect(look { $0.hovered = true; $0.hoveredSegment = .dictate; $0.tipVisible = true }.tip?.label == "Dictate")
        #expect(look { $0.hovered = true; $0.hoveredSegment = .wand; $0.tipVisible = true; $0.wandLabel = "Spell" }.tip?.label == "Spell")
        #expect(look { $0.phase = .recording; $0.tipVisible = true }.tip == nil)
        #expect(look { $0.hovered = true; $0.hoveredSegment = .dictate }.tip == nil)
    }

    @Test("A whisper reaches about 40% of the bar, speech most of it, silence stays at rest")
    func waveGain() {
        let smoother = PillWaveSmoother()
        #expect(smoother.shape(0.005, dt: 1.0 / 60) == 0)
        let whisper = smoother.shape(0.04, dt: 1.0 / 60)
        #expect(whisper >= 0.35 && whisper <= 0.5)
        let speech = PillWaveSmoother()
        _ = speech.shape(0.6, dt: 1.0 / 60)
        let normal = speech.shape(0.35, dt: 1.0 / 60)
        #expect(normal >= 0.6 && normal <= 0.85)
        // Headroom: even the loudest recent peak leaves the bars short of full (no pinned "maxed" look).
        #expect(PillWaveSmoother().shape(0.9, dt: 1.0 / 60) < 0.9)
        // Fast attack, slower release.
        let lively = PillWaveSmoother()
        _ = lively.step(toward: 0.5, at: 0)
        let rise = lively.step(toward: 0.5, at: 0.03)
        #expect(rise > 0.55)
        _ = lively.step(toward: 0, at: 0.06)
        #expect(lively.step(toward: 0, at: 0.09) > 0.2)
    }

    // MARK: Notices

    @Test("Opt+1 with nothing readable selected is one short error line, not a paragraph")
    func selectTextFirst() {
        for message in ["Couldn't read selected text. Select text to polish.",
                        "Couldn’t read selected text. Select text to polish.",
                        "Select text first", "Select text in a supported field to polish."] {
            let notice = FlowPillNotice.wispr(forToast: message)
            #expect(notice?.variant == .mini)
            #expect(notice?.line == "Select text to apply a transform")
            #expect(notice?.tone == .warning)
            #expect(notice?.timeout == 6)
            #expect(notice?.isCard == false)
        }
    }

    @Test("Any message becomes one short line")
    func compactLines() {
        #expect(FlowPillNotice.compactLine("Done.") == "Done")
        #expect(FlowPillNotice.compactLine("Selection changed. Select the text again.") == "Selection changed")
        #expect(FlowPillNotice.compactLine("Getting speech recognition ready…") == "Getting speech recognition ready…")
        #expect(FlowPillNotice.compactLine("You have <1 minute left before you reach the 20 minute limit!")
                == "Less than a minute left")
        #expect(FlowPillNotice.compactLine("Meeting saved — open it from History") == "Meeting saved")
    }

    @Test("Preparing notices are quiet lines; the rest of the standard notices are cards")
    func cardsAndLines() {
        let preparing = FlowPillNotice.speechNotReady(.loading)
        #expect(!preparing.isCard)
        #expect(preparing.tone == .info)
        #expect(FlowPillNotice.speechNotReady(.notDownloaded).isCard)
        #expect(FlowPillNotice.permission(.microphone).isCard)
        #expect(FlowPillNotice.wispr(forToast: "Already looks great")?.isCard == false)
    }

    @Test("Processing is bars and a spinner with no words, however long it takes")
    func processingHasNoWords() {
        let slow = look { $0.phase = .transcribing; $0.thinkingCaption = "Writing  4s" }
        #expect(slow.face == .processing)
        #expect(slow.size == CGSize(width: PillWispr.processingWidth, height: 30))
        let overdue = look { $0.phase = .transcribing; $0.thinkingCaption = "Still working" }
        #expect(overdue.face == .processing)
    }

    @Test("Polish shows the transform name with the spinner, and no progress text")
    func polishingLabel() {
        let polishing = look { $0.phase = .polishingSelection; $0.polishTitle = "Checking"; $0.polishProgress = 0.7 }
        #expect(polishing.face == .polishing(title: "Checking"))
        #expect(polishing.size == CGSize(width: 136, height: 30))
    }

    @Test("Done is 152 x 30; the cleanup nudge fits its words; a failure is the 91 x 30 error pill with no words")
    func finishedAndErrorSizes() {
        let done = look { $0.phase = .polishDone }
        #expect(done.face == .polished(autoCleanup: false))
        #expect(done.size == CGSize(width: 152, height: 30))
        let cleaned = look { $0.phase = .polishDone; $0.autoCleanup = true }
        #expect(cleaned.face == .polished(autoCleanup: true))
        #expect(cleaned.size.width > 100 && cleaned.size.width != 152)
        let failed = look { $0.showingError = true }
        #expect(failed.face == .error)
        #expect(failed.size == CGSize(width: 91, height: 30))
    }

    @Test("Wispr's timings: 5 s for Done, 7 s for the first three cleanup nudges then 5 s, 100 ms content and 180 ms size")
    func wisprTimings() {
        #expect(PillWispr.changesSeconds(autoCleanup: false, earlierShowings: 0) == 5)
        #expect(PillWispr.changesSeconds(autoCleanup: false, earlierShowings: 9) == 5)
        #expect(PillWispr.changesSeconds(autoCleanup: true, earlierShowings: 0) == 7)
        #expect(PillWispr.changesSeconds(autoCleanup: true, earlierShowings: 2) == 7)
        #expect(PillWispr.changesSeconds(autoCleanup: true, earlierShowings: 3) == 5)
        #expect(PillWispr.contentDuration == 0.1)
        #expect(PillWispr.sizeDuration == 0.18)
        #expect(PillWispr.polishFillSeconds == 7)
    }

    @Test("Appendix A durations for the notices the pill still shows")
    func appendixDurations() {
        let good = FlowPillNotice.wispr(forToast: "Already looks great")
        #expect(good?.line == "Your text looks good!")
        #expect(good?.timeout == 3)
        #expect(good?.quiet == true)
        let busy = FlowPillNotice.wispr(forToast: "Polish unavailable. Try again.")
        #expect(busy?.timeout == 3)
        #expect(FlowPillNotice.wispr(forToast: "Polished text sent") == nil)
        let slow = FlowPillNotice.wispr(forToast: "Transcription took too long")
        #expect(slow?.timeout == 8)
        #expect(slow?.message == "Your audio is saved for retrying")
    }

    // MARK: Pillbugs regressions

    @Test("A running meeting keeps its face and Stop button over lines and hover")
    func meetingStopStaysReachable() {
        let line = FlowPillNotice.wispr(forToast: "Selection changed. Select the text again.")
        #expect(look { $0.meeting = true; $0.notice = line }.face == .meeting(paused: false))
        #expect(look { $0.meeting = true; $0.hovered = true }.face == .meeting(paused: false))
        #expect(look { $0.meeting = true; $0.meetingPaused = true; $0.hovered = true }.face == .meeting(paused: true))
    }

    @Test("A card or failure flash never covers a running meeting: the face and Stop stay, the card waits for the end")
    func cardWaitsForMeeting() {
        let card = FlowPillNotice.permission(.microphone)
        #expect(look { $0.meeting = true; $0.notice = card }.face == .meeting(paused: false))
        #expect(look { $0.meeting = true; $0.meetingPaused = true; $0.notice = card }.face == .meeting(paused: true))
        #expect(look { $0.meeting = true; $0.showingError = true }.face == .meeting(paused: false))
        // Once the meeting has ended, the same card takes the pill as before.
        #expect(look { $0.meeting = false; $0.notice = card }.face == .card(card))
    }

    @Test("A card never covers a hands-free dictation: Cancel and Finish stay on the pill")
    func cardKeepsHandsFreeControls() {
        let card = FlowPillNotice.permission(.microphone)
        let locked = look { $0.phase = .locked; $0.notice = card }
        #expect(locked.face == .handsFree)
        #expect(locked.lead == .cancel)
        #expect(locked.trail == .finish)
    }

    // MARK: Hit area

    @Test("A measured clickable area becomes a bottom-based band with a margin")
    func measuredBand() {
        let band = PillHitBand.measured(CGRect(x: 100, y: 200, width: 80, height: 30), boundsHeight: 300)
        #expect(band == CGRect(x: 96, y: 66, width: 88, height: 38))
        #expect(PillHitBand.measured(.null, boundsHeight: 300) == nil)
        #expect(PillHitBand.measured(.zero, boundsHeight: 300) == nil)
    }
}
