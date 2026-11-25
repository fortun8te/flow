import SwiftUI

// Work progress for the pill: a glowing bar of light that fills the body while the engine works
// (`PillGlowTrack`, drawn by `progressGlow` in PillShaders.metal). Opt+1 follows streamed tokens over
// the tokens it expects; dictation follows a time estimate learned from earlier dictations
// (`PillWorkTiming`). The older darker fill (`PillPolishFill`) and its curve stay for the tests that use them.
//
// The fill follows real progress when the engine reports it (`voice.polishProgress`, see
// `PillPolishSignal`). Without it, an eased curve runs: it reaches 90 % in 7 s, then creeps toward
// 97 % and never reaches full, so a slow polish does not look stalled at full. It never moves back:
// `PillPolishState.floor` keeps the highest value shown during one polish.

/// What the polish engine reports. `fraction` is real progress (nil when unknown); `loadingModel`
/// marks a cold model load, which gets the "Loading model…" title and a shimmer.
struct PillPolishSignal: Equatable {
    static let notification = Notification.Name("voice.polishProgress")
    static let fractionKey = "fraction"
    static let loadingKey = "loadingModel"

    var fraction: Double?
    var loadingModel: Bool

    init(fraction: Double?, loadingModel: Bool = false) {
        self.fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        self.loadingModel = loadingModel
    }

    init(notification note: Notification) {
        self.init(fraction: note.userInfo?[Self.fractionKey] as? Double,
                  loadingModel: note.userInfo?[Self.loadingKey] as? Bool ?? false)
    }

    /// The userInfo the engine posts (no fraction key when progress is unknown).
    var userInfo: [String: Any] {
        var info: [String: Any] = [Self.loadingKey: loadingModel]
        if let fraction { info[Self.fractionKey] = fraction }
        return info
    }

    /// Posts on the main queue, where the pill listens. Safe to call from any thread or actor.
    static func post(fraction: Double?, loadingModel: Bool = false) {
        let info = PillPolishSignal(fraction: fraction, loadingModel: loadingModel).userInfo
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: notification, object: nil, userInfo: info)
        }
    }
}

/// The pill's polish progress, as the polishing face reads it.
struct PillPolishState: Equatable {
    var fraction: Double?
    var floor: Double = 0
    var loadingModel = false

    mutating func apply(_ signal: PillPolishSignal) {
        fraction = signal.fraction
        if let fraction { floor = max(floor, fraction) }
        loadingModel = signal.loadingModel
    }
}

enum PillProgressCurve {
    /// Seconds for the eased fallback to reach `knee`.
    static let duration = 7.0
    static let knee = 0.9
    /// The fallback creeps toward this and never reaches full.
    static let ceiling = 0.97
    /// Time constant of the creep after the knee.
    static let creepSeconds = 12.0

    /// Ease-out to the knee (zero slope there, so it slows), then a slow exponential creep.
    static func fallback(elapsed: Double) -> Double {
        let t = max(0, elapsed)
        if t < duration {
            return knee * (1 - pow(1 - t / duration, 2.2))
        }
        return knee + (ceiling - knee) * (1 - exp(-(t - duration) / creepSeconds))
    }

    /// The fill's target: real progress when known, otherwise the curve. Never below `floor`.
    static func target(elapsed: Double, state: PillPolishState) -> Double {
        let value = state.fraction ?? fallback(elapsed: elapsed)
        return min(1, max(state.floor, value))
    }
}

private struct PillPolishStateKey: EnvironmentKey {
    static let defaultValue = PillPolishState()
}

extension EnvironmentValues {
    /// The polish progress the pill's polishing face draws (set by `OverlayPillView`).
    var pillPolish: PillPolishState {
        get { self[PillPolishStateKey.self] }
        set { self[PillPolishStateKey.self] = newValue }
    }
}

/// The darker fill across the body at `fraction`. Width changes animate with a spring, so every
/// new target eases in from wherever the fill is now.
struct PillPolishFill: View {
    let fraction: Double
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A darker wash over the body: it reads as the body filling dark, not as a light flare.
    static let color = Color.black.opacity(0.32)

