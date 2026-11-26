import SwiftUI
import AppKit

// MARK: - The one body
//
// `PillBlobView` draws every piece of the pill (the body, a tip, the buds beside it) as one
// metaball field in PillShaders.metal, and places each piece's content on top. It is
// `Animatable` over `PillGeometry`, so the shape and the content positions spring together, frame
// by frame, from one look to the next. Content cross-fades are timed to the shape: the old face
// leaves fast, the new one waits for the shape to arrive.

/// Everything the pill can do when clicked.
struct PillActions {
    var dictate: () -> Void = {}
    var polish: (String) -> Void = { _ in }
    var polishOptions: () -> Void = {}
    var newNote: () -> Void = {}
    var cancel: () -> Void = {}
    var finish: () -> Void = {}
    var openChanges: () -> Void = {}
    /// Fold the Changes card back into the pill (Esc, a click elsewhere, idle, Undo).
    var closeChanges: () -> Void = {}
    var toggleChangesOriginal: () -> Void = {}
    /// The "Done. See changes" pill timed out: clear the finished result.
    var hideChanges: () -> Void = {}
    var undoCancel: () -> Void = {}
    var undoPaste: () -> Void = {}
    var undoHide: () -> Void = {}
    var stopMeeting: () -> Void = {}
    var openMeeting: () -> Void = {}
    var dismissNotice: () -> Void = {}
    var copyRecovery: (UUID) -> Bool = { _ in false }
    var hoverSegment: (PillReadySegment?) -> Void = { _ in }
}

/// What the waveform and labels read live from the engine.
struct PillLiveValues {
    var levels: [Float] = []
    var barLevel: Float = 0
    var lastPolishLevel = "medium"
    /// When the running meeting started, for the elapsed timer. Nil until the engine knows it.
    var meetingStartedAt: Date?
}

/// Pointer state the body reacts to.
struct PillPointer: Equatable {
    var location: CGPoint?
    var pressed = false
}

