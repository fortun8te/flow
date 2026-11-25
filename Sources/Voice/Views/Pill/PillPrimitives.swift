import SwiftUI
import AppKit

// MARK: - Layout helpers shared by every pill view

/// The pill's own coordinate space: the hosting view, top-left origin.
enum PillSpace {
    static let name = "pill.root"
}

/// Union of every clickable thing on screen, in `PillSpace`. The panel lets clicks through
/// everywhere else.
struct PillHitAreaKey: PreferenceKey {
    static let defaultValue = CGRect.null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = value.union(nextValue()) }
}

extension View {
    /// Marks this view's frame as clickable.
    func pillHitArea(_ enabled: Bool = true) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: PillHitAreaKey.self,
                                   value: enabled ? proxy.frame(in: .named(PillSpace.name)) : .null)
        })
    }

}

/// A slight dim while pressed, applied on the press itself (no animation, so it lands within a frame).
struct PillNoPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).opacity(configuration.isPressed ? 0.72 : 1)
    }
}

// MARK: - Waveform

/// The live bars. Loudness goes through a perceptual curve and an automatic gain that follows
/// the recent peak, so a whisper still moves the bars; while the microphone is live a faint
/// shimmer keeps them from ever lying flat. Each bar is the rest length x that level x a centre
/// bulge x a slow travelling wave.
struct PillWaveform: View {
    let levels: [Float]
    var meeting = false
    var animated = true
    /// Meeting bars shrink to dots while the recording is paused.
    var collapsed = false
    /// Dictation: the engine's 0...1 bar level (AudioCaptureService.barLevel).
    var barLevel: Float?
    /// Solid ink once the microphone is live; faint before and after.
    var live = true
    var vertical = false
    @Environment(\.pillSkin) private var skin
    @State private var smoother = PillWaveSmoother()

    private static let wave: [(Double, Double)] = [(0, 1), (0.2, 1.2), (0.4, 1.5), (0.8, 1.1), (0.9, 1.3), (1, 1)]

    private var count: Int { meeting ? skin.waveform.meetingBarCount : skin.waveform.barCount }
    private var length: CGFloat { (meeting ? skin.waveform.meetingLength : skin.waveform.length) + 8 }
    private var across: CGFloat { meeting ? 24 : 18 }

    private var meetingLevel: Double {
        let recent = levels.suffix(3)
        guard !recent.isEmpty else { return 0 }
        return min(1, max(0, Double(recent.reduce(0, +)) / Double(recent.count)))
    }

    /// CSS ease-in-out between the wave's keyframes.
    private static func easeInOut(_ x: Double) -> Double {
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<12 {
            let bx = 3 * (1 - t) * (1 - t) * t * 0.42 + 3 * (1 - t) * t * t * 0.58 + t * t * t
            if bx < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return 3 * (1 - t) * t * t + t * t * t
    }

    static func waveMultiplier(_ time: Double) -> Double {
        let t = time - time.rounded(.down)
        for index in 1..<wave.count where t <= wave[index].0 {
            let (t0, v0) = wave[index - 1], (t1, v1) = wave[index]
            let x = t1 > t0 ? (t - t0) / (t1 - t0) : 1
            return v0 + (v1 - v0) * easeInOut(x)
        }
        return 1
    }

    private func bulge(_ index: Int) -> Double {
        let distance = abs(Double(count - 1) / 2 - Double(index))
        return meeting ? max(0, 1 - distance * 18 / 48) : max(0, 1 - distance * distance / 48)
    }

    var body: some View {
        let style = skin.waveform
        let ink = skin.palette.ink, faint = skin.palette.inkFaint
        let still = !animated && (barLevel ?? 0) == 0 && smoother.value <= 0
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: still)) { tick in
            let now = tick.date.timeIntervalSinceReferenceDate
            // Dictation: 0...1 of the bar's room. Meetings keep their older level source.
            let fill: Double? = barLevel.map { smoother.step(toward: Double($0), at: now) }
            let scale: Double = max(1, meetingLevel * (meeting ? 2 : style.gain))
            let shimmer = live && barLevel != nil && animated
            let solid = meeting ? !collapsed : (barLevel != nil ? live : meetingLevel > 0.02)
            // A canvas keeps fractional bar lengths; stacked views would snap them to whole points.
            Canvas { context, size in
                let along = vertical ? size.height : size.width
                let room = vertical ? size.width : size.height
                let total = CGFloat(count) * style.barWidth + CGFloat(count - 1) * (style.barPitch - style.barWidth)
                let start = (along - total) / 2
                for index in 0..<count {
                    let order = index < (count + 1) / 2 ? index : index - count
                    let wave = animated ? 1 + (Self.waveMultiplier(now - 0.1 * Double(order)) - 1) * style.wave : 1
                    // A faint travelling shimmer while live: never a flat line, even in silence.
                    // Added in points near rest, not multiplied, so it never stretches loud bars to the edge.
                    let glint: CGFloat = shimmer ? 1.5 * CGFloat(0.5 + 0.5 * sin(now * 4.2 - Double(index) * 0.7)) : 0
                    let barLength: CGFloat = {
                        if collapsed { return style.barWidth }
                        if meeting { return min(room * 0.88, 18, max(style.barWidth, 2 * style.restLength * scale * bulge(index) * wave)) }
                        guard let fill else { return style.restLength }
                        // The tallest bar tops out at 88% of the room: lively, never pinned flat against the edge.
                        let shaped = min(0.88, fill * (0.35 + 0.65 * bulge(index)) * wave)
                        let reach = style.restLength + (room - style.restLength) * CGFloat(shaped)
                        return min(room, max(style.restLength, reach + glint * CGFloat(1 - shaped)))
                    }()
                    let a = start + CGFloat(index) * style.barPitch
                    let b = (room - barLength) / 2
                    let rect = vertical ? CGRect(x: b, y: a, width: barLength, height: style.barWidth)
                                        : CGRect(x: a, y: b, width: style.barWidth, height: barLength)
                    let radius = style.roundEnds ? min(rect.width, rect.height) / 2 : 0
                    context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(solid ? ink : faint))
                }
            }
        }
        .frame(width: vertical ? across : length, height: vertical ? length : across)
        .accessibilityHidden(true)
    }
}