    var body: some View {
        Rectangle()
            .fill(Self.color)
            .frame(width: width * CGFloat(fraction))
            .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.92), value: fraction)
            .frame(width: width, alignment: .leading)
    }
}

/// A soft band that sweeps across the body. Used only while the model loads (the caller decides).
struct PillShimmer: View {
    let width: CGFloat
    static let period = 1.6

    var body: some View {
        TimelineView(.animation) { tick in
            let phase = tick.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
            let band = width * 0.45
            LinearGradient(colors: [.clear, Color.white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + CGFloat(phase) * (width + band))
                .frame(width: width, alignment: .leading)
                .clipped()
        }
        .allowsHitTesting(false)
    }
}

/// Polishing: the title (or "Loading model…") and the spinner. The glow bar under it is drawn by the
/// body (`PillGlowTrack`, PillShaders.metal); this face only adds the shimmer while a model loads.
struct PillPolishingFace: View {
    let title: String
    let size: CGSize
    @Environment(\.pillSkin) private var skin
    @Environment(\.pillPolish) private var polish

    var body: some View {
        ZStack(alignment: .leading) {
            if polish.loadingModel {
                PillShimmer(width: size.width)
            }
            HStack(spacing: 8) {
                Text(title).font(skin.type.font(.button)).foregroundStyle(skin.palette.ink).lineLimit(1)
                PillSpokeSpinner()
            }
            .padding(.horizontal, skin.metrics.statusPadding)
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
    }
}


// MARK: - The glow bar

/// One frame of the glow: what the shader and the two-tone label read.
struct PillGlowFrame: Equatable {
    /// 0...1 along the body.
    var fill: Double
    /// 0...1, the sheen's place along the bar.
    var sheen: Double
    /// 0...1, the short flash when the work finishes.
    var flash: Double
    /// 0...1, fades the glow in when the work starts.
    var strength: Double

    static let off = PillGlowFrame(fill: -1, sheen: 0, flash: 0, strength: 0)
    var isOn: Bool { fill >= 0 && strength > 0.001 }
}

/// The progress of one piece of work (a dictation's cleanup or an Opt+1 polish), as a pure function
/// of time and the events seen so far, so a `TimelineView` can draw it without keeping state.
///
/// Honest and smooth: time-based work reaches 90 % at the learned estimate, then slows toward 98 %
/// without ever stopping; token-based work eases toward streamed / expected tokens. The value never
/// moves back. `complete(at:)` sweeps it to full in 160 ms with a small flash, and the pill moves on after 200 ms.
struct PillGlowTrack: Equatable {
    enum Kind: String, Equatable { case dictation, polish }

    var kind: Kind
    /// Seconds since the reference date (`Date.timeIntervalSinceReferenceDate`).
    var start: Double
    /// The learned estimate for this work, in seconds.
    var expected: Double
    /// The model is still loading (cold Opt+1): the bar holds low and slow.
    var loading = false
    /// Real progress (tokens): where the eased approach started, toward what, and when.
    private(set) var anchorTime: Double?
    private(set) var anchorValue: Double = 0
    private(set) var tokenTarget: Double?
    /// When the token count reached its ceiling: from then the bar creeps on slowly.
    private(set) var ceilingAt: Double?
    private(set) var completedAt: Double?
    private(set) var completedFrom: Double = 0

    static let knee = 0.9
    static let ceiling = 0.98
    /// Past the estimate the bar keeps moving: this many estimates per e-fold of the remaining gap.
    static let overrunScale = 0.9
    static let easeSeconds = 0.22
    static let sweepSeconds = 0.16
    /// How long the finished bar stays before the pill moves on (sweep plus flash).
    static let holdSeconds = 0.2
    static let fadeInSeconds = 0.05
    static let sheenPeriod = 1.7
    /// Token progress maps into this span, so the prefill has room before the first token.
    static let tokenFloor = 0.1
    static let tokenSpan = 0.86
    static let loadingCap = 0.12