struct PillBlobView: View, Animatable {
    var geometry: PillGeometry
    var animatableData: PillGeometry {
        get { geometry }
        set { geometry = newValue }
    }
    let look: PillLook
    /// Buds and tip still drawn while they melt back into the body.
    let shownLead: PillBud?
    let shownTrail: PillBud?
    let shownTip: PillTipText?
    let live: PillLiveValues
    let actions: PillActions
    let pointer: PillPointer
    /// Previews only: fades the body's content (frame strips show the cross-fade).
    var contentOpacity: Double = 1
    @Environment(\.pillSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The work the glow follows, and a fixed frame for offscreen inspection.
    @Environment(\.pillGlow) private var glow
    @Environment(\.pillGlowFreeze) private var frozenGlow

    /// The glow shows only on the working faces (dictation processing, Opt+1 polishing).
    private var glowFace: Bool {
        switch look.face {
        case .processing, .polishing: return true
        default: return false
        }
    }

    var body: some View {
        if glowFace, let frozenGlow {
            content(glow: frozenGlow)
        } else if glowFace, let glow {
            // The only clock the glow needs, and only while there is work. No frame cap: the bar and its sheen
            // draw at the display's full refresh rate (60 or 120 Hz) while visible.
            TimelineView(.animation) { tick in
                content(glow: still(glow.frame(at: tick.date.timeIntervalSinceReferenceDate)))
            }
        } else {
            content(glow: .off)
        }
    }

    /// Reduce Motion: the bar still fills, without the travelling sheen.
    private func still(_ frame: PillGlowFrame) -> PillGlowFrame {
        guard reduceMotion else { return frame }
        var copy = frame
        copy.sheen = -2
        return copy
    }

    private func content(glow: PillGlowFrame) -> some View {
        ZStack(alignment: .topLeading) {
            PillBodyLayer(geometry: geometry, look: look, pointer: pointer, glow: glow)
            bodyContent.opacity(contentOpacity).environment(\.pillGlowFrame, glow)
            budContent(.lead, shownLead)
            budContent(.trail, shownTrail)
            tipContent
        }
    }

    // MARK: Content

    /// 0 until the shape has nearly reached the face's size, then up to 1: words appear only
    /// once the body can hold them.
    private var fit: Double {
        let frame = geometry.slot(.body).rect
        guard look.size.width > 0, look.size.height > 0 else { return 1 }
        let ratio = min(frame.width / look.size.width, frame.height / look.size.height,
                        look.size.width / max(frame.width, 1), look.size.height / max(frame.height, 1))
        return Double(min(1, max(0, (ratio - 0.86) / 0.14)))
    }

    private var bodyContent: some View {
        let frame = geometry.slot(.body)
        // Wispr's content curve for every change: the old face and the new one both take 100 ms.
        return PillFaceView(face: look.face, size: look.size, live: live, actions: actions)
            .opacity(fit)
            .id(look.face.key)
            .transition(.asymmetric(
                insertion: .opacity.animation(PillWispr.contentCurve),
                removal: .opacity.animation(PillWispr.contentCurve)))
            .frame(width: frame.rect.width, height: frame.rect.height)
            .clipShape(PillShape(radius: frame.radius))
            .offset(x: frame.rect.minX, y: frame.rect.minY)
    }

    @ViewBuilder private func budContent(_ slot: PillSlot, _ bud: PillBud?) -> some View {
        let frame = geometry.slot(slot)
        if let bud, frame.presence > 0.02 {
            PillBudView(bud: bud, actions: actions)
                .frame(width: frame.rect.width, height: frame.rect.height)
                .opacity(Double(min(1, max(0, (frame.presence - 0.55) / 0.45))))
                .offset(x: frame.rect.minX, y: frame.rect.minY)
        }
    }

    @ViewBuilder private var tipContent: some View {
        let frame = geometry.slot(.tip)
        if let tip = shownTip, frame.presence > 0.02 {
            HStack(spacing: 4) {
                Text(tip.label).font(skin.type.font(.tooltip))
                if !tip.key.isEmpty { Text(tip.key).font(skin.type.font(.tooltipKey)) }
            }
            .foregroundStyle(skin.palette.ink)
            .lineLimit(1)
            .padding(.horizontal, skin.metrics.tooltipPadding)
            .frame(width: frame.rect.width, height: frame.rect.height)
            .clipped()
            .opacity(Double(min(1, max(0, (frame.presence - 0.55) / 0.45))))
            .offset(x: frame.rect.minX, y: frame.rect.minY)
            .allowsHitTesting(false)
        }
    }
}

/// The metaball field itself, drawn by the skin's renderer.
struct PillBodyLayer: View {
    let geometry: PillGeometry
    let look: PillLook
    let pointer: PillPointer
    /// The progress glow drawn into the body (off outside work).
    var glow: PillGlowFrame = .off
    @Environment(\.pillSkin) private var skin
    @Environment(\.pillBackdrop) private var backdrop
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let library = ShaderLibrary.bundle(.module)

    var body: some View {
        // Only the glass's slow drift needs a clock here. The progress glow's clock is in `PillBlobView`.
        let moving = !reduceMotion && skin.isGlass && skin.motion.drift > 0 && !look.face.isResting
        if moving {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tick in
                layer(time: tick.date.timeIntervalSinceReferenceDate)
            }
        } else {
            layer(time: 0)
        }
    }

