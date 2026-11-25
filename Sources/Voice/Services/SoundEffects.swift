import Accelerate
// VOICE — Sound Effects
// ============================================================
// Programmatic earcons via AVAudioEngine. Premium dictation feel.
//
// WHY NOT NSSound(named:):
//   Shared instance, restarts mid-playback, volume leaks across callers.
//
// WHY programmatic synthesis:
//   Full control over spectra, envelope, stereo image, and tail.
//   Multi-component design (noise + tone + harmonics) avoids the
//   "phone notification" feel of a single sine pop.
//
// DESIGN PHILOSOPHY (Wispr Flow / Superwhisper-ish):
//   - Asymmetric envelopes: ~1ms attack, exponential decay
//   - Layered components: filtered noise (transient) + tonal body
//   - Inharmonic partials for "tap" character, not chime
//   - Subtle stereo widening (L/R micro-delay) for spaciousness
//   - Reverb-ish tail via low-amplitude exponential decay
//   - Volume-matched RMS across the three sounds
//
// SOUNDS:
//   playStart — Soft warm tap: noise transient + A4 body w/ slight glide up.
//                Inviting, "ready" feel. ~140ms total.
//   playStop  — Dampened descending pluck: low descending tone, woody decay. ~180ms.
//                Confirmation, "got it" — not a warning.
//   playDone  — Subliminal soft pluck: C5 with higher color, fast decay.
//                ~180ms. Almost felt, not heard.
// ============================================================

import AVFoundation

/// Owns cue ordering independently of the output device. All calls run on soundQueue.
/// An output change may stop a scheduled buffer without delivering its completion.
final class SoundCuePlaybackQueue<Cue> {
    private let isRunning: () -> Bool
    private let start: () throws -> Void
    private let play: (Cue, @escaping () -> Void) -> Void
    private let rebuild: () -> Void
    private let duration: (Cue) -> TimeInterval
    private let scheduleTimeout: (TimeInterval, @escaping () -> Void) -> Void
    private let failed: (Error) -> Void
    private var pending: [Cue] = []
    private var activeToken: UInt64?
    private var nextToken: UInt64 = 0

    init(isRunning: @escaping () -> Bool, start: @escaping () throws -> Void,
         play: @escaping (Cue, @escaping () -> Void) -> Void, rebuild: @escaping () -> Void,
         duration: @escaping (Cue) -> TimeInterval,
         scheduleTimeout: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         failed: @escaping (Error) -> Void = { _ in }) {
        self.isRunning = isRunning; self.start = start; self.play = play; self.rebuild = rebuild
        self.duration = duration; self.scheduleTimeout = scheduleTimeout; self.failed = failed
    }

    func enqueue(_ cue: Cue) {
        // Do this before the busy check. A stopped engine cannot finish the active cue.
        if activeToken != nil && !isRunning() { invalidateOutput() }
        if pending.count >= 8 { pending.removeFirst() }
        pending.append(cue)
        playNext()
    }

    func outputChanged() {
        invalidateOutput()
        playNext()
    }

    private func invalidateOutput() {
        activeToken = nil
        rebuild()
    }

    private func playNext() {
        guard activeToken == nil, !pending.isEmpty else { return }
        do {
            if !isRunning() { try start() }
        } catch {
            pending.removeAll()
            invalidateOutput()
            failed(error)
            return
        }
        let cue = pending.removeFirst()
        nextToken &+= 1
        let token = nextToken
        activeToken = token
        play(cue) { [weak self] in
            guard let self, self.activeToken == token else { return }
            self.activeToken = nil
            self.playNext()
        }
        // Some device interruptions leave isRunning true but never complete the buffer.
        scheduleTimeout(max(0, duration(cue)) + 0.75) { [weak self] in
            guard let self, self.activeToken == token else { return }
            self.invalidateOutput()
            self.playNext()
        }
    }
}

enum SoundEffects {