    init(kind: Kind, start: Double, expected: Double) {
        self.kind = kind
        self.start = start
        self.expected = max(0.2, expected.isFinite ? expected : 1)
    }

    /// Time-based progress: an ease to `knee` at the estimate, then an asymptotic approach to `ceiling`.
    static func timeCurve(elapsed: Double, expected: Double) -> Double {
        let r = max(0, elapsed) / max(0.05, expected)
        if r <= 1 { return knee * (1 - pow(1 - r, 1.3)) }
        return knee + (ceiling - knee) * (1 - exp(-(r - 1) / overrunScale))
    }

    /// Where streamed / expected tokens put the bar.
    static func tokenValue(_ fraction: Double) -> Double {
        tokenFloor + tokenSpan * min(1, max(0, fraction))
    }

    /// The bar before completion. Monotone in time.
    func value(at t: Double) -> Double {
        let elapsed = max(0, t - start)
        var v = Self.timeCurve(elapsed: elapsed, expected: expected)
        if loading { v = min(v, Self.loadingCap) }
        if let anchorTime, let tokenTarget {
            v = anchorValue
            let k = 1 - exp(-max(0, t - anchorTime) / Self.easeSeconds)
            v += (max(anchorValue, tokenTarget) - anchorValue) * k
            if let ceilingAt {
                let start = Self.tokenValue(TypoFixProgress.ceiling)
                let creep = start + (Self.ceiling - start) * (1 - exp(-max(0, t - ceilingAt) / 2.5))
                v = max(v, creep)
            }
        }
        return min(Self.ceiling, max(0, v))
    }

    /// Real progress arrived (streamed / expected tokens, 0...1).
    mutating func report(fraction: Double, at t: Double) {
        let now = value(at: t)
        anchorTime = t
        anchorValue = now
        tokenTarget = max(tokenTarget ?? 0, Self.tokenValue(fraction))
        if fraction >= TypoFixProgress.ceiling, ceilingAt == nil { ceilingAt = t }
    }

    mutating func setLoading(_ value: Bool, at t: Double) {
        guard value != loading else { return }
        if !value {
            // The model is up: the estimate restarts from where the bar is, so it never jumps.
            let now = self.value(at: t)
            loading = false
            let r = Self.inverseTimeCurve(now)
            start = t - r * expected
        } else {
            loading = true
        }
    }

    /// The elapsed share of the estimate at which `timeCurve` reaches `value` (below the knee).
    static func inverseTimeCurve(_ value: Double) -> Double {
        let v = min(knee * 0.999, max(0, value))
        return 1 - pow(1 - v / knee, 1 / 1.3)
    }

    mutating func complete(at t: Double) {
        guard completedAt == nil else { return }
        completedFrom = value(at: t)
        completedAt = t
    }

    var isComplete: Bool { completedAt != nil }

    /// True once the sweep and flash are over and the pill may move on.
    func isFinished(at t: Double) -> Bool {
        guard let completedAt else { return false }
        return t - completedAt >= Self.holdSeconds
    }

    func frame(at t: Double) -> PillGlowFrame {
        let strength = min(1, max(0, (t - start) / Self.fadeInSeconds))
        let sheen = (max(0, t - start) / Self.sheenPeriod).truncatingRemainder(dividingBy: 1)
        guard let completedAt else {
            return PillGlowFrame(fill: value(at: t), sheen: sheen, flash: 0, strength: max(strength, 0.0))
        }
        let since = max(0, t - completedAt)
        let p = min(1, since / Self.sweepSeconds)
        let eased = 1 - pow(1 - p, 3)
        let fill = completedFrom + (1 - completedFrom) * eased
        let flash = since < Self.sweepSeconds ? pow(p, 2) : exp(-(since - Self.sweepSeconds) / 0.1)
        return PillGlowFrame(fill: fill, sheen: sheen, flash: flash, strength: 1)
    }
}

/// Learned timings for the glow's estimates. Small and local (UserDefaults): the last 40 samples of
/// each kind. Dictation learns seconds of cleanup per word and words per second of speech; Opt+1
/// learns seconds per word for its time fallback and output tokens per input token for the token meter.
enum PillWorkTiming {
    static let dictationKey = "flow.glow.dictationSamples"
    static let polishKey = "flow.glow.polishSamples"
    static let tokenRatioKey = "flow.glow.opt1TokenRatio"
    static let limit = 40

