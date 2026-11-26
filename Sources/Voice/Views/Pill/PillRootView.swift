import SwiftUI
import AppKit

// MARK: - The pill
//
// The panel hosts this view. It gathers the engine's state and the pointer into a
// `PillLookInput`, asks `PillLookBuilder` for the look, lays the look out from the dock's pinned
// point (`PillLayoutEngine`) and draws it as one metaball body (`PillBlobView`). Every change of
// look springs from the old one; `PillTransitions` picks the spring.

struct OverlayPillView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pillInspection) private var inspection
    @Environment(\.pillBackdrop) private var backdrop
    @Bindable var state: RecordingState
    @AppStorage("voice.pillPosition") private var anchor = "bottomCenter"
    @AppStorage("pillSkin") private var storedSkin = "glass"
    @AppStorage("flow.lastPolishLevel") private var lastPolishLevel = "medium"
    /// Diagnostic chip with the last polish engine. Off by default.
    @AppStorage("voice.showEnginePill") private var showEnginePill = false

    var onTap: (() -> Void)?
    /// Polish closure carries the cleanup level: "light" / "medium" / "heavy".
    var onPolish: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onUndoCancel: (() -> Void)?
    var onUndoPaste: (() -> Void)?
    var onStopMeeting: (() -> Void)?
    var onPhaseChange: ((PillPhase) -> Void)?
    /// The clickable area in the hosting view's top-left coordinates.
    var onHitAreaChange: ((CGRect) -> Void)?
    /// The live capture behind the panel (glass skins). Offscreen renders pass a still instead.
    var backdropSource: PillBackdrop?

    /// The phase shown before the current render: decides how the next change moves.
    @State private var shownPhase: PillPhase = .idle
    /// The phase the pill actually drew last (the held working phase while its glow finishes), so the
    /// move out of a held face springs instead of snapping.
    @State private var drawnPhase: PillPhase = .idle
    // Idle hover: open while the pointer is on the pill (or a menu from it is open), with the
    // 100 ms hold of `FlowPillMachine`.
    @State private var hoverMachine = FlowPillMachine()
    @State private var hoverSources: Set<String> = []
    @State private var hoveredSegment: PillReadySegment?
    @State private var tipShown = false
    @State private var tipTask: Task<Void, Never>?
    @State private var collapseTask: Task<Void, Never>?
    @State private var hiddenForHour = false
    @State private var pointer = PillPointer()
    /// Pieces stay drawn while they melt back into the body.
    @State private var shownLead: PillBud?
    @State private var shownTrail: PillBud?
    @State private var shownTip: PillTipText?
    @State private var slowCaption: String?
    /// When the running meeting started (first seen), for the meeting face's elapsed timer.
    @State private var meetingSince: Date?
    /// Ticks while polishing so the progress fill follows its estimate.
    @State private var progressClock = Date()
    /// Real progress from the polish engine (`PillPolishSignal`), reset for each polish.
    @State private var polishState = PillPolishState()
    /// The work the glow bar follows (dictation cleanup or Opt+1), and the working phase kept on screen
    /// for the bar's last sweep and flash after the work ends.
    @State private var glow: PillGlowTrack?
    @State private var heldPhase: PillPhase?
    @State private var holdTask: Task<Void, Never>?
    /// Moving to another screen: the pill shrinks toward its dock as it leaves and grows back as it arrives.
    @State private var switchScale: CGFloat = 1
    @State private var engineToast: EngineToastSnapshot?
    @State private var engineToastShownAt: Date?
    @State private var engineToastDismissTask: Task<Void, Never>?
    @State private var engineToastDetailsOpen = false
    @State private var lastObservedEngine: String?
    /// The finished polish whose Changes card is open (the pill grows into it), and its Original toggle.
    @State private var changesOpenID: UUID?
    @State private var changesOriginal = false

    private var currentBackdrop: PillBackdropFrame? { backdropSource?.frame ?? backdrop }
    private var skin: PillSkin { PillSkin.named(storedSkin).adapted(toBackdropLuma: brightBehind ? 1 : 0) }
    /// The held light-or-dark choice for glass skins (see `PillInk`).
    @State private var brightBehind = false
    private var dock: PillDockEdge { PillDockEdge.from(anchor: anchor) }
    private var open: Bool { hoverMachine.state == .ready }

    private var phase: PillPhase {
        PillPhaseResolver.phase(
            isRecording: state.isRecording,
            isLocked: state.isLocked,
            pendingStart: state.pendingRecordingStart,
            isTranscribing: state.isTranscribing,
            isPolishingSelection: state.isPolishingSelection,
            showingCancelled: state.showingCancelledToast,
            showingUndoPaste: state.showingUndoPasteToast,
            showingPolishDone: state.polishDiff != nil)
    }

    /// What the pill draws: the real phase, or the working phase while its glow finishes.
    private var shownWorkPhase: PillPhase { heldPhase ?? phase }

    private var input: PillLookInput {
        var input = PillLookInput()
        let phase = shownWorkPhase
        input.phase = phase
        input.dock = dock
        input.hovered = open || inspection.idleExpanded
        input.hoveredSegment = hoveredSegment ?? inspection.tip.flatMap(PillReadySegment.init(rawValue:))
        input.tipVisible = tipShown || inspection.tip != nil
        input.notice = state.flowNotice
        input.micHint = state.micHint
        input.showingError = state.showingErrorPill
        input.hiddenForHour = hiddenForHour
        input.meeting = state.isCapturingMeeting
        input.meetingPaused = state.isPaused
        input.meetingDetected = state.isMeetingAppActive
        input.thinkingCaption = slowCaption
        if phase == .polishingSelection {
            input.polishTitle = polishState.loadingModel ? "Loading model…" : "Polishing"
            input.polishProgress = polishState.fraction
        }
        input.autoCleanup = state.polishDiff?.autoCleanup ?? false
        if let diff = state.polishDiff, changesOpenID == diff.id || inspection.changesOpen {
            input.changes = diff
            input.changesOriginal = changesOriginal || inspection.changesOriginal
        }
        input.wandLabel = IdleWandMenu.items.first { $0.level == lastPolishLevel }?.label ?? "Polish"
        return input
    }

    var body: some View {
        let look = PillLookBuilder.look(input, skin: skin)
        let motion = PillTransitions.motion(from: drawnPhase, to: shownWorkPhase)
        GeometryReader { geo in
            let lifted = pointer.location != nil && !look.face.isResting && !look.face.isCard
            let lift = reduceMotion ? 1 : (pointer.pressed && lifted ? skin.motion.pressSink : lifted ? skin.motion.hoverLift : 1)
            let geometry = PillLayoutEngine.geometry(look, dock: dock, in: geo.size, skin: skin, lift: lift)
            PillBlobView(geometry: geometry, look: look,
                         shownLead: look.lead ?? shownLead, shownTrail: look.trail ?? shownTrail, shownTip: look.tip ?? shownTip,
                         live: live, actions: actions, pointer: pointer)
                .animation(skin.motion.spring(for: motion, reduceMotion: reduceMotion), value: look)
                .scaleEffect(switchScale, anchor: dock.pin)
                // A press sinks at once; only the release eases back.
                .animation(reduceMotion || pointer.pressed ? nil : skin.motion.hover, value: lift)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let inside = PillLayoutEngine.hitArea(geometry).insetBy(dx: -2, dy: -2).contains(location)
                        setPointerLocation(inside ? location : nil)
                        setHover("body", inside)
                    case .ended:
                        setPointerLocation(nil)
                        setHover("body", false)
                    }
                }
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pointer.pressed { pointer.pressed = true } }
                    .onEnded { _ in pointer.pressed = false })
                .onChange(of: PillLayoutEngine.hitArea(PillLayoutEngine.geometry(look, dock: dock, in: geo.size, skin: skin)), initial: true) { _, area in
                    onHitAreaChange?(area)
                }
                .onChange(of: look.lead, initial: true) { _, bud in if let bud { shownLead = bud } }
                .onChange(of: state.isCapturingMeeting, initial: true) { _, on in meetingSince = on ? (meetingSince ?? Date()) : nil }
                .onChange(of: look.trail, initial: true) { _, bud in if let bud { shownTrail = bud } }
                .onChange(of: look.tip, initial: true) { _, tip in if let tip { shownTip = tip } }
        }
        .overlay(alignment: .top) { engineToastView }
        .environment(\.pillSkin, skin)
        .environment(\.pillBackdrop, currentBackdrop)
        .onAppear {
            shownPhase = phase
            drawnPhase = shownWorkPhase
            onPhaseChange?(phase)
            lastObservedEngine = PolishStatus.shared.lastEngine
        }
        .onChange(of: currentBackdrop?.luma, initial: true) { _, luma in
            brightBehind = PillInk.bright(brightBehind, luma: luma, busy: phase != .idle)
        }
        .onChange(of: phase) { _, next in
            // Back at rest: take the screen behind as it is now.
            if next == .idle { brightBehind = PillInk.bright(brightBehind, luma: currentBackdrop?.luma, busy: false) }
        }
        .onChange(of: phase) { _, next in phaseChanged(to: next) }
        .onChange(of: shownWorkPhase) { _, drawn in drawnPhase = drawn }
        .onChange(of: state.flowNotice) { _, _ in onPhaseChange?(phase) }
        .onChange(of: state.isCapturingMeeting) { _, _ in onPhaseChange?(phase) }
        // One-line notices leave by themselves; cards run their own timer.
        .task(id: state.flowNotice?.id) {
            guard let notice = state.flowNotice, !notice.isCard else { return }
            try? await Task.sleep(for: .seconds(notice.timeout ?? 3))
            if !Task.isCancelled, state.flowNotice?.id == notice.id { state.flowNotice = nil }
        }
        // Slow steps name themselves after a while ("Writing  4s"); polishing ticks its progress.
        .task(id: phase) { await runSlowCaption(for: phase) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("flow.barHiddenCard"))) { note in
            hiddenForHour = note.userInfo?["show"] as? Bool ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("flow.pillPointerChanged"))) { note in
            setHover("panel", note.userInfo?["inside"] as? Bool ?? false)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("flow.pillPointerExited"))) { _ in
            hoverSources = hoverSources.intersection(["menu"])
            pointer = PillPointer()
            feedHover()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("flow.pillMenu"))) { note in
            let menuOpen = note.userInfo?["open"] as? Bool ?? false
            if menuOpen { clearTip() }
            setHover("menu", menuOpen)
        }
        .onReceive(NotificationCenter.default.publisher(for: PillScreenSwitch.notification)) { note in
            guard !reduceMotion else { return }
            if note.userInfo?[PillScreenSwitch.phaseKey] as? String == "out" {
                withAnimation(.easeIn(duration: PillScreenSwitch.outSeconds)) { switchScale = PillScreenSwitch.shrink }
            } else {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { switchScale = PillScreenSwitch.shrink }
                // 23 Nov 2026: response 0.24 s -> 0.18 s so the return to full size ends with the fade-in.
                withAnimation(.spring(response: 0.18, dampingFraction: 0.82)) { switchScale = 1 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PillPolishSignal.notification)) { note in
            let signal = PillPolishSignal(notification: note)
            guard state.isPolishingSelection, signal.belongs(to: state.polishOperationID) else { return }
            polishState.apply(signal)
            if var track = glow, track.kind == .polish, !track.isComplete {
                let now = Date.timeIntervalSinceReferenceDate
                track.setLoading(signal.loadingModel, at: now)
                if let fraction = signal.fraction { track.report(fraction: fraction, at: now) }
                glow = track
            }
        }
        .environment(\.pillPolish, polishState)
        .environment(\.pillGlow, glow)
        .environment(\.pillGlowFreeze, inspection.glow)
        .onReceive(NotificationCenter.default.publisher(for: .voicePolishComplete)) { _ in presentEngineToast() }
        .onChange(of: PolishStatus.shared.lastEngine) { _, newValue in
            if newValue != lastObservedEngine { lastObservedEngine = newValue; presentEngineToast() }
        }
    }

    // MARK: State changes

    private func phaseChanged(to next: PillPhase) {
        Telemetry.log("pill.phase", properties: ["phase": "\(next)", "from": "\(shownPhase)"])
        let previous = shownPhase
        shownPhase = next
        // Each polish starts its fill from nothing; a finished one leaves no progress behind.
        if (next == .polishingSelection) != (previous == .polishingSelection) { polishState = PillPolishState() }
        updateGlow(from: previous, to: next)
        // Recording started or stopped: one tap each (the system plays it only on a trackpad).
        let recordingNow: (PillPhase) -> Bool = { [.recording, .locked].contains($0) }
        if recordingNow(next) != recordingNow(previous) {
            if recordingNow(next) { PillHaptics.start() } else { PillHaptics.done() }
        }
        if previous == .recording && next == .locked { PillHaptics.lock() }
        if next != .idle {
            _ = hoverMachine.send(.backend(.resting))
            clearTip()
            postHover()
        }
        // Starting a dictation dismisses any notice, so the listening pill is always seen.
        if [.starting, .recording, .locked].contains(next), state.flowNotice != nil { state.flowNotice = nil }
        onPhaseChange?(next)
    }

    /// Starts the glow when work starts; when it ends well, sweeps it to full with a flash and keeps the
    /// working face for `PillGlowTrack.holdSeconds` before the pill moves on. Cancels and errors drop it.
    private func updateGlow(from previous: PillPhase, to next: PillPhase) {
        let now = Date.timeIntervalSinceReferenceDate
        let working: (PillPhase) -> Bool = { $0 == .transcribing || $0 == .polishingSelection }
        if working(next) {
            holdTask?.cancel()
            heldPhase = nil
            if next == .transcribing, glow?.kind != .dictation || glow?.isComplete == true {
                glow = PillGlowTrack(kind: .dictation, start: now,
                                     expected: PillWorkTiming.dictationSeconds(audioSeconds: state.lastRecordingSeconds))
            } else if next == .polishingSelection, glow?.kind != .polish || glow?.isComplete == true {
                var track = PillGlowTrack(kind: .polish, start: now,
                                          expected: PillWorkTiming.polishSeconds(words: state.polishWords))
                track.setLoading(polishState.loadingModel, at: now)
                glow = track
            }
            return
        }
        guard working(previous), var track = glow, !track.isComplete else {
            if !working(previous) && heldPhase == nil { glow = nil }
            if [.starting, .recording, .locked].contains(next) { holdTask?.cancel(); heldPhase = nil; glow = nil }
            return
        }
        // A finished piece of work: paste, the Changes pill, or back to rest without a failure.
        let success = next == .undoPaste || next == .polishDone || (next == .idle && !state.showingErrorPill)
        guard success, !reduceMotion else {
            glow = nil
            heldPhase = nil
            return
        }
        track.complete(at: now)
        glow = track
        heldPhase = previous
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PillGlowTrack.holdSeconds))
            guard !Task.isCancelled else { return }
            heldPhase = nil
            glow = nil
        }
    }

    /// Wispr shows no running captions or counters while it works ("Writing 3s", "Checking"): the spinner
    /// and the polish fill say enough, and the old 1 s / 250 ms tickers re-rendered the pill (lag).
    private func runSlowCaption(for phase: PillPhase) async {
        slowCaption = nil
    }

    // MARK: Hover

    private func setHover(_ source: String, _ inside: Bool) {
        // Most pointer moves change nothing: skip the state write so SwiftUI does not re-render.
        let changed = inside ? hoverSources.insert(source).inserted : hoverSources.remove(source) != nil
        guard changed else { return }
        feedHover()
    }

    /// The pointer's place for the glass highlight. A move under 4 pt is not written: every write
    /// re-renders the pill, and a 4 pt step is below what the soft highlight shows.
    private func setPointerLocation(_ location: CGPoint?) {
        guard let location else {
            if pointer.location != nil { pointer.location = nil }
            return
        }
        if let current = pointer.location, abs(current.x - location.x) < 4, abs(current.y - location.y) < 4 { return }
        pointer.location = location
    }

    private func feedHover() {
        guard phase == .idle else { return }
        send(hoverSources.isEmpty ? .pointerExited : .pointerEntered)
    }

    private func send(_ event: FlowPillEvent) {
        let wasOpen = open
        for effect in hoverMachine.send(event) {
            if case .scheduleCollapse(let generation, let ms) = effect {
                // One timer at a time: a newer change replaces the pending one instead of queueing behind it.
                collapseTask?.cancel()
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(ms))
                    guard !Task.isCancelled else { return }
                    send(.collapseElapsed(generation))
                }
            }
        }
        if wasOpen != open {
            if !open { clearTip() }
            PillDebugLog.write("hover.open=\(open)")
            postHover()
        }
    }

    private func postHover() {
        NotificationCenter.default.post(name: Notification.Name("voice.pillIdleHover"), object: nil,
                                        userInfo: ["expanded": open])
    }

    private func hoverSegment(_ segment: PillReadySegment?) {
        tipTask?.cancel()
        if segment == nil {
            // Leaving one button for the next keeps the tip; leaving the pill clears it.
            tipTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                clearTip()
            }
            return
        }
        hoveredSegment = segment
        if tipShown || hoverSources.contains("menu") { return }
        let delay = segment == .dictate ? skin.motion.tooltipDelayMilliseconds : skin.motion.pickerTooltipDelayMilliseconds
        tipTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, hoveredSegment == segment, open else { return }
            tipShown = true
        }
    }

    private func clearTip() {
        tipTask?.cancel()
        tipShown = false
        hoveredSegment = nil
    }

    // MARK: Actions

    private var live: PillLiveValues {
        PillLiveValues(levels: state.audioLevels, barLevel: state.barLevel, lastPolishLevel: lastPolishLevel,
                       meetingStartedAt: meetingSince)
    }

    private var actions: PillActions {
        var a = PillActions()
        a.dictate = { clearTip(); onTap?() }
        a.polish = { level in clearTip(); onPolish?(level) }
        a.polishOptions = {
            clearTip()
            FlowPolishMenu.show(current: lastPolishLevel) { level in
                lastPolishLevel = level
                onPolish?(level)
            }
        }
        a.newNote = { clearTip(); NotificationCenter.default.post(name: .voiceStartMeetingManual, object: nil) }
        a.cancel = { PillHaptics.press(); onCancel?() }
        a.finish = { if phase == .recording || phase == .locked { PillHaptics.press(); onConfirm?() } }
        // The pill itself grows into the Changes card; no window.
        a.openChanges = {
            guard let diff = state.polishDiff else { return }
            PillHaptics.press()
            changesOriginal = false
            changesOpenID = diff.id
        }
        let openDiff = state.polishDiff?.id
        a.closeChanges = {
            guard changesOpenID != nil else { return }
            changesOpenID = nil
            changesOriginal = false
            if let openDiff, state.polishDiff?.id == openDiff { state.polishDiff = nil }
        }
        a.toggleChangesOriginal = {
            changesOriginal.toggle()
            // Training signal: he looked at the original (linked to the Opt+1 run by its diff id).
            if changesOriginal, let id = state.polishDiff?.id {
                FlowRunLog.followup(id: id.uuidString, kind: "opt1", followup: "original-shown")
            }
        }
        a.undoCancel = { onUndoCancel?() }
        a.undoPaste = { onUndoPaste?() }
        a.hideChanges = { state.polishDiff = nil }
        a.undoHide = { NotificationCenter.default.post(name: Notification.Name("flow.undoBarHide"), object: nil) }
        a.stopMeeting = { PillHaptics.press(); onStopMeeting?() }
        a.openMeeting = {
            NotificationCenter.default.post(name: .voiceOpenMeetingFromNotification, object: nil,
                                            userInfo: ["meetingId": state.activeMeetingId?.uuidString ?? ""])
        }
        let shown = state.flowNotice?.id
        a.dismissNotice = { if state.flowNotice?.id == shown { state.flowNotice = nil } }
        a.copyRecovery = { id in
            guard state.flowNotice?.id == id, let text = state.flowNotice?.recoveryText else { return false }
            return DictationPasteboard.write(text)
        }
        a.hoverSegment = { hoverSegment($0) }
        return a
    }

    // MARK: Engine diagnostics (voice.showEnginePill)

    @ViewBuilder private var engineToastView: some View {
        if let snapshot = engineToast, let shownAt = engineToastShownAt {
            EnginePolishToast(snapshot: snapshot, shownAt: shownAt, detailsOpen: $engineToastDetailsOpen, onTap: {
                engineToastDismissTask?.cancel()
                engineToastDismissTask = nil
                engineToastDetailsOpen.toggle()
            })
            .transition(.opacity)
        }
        if showEnginePill { EnginePolishDebugChip().allowsHitTesting(false) }
    }

    private func presentEngineToast() {
        guard showEnginePill else { return }
        let status = PolishStatus.shared
        guard let engine = status.lastEngine, !engine.isEmpty else { return }
        let latencyMs: Int = {
            if status.lastLatencyMs > 0 { return status.lastLatencyMs }
            if engine.hasPrefix("cloud:groq") { return GroqPolisher.shared.lastLatencyMs }
            if engine.hasPrefix("cloud:") { return CerebrasPolisher.shared.lastLatencyMs }
            if engine.hasPrefix("local:") { return Qwen3Polisher.shared.lastLatencyMs }
            return 0
        }()
        withAnimation(.easeOut(duration: 0.22)) {
            engineToast = EngineToastSnapshot(engine: engine, latencyMs: latencyMs, reason: status.lastReason,
                                              inputWordCount: status.lastInputWordCount,
                                              outputWordCount: status.lastOutputWordCount,
                                              fallbackCount: status.lastFallbackCount,
                                              sanitizerRejected: status.lastSanitizerRejected)
            engineToastShownAt = Date()
            engineToastDetailsOpen = false
        }
        engineToastDismissTask?.cancel()
        engineToastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PillTiming.engineToastSeconds))
            if Task.isCancelled || engineToastDetailsOpen { return }
            withAnimation(.easeIn(duration: 0.3)) { engineToast = nil; engineToastShownAt = nil }
        }
    }
}