/// Turns the engine's 0...1 level into bar height: a gate for room noise, a perceptual curve,
/// an automatic gain against the recent peak (half-life one second, never below `minimumPeak`,
/// so a whisper reaches about 40% and speech 70-90%), then a fast attack (30 ms) and a slower
/// release (150 ms). Frame-rate independent.
final class PillWaveSmoother {
    static let gate = 0.02
    /// The recent peak lands at about 85% of the bar, not 100%, so loud speech stops pinning every bar (21 Nov 2026).
    static let headroom = 1.18
    static let curve = 0.5
    static let minimumPeak = 0.45
    static let attack = 0.03
    static let release = 0.15
    private(set) var value: Double = 0
    private(set) var peak = PillWaveSmoother.minimumPeak
    private var last: Double?

    /// The shaped 0...1 level for a raw level, updating the gain.
    func shape(_ raw: Double, dt: Double) -> Double {
        let level = raw < Self.gate ? 0 : pow(min(1, raw), Self.curve)
        peak = max(Self.minimumPeak, max(level, peak * pow(0.5, dt)))
        return min(1, level / (peak * Self.headroom))
    }

    func step(toward target: Double, at time: Double) -> Double {
        let dt = last.map { min(0.2, max(0, time - $0)) } ?? (1.0 / 60)
        last = time
        guard dt > 0 else { return value }
        let shaped = shape(target, dt: dt)
        let tau = shaped > value ? Self.attack : Self.release
        value += (shaped - value) * (1 - exp(-dt / tau))
        return value
    }
}

// MARK: - Round control

/// A small round button inside a pill (hands-free cancel and finish, the meeting stop).
struct PillRoundControl<Glyph: View>: View {
    let label: String
    let fill: Color
    var diameter: CGFloat
    let action: (() -> Void)?
    var onHover: (Bool) -> Void = { _ in }
    @ViewBuilder let glyph: Glyph
    @State private var hovering = false

    var body: some View {
        Button { action?() } label: {
            ZStack {
                Circle().fill(fill).frame(width: diameter, height: diameter)
                    .brightness(hovering && action != nil ? 0.06 : 0)
                glyph
            }
            .frame(width: diameter + 6, height: diameter + 6).contentShape(Circle())
        }
        .buttonStyle(PillNoPressStyle()).disabled(action == nil).opacity(action == nil ? 0.4 : 1)
        .onHover { inside in hovering = inside; onHover(inside) }
        .accessibilityLabel(label)
    }
}

// MARK: - Glyphs

/// A cross, drawn edge to edge in its rect.
struct PillCrossGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

/// An outline microphone on a 24-unit grid: body, cradle and stem.
struct PillMicGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var path = Path()
        path.addRoundedRect(in: CGRect(x: rect.minX + 9 * k, y: rect.minY + 2 * k, width: 6 * k, height: 13 * k),
                            cornerSize: CGSize(width: 3 * k, height: 3 * k))
        path.move(to: p(19, 10)); path.addLine(to: p(19, 12))
        path.addArc(center: p(12, 12), radius: 7 * k, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: p(5, 10))
        path.move(to: p(12, 19)); path.addLine(to: p(12, 22))
        return path
    }
}

struct PillCheckGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// Chevron pointing up (m18 15-6-6-6 6 on a 24 grid).
struct PillChevronUpGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 18 * s, y: rect.minY + 15 * s))
        path.addLine(to: CGPoint(x: rect.minX + 12 * s, y: rect.minY + 9 * s))
        path.addLine(to: CGPoint(x: rect.minX + 6 * s, y: rect.minY + 15 * s))
        return path
    }
}

/// Circle with "!" (errors) or a triangle with "!" (warnings), stroked.
struct PillStatusGlyph: Shape {
    var alert = false
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        if alert {
            path.move(to: p(21.73, 18)); path.addLine(to: p(13.73, 4))
            path.addQuadCurve(to: p(10.27, 4), control: p(12, 1.2))
            path.addLine(to: p(2.27, 18))
            path.addQuadCurve(to: p(4, 21), control: p(1.2, 21))
            path.addLine(to: p(20, 21))
            path.addQuadCurve(to: p(21.73, 18), control: p(22.8, 21))
            path.closeSubpath()
            path.move(to: p(12, 9)); path.addLine(to: p(12, 13))
            path.move(to: p(12, 17)); path.addLine(to: p(12.01, 17))
        } else {
            path.addEllipse(in: CGRect(origin: p(2, 2), size: CGSize(width: 20 * s, height: 20 * s)))
            path.move(to: p(12, 8)); path.addLine(to: p(12, 12))
            path.move(to: p(12, 16)); path.addLine(to: p(12.01, 16))
        }
        return path
    }
}

/// A curved arrow back (undo), on a 24 grid.
struct PillUndoGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(9, 14)); path.addLine(to: p(4, 9)); path.addLine(to: p(9, 4))
        path.move(to: p(4, 9)); path.addLine(to: p(14.5, 9))
        path.addArc(center: p(14.5, 14.5), radius: 5.5 * s, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: p(11, 20))
        return path
    }
}