    /// One finished piece of work: words handled, seconds of speech (dictation), seconds it took.
    struct Sample: Codable, Equatable {
        var words: Int
        var audioSeconds: Double
        var seconds: Double
    }

    static func samples(_ key: String, defaults: UserDefaults = .standard) -> [Sample] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([Sample].self, from: data) else { return [] }
        return list
    }

    static func record(_ sample: Sample, key: String, defaults: UserDefaults = .standard) {
        guard sample.seconds.isFinite, sample.seconds > 0.02, sample.seconds < 120 else { return }
        let list = Array((samples(key, defaults: defaults) + [sample]).suffix(limit))
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }

    static func recordDictation(words: Int, audioSeconds: Double, seconds: Double, defaults: UserDefaults = .standard) {
        record(Sample(words: max(0, words), audioSeconds: max(0, audioSeconds), seconds: seconds), key: dictationKey, defaults: defaults)
    }

    static func recordPolish(words: Int, seconds: Double, defaults: UserDefaults = .standard) {
        record(Sample(words: max(0, words), audioSeconds: 0, seconds: seconds), key: polishKey, defaults: defaults)
    }

    /// A robust line `seconds = a + b * words` through the samples: the median of the per-word slopes
    /// above a floor, and the median intercept left over. Falls back to `fallback` with no samples.
    static func fit(_ list: [Sample], fallback: (a: Double, b: Double)) -> (a: Double, b: Double) {
        guard list.count >= 3 else {
            guard !list.isEmpty else { return fallback }
            // A few samples: scale the fallback by how the real runs compared with it.
            let ratios = list.map { $0.seconds / max(0.05, fallback.a + fallback.b * Double($0.words)) }.sorted()
            let k = min(3, max(0.3, ratios[ratios.count / 2]))
            return (fallback.a * k, fallback.b * k)
        }
        let floorA = list.map(\.seconds).min() ?? fallback.a
        let a0 = max(0.05, floorA * 0.8)
        let slopes = list.filter { $0.words > 0 }.map { max(0, ($0.seconds - a0) / Double($0.words)) }.sorted()
        let b = slopes.isEmpty ? fallback.b : slopes[slopes.count / 2]
        let intercepts = list.map { $0.seconds - b * Double($0.words) }.sorted()
        let a = max(0.05, intercepts[intercepts.count / 2])
        return (a, b)
    }

    /// Words per second of speech, learned (2.4 by default).
    static func wordsPerSecond(_ list: [Sample]) -> Double {
        let rates = list.filter { $0.audioSeconds > 0.5 && $0.words > 0 }.map { Double($0.words) / $0.audioSeconds }.sorted()
        guard !rates.isEmpty else { return 2.4 }
        return min(5, max(0.8, rates[rates.count / 2]))
    }

    /// Expected seconds of dictation processing for `audioSeconds` of speech.
    static func dictationSeconds(audioSeconds: Double, defaults: UserDefaults = .standard) -> Double {
        let list = samples(dictationKey, defaults: defaults)
        let words = Double(max(1, Int((audioSeconds * wordsPerSecond(list)).rounded())))
        let line = fit(list, fallback: (0.35, 0.012))
        return min(20, max(0.25, line.a + line.b * words))
    }

    /// Expected seconds for an Opt+1 on `words` words (the time fallback when tokens are not reported).
    static func polishSeconds(words: Int, defaults: UserDefaults = .standard) -> Double {
        let line = fit(samples(polishKey, defaults: defaults), fallback: (0.6, 0.02))
        return min(30, max(0.4, line.a + line.b * Double(max(1, words))))
    }