    @ViewBuilder private func layer(time: Double) -> some View {
        let values = geometry.shaderValues
        let s = skin.surface
        // The progress glow: fill, sheen phase, completion flash, strength. A negative fill is "off".
        let sweep = glow
        let hover: Float = pointer.location == nil || look.face.isResting ? 0 : 1
        let p = pointer.location ?? .zero
        switch skin.renderer {
        case .plate:
            plate(values: values, sweep: sweep, hover: hover, pointer: p)
        case .glass(let glass):
            if let backdrop {
                Image(decorative: backdrop.image, scale: backdrop.scale)
                    .resizable()
                    .layerEffect(Self.library.pillGlass(
                        .floatArray(values), .float(geometry.blend), .float(0.6),
                        .color(glass.tint), .color(glass.rim), .float(glass.bevel), .float(glass.refraction),
                        .float(glass.dispersion), .float(glass.frost), .float(glass.magnify), .float(glass.dark ? 1 : 0),
                        .float(glass.saturation),
                        .color(s.shadow), .float(s.shadowRadius), .float(s.shadowY),
                        .color(skin.palette.light), .float4(Float(sweep.fill), Float(sweep.sheen), Float(sweep.flash), Float(sweep.strength)),
                        .float2(p), .float(hover),
                        .float(skin.motion.drift > 0 ? time / skin.motion.drift : 0)),
                        maxSampleOffset: CGSize(width: glass.refraction * 1.6 + glass.frost + 30, height: glass.refraction * 1.6 + glass.frost + 30))
            } else {
                // No capture (no Screen Recording permission, or offscreen): a blur behind the
                // body and the glass's own rim and tint on top.
                let body = geometry.slot(.body)
                ZStack(alignment: .topLeading) {
                    Color.clear
                    Color.clear
                        .background(.ultraThinMaterial, in: PillShape(radius: body.radius))
                        .frame(width: body.rect.width, height: body.rect.height)
                        .offset(x: body.rect.minX, y: body.rect.minY)
                        .environment(\.colorScheme, glass.dark ? .dark : .light)
                    plate(values: values, sweep: sweep, hover: hover, pointer: p, fill: glass.fallbackTint, edge: glass.rim.opacity(0.6))
                }
            }
        }
    }

    private func plate(values: [Float], sweep: PillGlowFrame, hover: Float, pointer: CGPoint,
                       fill: Color? = nil, edge: Color? = nil) -> some View {
        let s = skin.surface
        let resting = look.face.isResting
        return Rectangle().fill(Color.black)
            .colorEffect(Self.library.pillPlate(
                .floatArray(values), .float(geometry.blend), .float(0.6),
                .color(fill ?? (resting ? s.restingFill : s.fill)),
                .color(edge ?? (look.tint ?? (resting ? s.restingEdge : (hover > 0 ? s.edgeHover : s.edge)))),
                .float(look.tint != nil ? 1.25 : s.edgeWidth),
                .color(resting ? .clear : s.shadow), .float(s.shadowRadius), .float(s.shadowY),
                .color(skin.palette.light), .float4(Float(sweep.fill), Float(sweep.sheen), Float(sweep.flash), Float(sweep.strength)),
                .float2(pointer), .float(hover)))
    }
}

// MARK: - Faces (the body's content)