    private static var enabled: Bool {
        if UserDefaults.standard.object(forKey: "soundEffectsEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "soundEffectsEnabled")
    }

    private static var engine = AVAudioEngine()
    private static let sampleRate: Double = 44100
    private static let soundQueueKey = DispatchSpecificKey<Bool>()
    private static let soundQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "voice.sound-effects", qos: .userInitiated)
        queue.setSpecific(key: soundQueueKey, value: true)
        return queue
    }()
    private static func onSoundQueue(_ action: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: soundQueueKey) == true { action() }
        else { soundQueue.async(execute: action) }
    }
    private static var player = AVAudioPlayerNode()
    private static var playerAttached = false
    private static var configurationObserver: NSObjectProtocol?

    /// Rendered cues, built once and kept. Read and written only on soundQueue.
    private static var cueCache: [String: AVAudioPCMBuffer] = [:]
    /// Set on the caller's thread when a cue is requested. Used for the trigger-to-play probe.
    private static var requestedAt: CFAbsoluteTime = 0
    /// Recent trigger-to-play-call times in milliseconds, newest last. Probe for tests and diagnostics.
    private(set) static var recentPlayLatenciesMs: [Double] = []

    /// Starts the engine, routed to the UI sound target. Called on soundQueue only.
    private static func startEngine() throws {
        if !playerAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode,
                           format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
            playerAttached = true
            let observedEngine = engine
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: observedEngine, queue: nil
            ) { _ in
                soundQueue.async {
                    guard engine === observedEngine else { return }
                    playback.outputChanged()
                }
            }
        }
        // Route before the engine starts. Earcons go to the system alert output, or the built-in
        // speakers when that output is AirPlay or Bluetooth.
        if !engine.isRunning, let target = UISoundRouting.currentTarget(), let unit = engine.outputNode.audioUnit {
            var device = target.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        try engine.start()
    }

    private static let playback: SoundCuePlaybackQueue<AVAudioPCMBuffer> = SoundCuePlaybackQueue(
        isRunning: { engine.isRunning },
        start: { try startEngine() },
        play: { buffer, completion in
            let now = CFAbsoluteTimeGetCurrent()
            recentPlayLatenciesMs.append((now - requestedAt) * 1000)
            if recentPlayLatenciesMs.count > 50 { recentPlayLatenciesMs.removeFirst() }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                soundQueue.async { completion() }
            }
            player.play()
        },
        rebuild: {
            if let observer = configurationObserver {
                NotificationCenter.default.removeObserver(observer)
                configurationObserver = nil
            }
            player.stop()
            engine.stop()
            engine.reset()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            playerAttached = false
        },
        duration: { Double($0.frameLength) / $0.format.sampleRate },
        scheduleTimeout: { seconds, action in soundQueue.asyncAfter(deadline: .now() + seconds, execute: action) },
        failed: { error in Telemetry.log("sound.output_failed", properties: ["code": (error as NSError).code]) }
    )

    /// Optional local default-theme reference assets, imported from the installed
    /// Wispr archive. Assets stay in the user's private support folder, outside
    /// source control. Missing assets retain the existing synthesized fallback.
    private static func referenceCue(_ name: String, volume: Float = 1) -> AVAudioPCMBuffer? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Flow/ReferenceSounds/\(name).wav")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 5),
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }
            try file.read(into: input)
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * sampleRate / input.format.sampleRate)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
                  let converter = AVAudioConverter(from: input.format, to: format) else { return nil }
            var supplied = false
            var conversionError: NSError?
            let result = converter.convert(to: output, error: &conversionError) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            guard result != .error, conversionError == nil, output.frameLength > 0 else { return nil }
            if volume != 1, let channels = output.floatChannelData {
                for channel in 0..<Int(output.format.channelCount) {
                    var gain = volume
                    vDSP_vsmul(channels[channel], 1, &gain, channels[channel], 1, vDSP_Length(output.frameLength))
                }
            }
            return output
        } catch { return nil }
    }

    // MARK: - Public

    /// Recording-on earcon. Warm, inviting tap.
    static func playStart() {
        guard enabled else { return }
        renderAndPlay(reference: "start", duration: 0.18, peakAmplitude: 0.15) { t, dur in
            let n = noiseTransient(t: t, decayMs: 8, color: .high)
            // Body: A4 (440) with a 12-cent upward glide over the first 30ms
            let glide = 1.0 + 0.007 * smoothRise(t: t, ms: 30)
            let body = pluckTone(
                t: t,
                freq: 440.0 * glide,
                decay: 0.040,           // ~40ms tonal decay
                harmonics: [(1.0, 1.00), (2.01, 0.32), (3.03, 0.10)],
                inharmonicity: 0.004
            )
            // Reverb-like tail: dampened sine, very low amplitude
            let tail = exp(-t / 0.060) * sin(2.0 * .pi * 523.25 * t) * 0.05
            return (noise: n * 0.55, body: body * 0.85 + tail, t: t, dur: dur)
        }
    }

    /// Recording-off earcon. Dampened descending pluck. "Got it."
    static func playStop() {
        guard enabled else { return }
        renderAndPlay(reference: "stop", duration: 0.22, peakAmplitude: 0.15) { t, dur in
            // Soft front-end transient — quieter than start (not a warning)
            let n = noiseTransient(t: t, decayMs: 6, color: .mid)
            // Low tone with a slight downward glide over 50ms
            let glideAmt = 1.0 - 0.04 * smoothRise(t: t, ms: 50)
            let freq = 300.0 * glideAmt
            let body = pluckTone(
                t: t,
                freq: freq,
                decay: 0.070,           // longer woody decay
                harmonics: [(1.0, 1.00), (2.0, 0.22), (3.0, 0.07)],
                inharmonicity: 0.002
            )
            // Slight sub-octave shimmer for warmth
            let sub = exp(-t / 0.080) * sin(2.0 * .pi * 130.81 * t) * 0.10
            return (noise: n * 0.30, body: body * 0.90 + sub, t: t, dur: dur)
        }
    }

    /// Paste-complete earcon. Subliminal soft pluck.
    static func playDone() {
        guard enabled else { return }
        renderAndPlay(reference: "done", duration: 0.18, peakAmplitude: 0.09) { t, dur in
            // Almost no transient — just air
            let n = noiseTransient(t: t, decayMs: 3, color: .high) * 0.20
            // C5 (523.25) plus a quiet upper tone
            let body1 = pluckTone(
                t: t,
                freq: 523.25,
                decay: 0.060,
                harmonics: [(1.0, 1.00), (2.0, 0.15)],
                inharmonicity: 0.003
            )
            let body2 = pluckTone(
                t: t,
                freq: 987.77,
                decay: 0.018,
                harmonics: [(1.0, 0.45)],
                inharmonicity: 0.0
            )
            return (noise: n, body: (body1 + body2) * 0.75, t: t, dur: dur)
        }
    }

    /// Hands-free lock-engaged earcon. Two quick warm taps — a "latched"
    /// signature distinct from the single start tap (mirrors Wispr's
    /// two-tap popo-lock feel without shipping their asset). ~170ms.
    static func playLock() {
        guard enabled else { return }
        renderAndPlay(reference: "lock", duration: 0.17, peakAmplitude: 0.20) { t, dur in
            let n = noiseTransient(t: t, decayMs: 5, color: .mid) * 0.40
            // Tap 1 at onset, Tap 2 offset ~55ms → "ka-chunk" lock rhythm.
            let tap1 = pluckTone(
                t: t, freq: 440.0, decay: 0.030,
                harmonics: [(1.0, 1.00), (2.0, 0.25), (3.0, 0.08)],
                inharmonicity: 0.003
            )
            let t2 = t - 0.055
            let tap2 = t2 > 0 ? pluckTone(
                t: t2, freq: 440.0, decay: 0.035,
                harmonics: [(1.0, 1.00), (2.0, 0.25), (3.0, 0.08)],
                inharmonicity: 0.003
            ) : 0
            return (noise: n, body: (tap1 + tap2) * 0.70, t: t, dur: dur)
        }
    }

    /// Wispr plays a card's sound by its status, at half volume: error, alert, or success for info.
    enum NoticeStatus { case error, alert, info }
    static func playNotice(_ status: NoticeStatus) {
        guard enabled else { return }
        let name: String
        switch status {
        case .error: name = "error"
        case .alert: name = "alert"
        case .info: name = "success"
        }
        soundQueue.async {
            if let buffer = noticeCue(name) { playback.enqueue(buffer) }
            else {
                switch status {
                case .error: playError()
                case .alert: playStop()
                case .info: playDone()
                }
            }
        }
    }

    /// Error / no-speech earcon. Low, slightly dissonant falling double-tone —
    /// reads unmistakably as "wrong" without being harsh. Quiet. ~240ms.
    static func playError() {
        guard enabled else { return }
        renderAndPlay(reference: "error", duration: 0.24, peakAmplitude: 0.17) { t, dur in
            let n = noiseTransient(t: t, decayMs: 6, color: .low) * 0.30
            // Two low tones a minor-second apart (G3 + G#3) → gentle dissonance,
            // both gliding down slightly for a "deflating" negative feel.
            let glide = 1.0 - 0.10 * smoothRise(t: t, ms: 80)
            let a = pluckTone(
                t: t, freq: 196.00 * glide, decay: 0.090,
                harmonics: [(1.0, 1.00), (2.0, 0.18)], inharmonicity: 0.002
            )
            let b = pluckTone(
                t: t, freq: 207.65 * glide, decay: 0.090,
                harmonics: [(1.0, 0.70)], inharmonicity: 0.002
            )
            return (noise: n, body: (a + b) * 0.60, t: t, dur: dur)
        }
    }

    // MARK: - Synthesis helpers

    private enum NoiseColor { case high, mid, low }

    /// Single-pole noise shaping state per call.
    private final class NoiseState {
        var lp: Double = 0  // low-pass state
        var hp: Double = 0  // high-pass state
    }

    /// Filtered noise burst with fast exponential decay.
    /// Used as the percussive transient ("tssst") at the head of each sound.
    /// NOTE: Returns shaped noise per-call sample; deterministic decay envelope.
    private static func noiseTransient(t: Double, decayMs: Double, color: NoiseColor) -> Double {
        // Deterministic pseudo-noise — cheap, avoids global RNG state
        // Hash time into a pseudo-random in [-1, 1].
        let scaled = t * sampleRate
        let bits = scaled.bitPattern &* 2862933555777941757 &+ 3037000493
        let u = Double(bits & 0xFFFFFFFF) / Double(UInt32.max)
        let raw = u * 2.0 - 1.0

        // Apply simple frequency coloring via a one-pole based on prior sample mix.
        // We approximate without per-call state by mixing with sin-based "tilt".
        let tilt: Double
        switch color {
        case .high:
            // Emphasize high freq → mostly raw noise plus high-pass-ish.
            tilt = raw - 0.4 * sin(2.0 * .pi * 220 * t)
        case .mid:
            tilt = raw * 0.7
        case .low:
            tilt = raw * 0.4 + 0.3 * sin(2.0 * .pi * 110 * t)
        }
        // Exponential decay envelope
        let decay = decayMs / 1000.0
        let env = exp(-t / decay)
        return tilt * env
    }

    /// A plucked tonal component: sum of (slightly inharmonic) sine harmonics
    /// with exponential decay. Per-harmonic decay scales with index for realism.
    private static func pluckTone(
        t: Double,
        freq: Double,
        decay: Double,                      // seconds for fundamental e-fold
        harmonics: [(ratio: Double, gain: Double)],
        inharmonicity: Double               // 0..0.01 typical
    ) -> Double {
        var sum: Double = 0
        for (idx, h) in harmonics.enumerated() {
            // Inharmonic stretch: each partial slightly sharper than integer ratio
            let stretch = 1.0 + inharmonicity * Double(idx * idx)
            let f = freq * h.ratio * stretch
            // Higher harmonics decay faster (natural pluck behavior)
            let hDecay = decay / (1.0 + 0.6 * Double(idx))
            let env = exp(-t / hDecay)
            sum += sin(2.0 * .pi * f * t) * h.gain * env
        }
        return sum
    }

    /// Smooth 0→1 ramp over `ms` milliseconds (cosine ease).
    private static func smoothRise(t: Double, ms: Double) -> Double {
        let dur = ms / 1000.0
        if t >= dur { return 1.0 }
        let x = t / dur
        return 0.5 - 0.5 * cos(.pi * x)
    }

    // MARK: - Render core

    /// Per-sample synthesis result.
    private typealias VoiceFrame = (noise: Double, body: Double, t: Double, dur: Double)

    /// Render the per-sample voice closure into a stereo buffer with
    /// subtle stereo widening (right channel delayed ~0.6ms + slight gain trim).
    ///
    /// Synthesis and engine graph changes use a serial background queue so
    /// closely spaced feedback cues cannot race or block the main thread.
    private static func renderAndPlay(
        reference: String,
        duration: Double,
        peakAmplitude: Float,
        voice: @escaping (Double, Double) -> VoiceFrame
    ) {
        let requested = CFAbsoluteTimeGetCurrent()
        onSoundQueue {
            requestedAt = requested
            if let cached = cueCache[reference] {
                playback.enqueue(cached)
                return
            }
            if let referenceBuffer = referenceCue(reference) {
                cueCache[reference] = referenceBuffer
                if !prewarming { playback.enqueue(referenceBuffer) }
                return
            }
            let frameCount = AVAudioFrameCount(sampleRate * duration)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount

            guard let ch0 = buffer.floatChannelData?[0],
                  let ch1 = buffer.floatChannelData?[1] else { return }

            // Master envelope: 1.5ms cosine attack, exponential decay for the body
            // (per-component decays already shape the tail; this just removes any DC click).
            let attackSec = 0.0015
            let releaseSec = duration * 0.15
            let releaseStartSec = duration - releaseSec

            // Stereo widening: ~0.6ms inter-channel delay (Haas effect)
            let delayFrames = Int(sampleRate * 0.0006)

            // First pass: synthesize mono into a scratch buffer so we can apply
            // delay-based widening cleanly + measure peak for normalization.
            var mono = [Double](repeating: 0, count: Int(frameCount))
            var peak: Double = 0
            for i in 0..<Int(frameCount) {
                let t = Double(i) / sampleRate
                let frame = voice(t, duration)

                // Master attack/release (anti-click)
                var menv: Double = 1.0
                if t < attackSec {
                    menv = 0.5 - 0.5 * cos(.pi * t / attackSec)
                } else if t > releaseStartSec {
                    let r = (t - releaseStartSec) / releaseSec
                    menv = 0.5 + 0.5 * cos(.pi * r)
                }

                // Mix noise + body. Noise is already enveloped internally.
                let s = (frame.noise + frame.body) * menv
                mono[i] = s
                if abs(s) > peak { peak = abs(s) }
            }

            // Normalize to peakAmplitude target (prevents clipping, RMS-matches sounds)
            let norm = peak > 0 ? Double(peakAmplitude) / peak : Double(peakAmplitude)

            for i in 0..<Int(frameCount) {
                let l = Float(mono[i] * norm)
                // Right channel: delayed copy at ~0.97 gain (gentle Haas widening)
                let j = i - delayFrames
                let r = (j >= 0) ? Float(mono[j] * norm * 0.97) : 0
                ch0[i] = l
                ch1[i] = r
            }

            cueCache[reference] = buffer
            if prewarming { return }
            playback.enqueue(buffer)
        }
    }

    /// True only while `prewarm()` renders cues. Renders are cached but nothing is played.
    private static var prewarming = false

    /// Reference or synthesized error/alert/success cue at half volume, cached after the first build.
    private static func noticeCue(_ name: String) -> AVAudioPCMBuffer? {
        let key = "notice-\(name)"
        if let cached = cueCache[key] { return cached }
        guard let buffer = referenceCue(name, volume: 0.5) else { return nil }
        cueCache[key] = buffer
        return buffer
    }

    /// Test hook: forget every rendered cue so the next call measures a cold render.
    static func resetCueCacheForTesting() {
        onSoundQueue { cueCache = [:] }
    }

    /// Renders every earcon once and starts the engine on the UI sound target, so the first
    /// real cue has no cold start. Safe to call more than once. Plays nothing.
    static func prewarm() {
        guard enabled else { return }
        onSoundQueue {
            prewarming = true
            playStart(); playStop(); playDone(); playLock(); playError()
            prewarming = false
            for name in ["error", "alert", "success"] { _ = noticeCue(name) }
            try? startEngine()
        }
    }
}