    /// Output tokens per input token for Opt+1 (a copy edit is close to 1), learned as a running blend.
    static func tokenRatio(defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.double(forKey: tokenRatioKey)
        return stored > 0 ? min(1.6, max(0.6, stored)) : 1.0
    }

    static func recordTokenRatio(input: Int, output: Int, defaults: UserDefaults = .standard) {
        guard input >= 4, output > 0 else { return }
        let observed = min(1.6, max(0.6, Double(output) / Double(input)))
        let next = 0.8 * tokenRatio(defaults: defaults) + 0.2 * observed
        defaults.set(next, forKey: tokenRatioKey)
    }
}

private struct PillGlowKey: EnvironmentKey {
    static let defaultValue: PillGlowTrack? = nil
}

private struct PillGlowFrameKey: EnvironmentKey {
    static let defaultValue = PillGlowFrame.off
}

private struct PillGlowFreezeKey: EnvironmentKey {
    static let defaultValue: PillGlowFrame? = nil
}

extension EnvironmentValues {
    /// The work in progress the pill's glow follows (set by `OverlayPillView`), nil when idle.
    var pillGlow: PillGlowTrack? {
        get { self[PillGlowKey.self] }
        set { self[PillGlowKey.self] = newValue }
    }
    /// Offscreen inspection: a fixed glow frame instead of the live clock.
    var pillGlowFreeze: PillGlowFrame? {
        get { self[PillGlowFreezeKey.self] }
        set { self[PillGlowFreezeKey.self] = newValue }
    }
    /// The glow's current frame, for the two-tone label over the bar.
    var pillGlowFrame: PillGlowFrame {
        get { self[PillGlowFrameKey.self] }
        set { self[PillGlowFrameKey.self] = newValue }
    }
}

/// The bar's rectangle in a body of `size`, matching `progressGlow` in PillShaders.metal.
enum PillGlowGeometry {
    static func inset(_ size: CGSize) -> CGFloat {
        let vertical = size.height > size.width * 1.15
        return min(3.5, max(2, (vertical ? size.width : size.height) * 0.1))
    }

    static func fillRect(_ size: CGSize, fill: Double) -> CGRect {
        let i = inset(size)
        let track = CGRect(x: i, y: i, width: max(1, size.width - 2 * i), height: max(1, size.height - 2 * i))
        let f = CGFloat(min(1, max(0, fill)))
        if size.height > size.width * 1.15 {
            let h = track.height * f
            return CGRect(x: track.minX, y: track.maxY - h, width: track.width, height: h)
        }
        return CGRect(x: track.minX, y: track.minY, width: track.width * f, height: track.height)
    }
}

/// The label over the glow: light ink over the dark track, near-black ink over the bright bar, so the
/// words and the spinner always read. The content is built twice with the two inks.
struct PillGlowInk<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: () -> Content
    @Environment(\.pillSkin) private var skin
    @Environment(\.pillGlowFrame) private var frame

    var body: some View {
        if frame.isOn {
            let bar = PillGlowGeometry.fillRect(size, fill: frame.fill)
            ZStack(alignment: .topLeading) {
                content().environment(\.pillSkin, Self.inked(skin, dark: false))
                    .mask(alignment: .topLeading) {
                        Rectangle().fill(Color.white)
                            .overlay(alignment: .topLeading) {
                                Rectangle().frame(width: bar.width, height: bar.height).offset(x: bar.minX, y: bar.minY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }
                content().environment(\.pillSkin, Self.inked(skin, dark: true))
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(width: bar.width, height: bar.height).offset(x: bar.minX, y: bar.minY)
                    }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        } else {
            content()
        }
    }

    static func inked(_ skin: PillSkin, dark: Bool) -> PillSkin {
        var s = skin
        let ink = dark ? Color(white: 0.06) : Color(white: 0.97)
        s.palette.ink = ink
        s.palette.inkSecondary = ink.opacity(dark ? 0.7 : 0.6)
        s.palette.inkFaint = ink.opacity(dark ? 0.45 : 0.36)
        return s
    }
}