struct PillFaceView: View {
    let face: PillFace
    let size: CGSize
    let live: PillLiveValues
    let actions: PillActions
    @Environment(\.pillSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let m = skin.metrics, p = skin.palette
        Group {
            switch face {
            case .resting:
                Color.clear
            case .ready:
                PillGlyphButton(segment: .dictate, label: "Dictate", actions: actions, action: actions.dictate) {
                    PillMicGlyph().stroke(p.ink, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        .frame(width: m.micGlyph, height: m.micGlyph)
                }
                .frame(width: size.width, height: size.height)
            case .starting:
                PillWaveform(levels: [], animated: false, barLevel: 0, live: false)
            case .listening:
                PillWaveform(levels: live.levels, animated: !reduceMotion, barLevel: live.barLevel, live: true)
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: actions.finish)
            case .handsFree:
                PillWaveform(levels: live.levels, animated: !reduceMotion, barLevel: live.barLevel, live: true)
            case .processing:
                // Wispr's processing: resting bars and the spinner, no words, over the glow bar.
                PillGlowInk(size: size) {
                    HStack(spacing: 6) {
                        PillWaveform(levels: [], animated: false, barLevel: 0, live: false)
                        PillSpokeSpinner()
                    }
                    .frame(width: size.width, height: size.height)
                }
            case .polishing(let title):
                PillGlowInk(size: size) { PillPolishingFace(title: title, size: size) }
            case .polished(let auto):
                PillChangesFace(autoCleanup: auto, size: size, openChanges: actions.openChanges, hide: actions.hideChanges)
            case .cancelled:
                wordsWithUndo("Transcript cancelled", mark: nil, undo: actions.undoCancel)
            case .pasted:
                wordsWithUndo("Pasted", mark: .success, undo: actions.undoPaste)
            case .hiddenForHour:
                wordsWithUndo("The Flow Bar will be hidden for an hour", mark: nil, undo: actions.undoHide)
            case .line(let text, let tone):
                HStack(spacing: 7) {
                    if tone != .info { PillToneMark(tone: tone, size: m.noticeIcon).fixedSize() }
                    Text(text).font(skin.type.font(.label)).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, m.noticePadding)
                .accessibilityElement(children: .combine)
            case .card(let notice):
                PillCardContent(model: PillCardModel(notice: notice), size: size,
                                dismiss: actions.dismissNotice, copy: actions.copyRecovery)
            case .changes(let diff, let original):
                PillChangesCard(diff: diff, original: original, size: size, actions: actions)
            case .meeting(let paused):
                HStack(spacing: 4) {
                    PillMeetingLabel(paused: paused, startedAt: live.meetingStartedAt)
                    PillRoundControl(label: "Stop notes", fill: p.controlFill, diameter: 22, action: actions.stopMeeting) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(p.controlInk).frame(width: 8.5, height: 8.5)
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.openMeeting)
            case .error:
                // Wispr's error pill: the resting bars inside a red edge. No icon, no words.
                PillWaveform(levels: [], animated: false, barLevel: 0, live: false)
            }
        }
        // Let the text accept the measured width proposal. Horizontal
        // fixedSize forced long labels outside their capped pill.
        .frame(width: size.width, height: size.height)
    }

    private func wordsWithUndo(_ words: String, mark: PillTone?, undo: @escaping () -> Void) -> some View {
        let m = skin.metrics
        return HStack(spacing: m.statusGap) {
            if let mark { PillToneMark(tone: mark, size: 13) }
            Text(words).font(skin.type.font(.label)).foregroundStyle(skin.palette.ink).lineLimit(1)
            PillChip(title: "Undo") { undo(); return true }
                .layoutPriority(1)
        }
        .padding(.leading, m.statusPadding)
        .padding(.trailing, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(words)
    }
}

/// Eight spokes in a ring, fading one step at a time (Wispr's spinner: opacity 0.88 down to 0.15).
struct PillSpokeSpinner: View {
    @Environment(\.pillSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ink = skin.palette.ink
        TimelineView(.periodic(from: .now, by: 0.125)) { tick in
            // Discrete steps: the brightest spoke moves on by one every 125 ms, so a cycle is one second.
            let step = reduceMotion ? 0 : Int((tick.date.timeIntervalSinceReferenceDate / 0.125).rounded(.down)) % 8
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                for spoke in 0..<8 {
                    let age = (spoke - step + 8) % 8
                    let opacity = 0.88 - (0.88 - 0.15) * Double(age) / 7
                    let angle = Double(spoke) / 8 * 2 * .pi
                    var path = Path()
                    path.move(to: CGPoint(x: centre.x + 3.2 * cos(angle), y: centre.y + 3.2 * sin(angle)))
                    path.addLine(to: CGPoint(x: centre.x + 5.6 * cos(angle), y: centre.y + 5.6 * sin(angle)))
                    context.stroke(path, with: .color(ink.opacity(opacity)),
                                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

/// "Done. See changes" (152 x 30, Wispr's polish_completed_action) and "Cleaned up!" (the cleanup nudge).
/// Click opens the changes. It hides itself after 5 s (7 s for the first three cleanup nudges); the
/// countdown pauses while the pointer is on it and resumes with the time that was left.
struct PillChangesFace: View {
    let autoCleanup: Bool
    let size: CGSize
    let openChanges: () -> Void
    let hide: () -> Void
    @Environment(\.pillSkin) private var skin
    @State private var hovering = false
    @State private var deadline: ContinuousClock.Instant?
    @State private var secondsLeft: Double?
    @State private var timer: Task<Void, Never>?
    /// The finish: the glow has already swept to full in the polishing face; a check appears.
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let shownKey = "flow.cleanupChangesShownCount"

    var body: some View {
        let p = skin.palette
        // Light glass over a bright screen turns its ink dark; the pale pink would vanish there.
        let pink = skin.onBrightGlass ? Color(red: 0.72, green: 0.12, blue: 0.62) : Color(red: 1, green: 0xbc / 255, blue: 0xf2 / 255)
        HStack(spacing: 0) {
            if finished {
                PillToneMark(tone: .success, size: 12).transition(.scale.combined(with: .opacity))
                    .padding(.trailing, 5)
            }
            if autoCleanup {
                Text("Cleaned up!").font(skin.type.font(.button)).foregroundStyle(p.ink)
                Text("  See what's changed").font(skin.type.font(.button)).foregroundStyle(pink)
            } else {
                Text("Done.").font(skin.type.font(.button)).foregroundStyle(p.ink)
                Text(" See changes").font(skin.type.font(.button)).foregroundStyle(pink)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, skin.metrics.statusPadding)
        .frame(width: size.width, height: size.height)
        .background(Capsule().fill(hovering ? (skin.onBrightGlass ? Color.black.opacity(0.1) : Color(white: 0.29)) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: openChanges)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.set(); pause() } else { NSCursor.arrow.set(); resume() }
        }
        .onAppear { begin() }
        .onDisappear { timer?.cancel() }
        .accessibilityLabel(autoCleanup ? "Cleaned up. See what's changed" : "Done. See changes")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openChanges() }
    }

    private func begin() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.12)) { finished = true }
        var seconds = 5.0
        if autoCleanup {
            let shown = UserDefaults.standard.integer(forKey: Self.shownKey)
            seconds = PillWispr.changesSeconds(autoCleanup: true, earlierShowings: shown)
            UserDefaults.standard.set(shown + 1, forKey: Self.shownKey)
        }
        run(seconds: seconds)
    }

    private func run(seconds: Double) {
        timer?.cancel()
        let end = ContinuousClock.now + .seconds(seconds)
        deadline = end
        timer = Task { @MainActor in
            try? await ContinuousClock().sleep(until: end)
            if !Task.isCancelled { hide() }
        }
    }

    private func pause() {
        guard let deadline else { return }
        timer?.cancel()
        let left = ContinuousClock.now.duration(to: deadline).components
        secondsLeft = max(0, Double(left.seconds) + Double(left.attoseconds) / 1e18)
    }

    private func resume() {
        run(seconds: secondsLeft ?? 0)
        secondsLeft = nil
    }
}

// MARK: - Buds (content of the pieces beside the body)

struct PillBudView: View {
    let bud: PillBud
    let actions: PillActions
    @Environment(\.pillSkin) private var skin
    @AppStorage("flow.lastPolishLevel") private var lastPolishLevel = "medium"

    var body: some View {
        let p = skin.palette
        switch bud {
        case .cancel:
            PillGlyphButton(segment: nil, label: "Cancel", actions: actions, action: actions.cancel) {
                PillCrossGlyph().stroke(p.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).frame(width: 8, height: 8)
            }
        case .finish:
            PillGlyphButton(segment: nil, label: "Finish and paste", actions: actions, action: actions.finish) {
                ZStack {
                    Circle().fill(p.confirmFill).frame(width: 20, height: 20)
                    PillCheckGlyph().stroke(p.confirmInk, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 9, height: 6.5)
                }
            }
        case .note:
            PillGlyphButton(segment: .note, label: "New note", actions: actions, action: actions.newNote) {
                Image(systemName: "smallcircle.filled.circle").font(.system(size: 12.5)).foregroundStyle(p.ink)
            }
        case .wand:
            HStack(spacing: 0) {
                PillGlyphButton(segment: .wand, label: "Polish", actions: actions, action: { actions.polish(lastPolishLevel) }) {
                    Image(systemName: "wand.and.stars").font(.system(size: 12.5)).foregroundStyle(p.ink)
                }
                .frame(width: skin.metrics.thickness)
                PillGlyphButton(segment: .wandOptions, label: "Polish options", actions: actions, action: actions.polishOptions) {
                    PillChevronUpGlyph().stroke(p.inkSecondary, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                        .frame(width: 9, height: 9)
                }
                .frame(width: skin.metrics.readyOptions)
                .padding(.trailing, 2)
            }
        }
    }
}

/// A glyph that acts on click: soft highlight under the pointer, sinks while pressed, reports
/// hover so the pill can show its tip.
struct PillGlyphButton<Glyph: View>: View {
    let segment: PillReadySegment?
    let label: String
    let actions: PillActions
    let action: () -> Void
    @ViewBuilder let glyph: Glyph
    @Environment(\.pillSkin) private var skin
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            glyph
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Circle().fill(skin.palette.buttonFill.opacity(hovering ? 1 : 0)).padding(3))
                .contentShape(Rectangle())
        }
        .buttonStyle(PillPressStyle())
        .onHover { inside in
            hovering = inside
            if let segment { actions.hoverSegment(inside ? segment : nil) }
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .animation(skin.motion.hover, value: hovering)
        .accessibilityLabel(label)
    }
}

/// Buttons inside the pill sink a little while pressed. The sink starts on the press itself; only
/// the release eases back.
struct PillPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// The meeting face's left part: a pulsing red dot, "Notes" and the elapsed time at 60%.
struct PillMeetingLabel: View {
    let paused: Bool
    let startedAt: Date?
    @Environment(\.pillSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            if paused {
                Circle().fill(Color.white.opacity(0.5)).frame(width: PillCardStyle.meetingDot, height: PillCardStyle.meetingDot)
            } else {
                PillMeetingDot()
            }
            Text("Notes").font(PillCardType.title(skin)).foregroundStyle(skin.palette.ink).lineLimit(1)
            if let startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { tick in
                    Text(Self.elapsed(from: startedAt, to: tick.date))
                        .font(PillCardType.meta(skin)).monospacedDigit()
                        .foregroundStyle(skin.palette.ink.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(paused ? "Notes paused" : "Notes recording")
    }

    /// m:ss, or h:mm:ss after an hour.
    static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The 7 pt red dot that pulses while notes are recording (static under reduced motion).
struct PillMeetingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    private let red = Color(red: 1, green: 0x4d / 255, blue: 0x4d / 255)

    var body: some View {
        Circle().fill(red)
            .frame(width: PillCardStyle.meetingDot, height: PillCardStyle.meetingDot)
            .background(Circle().fill(red.opacity(pulse ? 0 : 0.28)).frame(width: 13, height: 13).scaleEffect(pulse ? 1.5 : 0.8))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Sizes per state (skin-free summary for tests and hit testing)

extension PillSkin.Metrics {
    func length(for state: FlowPillState) -> CGFloat {
        switch state {
        case .resting: return resting.width
        case .ready: return readyLength
        case .starting, .pushToTalk: return pushToTalkLength
        case .handsFree: return handsFreeLength
        case .processing: return PillWispr.processingWidth
        case .meeting: return meetingLength
        case .audioFailure, .pasteFailure, .microphoneUnavailable: return PillWispr.errorWidth
        }
    }

    /// A state's size standing along an edge (side docks stand it on end).
    func size(for state: FlowPillState, dock: PillDockEdge) -> CGSize {
        let flat = state == .resting ? resting : CGSize(width: length(for: state), height: thickness)
        return dock.isSide ? CGSize(width: flat.height, height: flat.width) : flat
    }
}
