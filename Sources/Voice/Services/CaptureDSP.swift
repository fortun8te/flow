// Flow — capture DSP chain (pure, shared)
// ============================================================
// The exact per-buffer signal chain AudioCaptureService applies to every
// resampled 16 kHz mono Float32 tap buffer before it reaches Parakeet and the
// retained `.caf`. Extracted (13 Nov 2026) so the headless
// `Flow --cleanup-prepare` replay runs the same code as live capture.
// Behaviour is byte-identical to the old in-place chain; see
// Tests/VoiceTests/CaptureDSPTests.swift, which keeps a frozen copy of the
// pre-refactor code and compares output bit for bit.
//
// Per buffer, in order (unchanged from the live service):
//   0. First buffer only: bootstrap smoothedRMS from the raw (pre-DSP) RMS.
//   1. One-pole high-pass (vDSP_deq22).
//   2. Pre-emphasis 0.97.
//   2b. Quiet-regime second pre-emphasis 0.55 (smoothedRMS in (silence floor, 0.05)).
//   3. Adaptive gain from the previous smoothedRMS.
//   4. Soft-knee look-ahead limiter.
//   5. Post-DSP RMS, then smoothedRMS update (alpha 0.5 for the first 4 buffers, then 0.1).
// ============================================================

import Accelerate

struct DSPTuning: Equatable, Sendable {
    /// Whether to enable AVAudioEngine voice processing (AEC + AGC + NS).
    let voiceProcessingEnabled: Bool
    /// Maximum adaptive gain we'll apply to a whisper (linear). 4.0 ≈ +12dB.
    let maxAdaptiveGain: Float
    /// RMS target the adaptive gain tries to reach for whispers.
    let targetRMS: Float
    /// Limiter ceiling (post-gain). 0.95 leaves ~0.4dB headroom under digital max.
    let limiterCeiling: Float
    /// Pre-emphasis coefficient (0 disables). Standard ASR value is 0.97.
    let preEmphasisAlpha: Float
    /// High-pass cutoff in Hz (0 disables). 80Hz removes DC + low rumble without
    /// touching voice fundamentals (male fundamental ~85Hz).
    let highPassCutoffHz: Float
    /// AGC attack/release smoothing (per-buffer, 0..1). Smaller = slower / less pumping.
    let agcSmoothing: Float

    static func forDevice(_ cls: InputDeviceClass) -> DSPTuning {
        switch cls {
        case .builtIn:
            // Noisy environment likely — but VPIO disabled across the board:
            // Apple's voice-processing AU is known to drop levels or produce
            // intermittent silence on built-in MacBook mics, especially after
            // route changes. Our own DSP chain (HPF + pre-emphasis + adaptive
            // gain + limiter) handles whisper boost and clarity; the LLM
            // polish stage handles any residual noise/disfluency. Trust the
            // raw signal — it's more reliable.
            //
            // MUMBLE-ROBUSTNESS TUNING (May 2026):
            // - highPassCutoffHz raised 80 → 120 Hz. Loses some warmth on
            //   deep voices (fundamental ~85 Hz), but removes more of the
            //   low-frequency mush (HVAC, fan rumble, body-contact thumps
            //   on the chassis) that masks mumbled consonants in the
            //   400 Hz – 4 kHz speech-intelligibility band. Net win for
            //   ASR clarity on mumbled / quiet speech; downstream LLM
            //   polish further normalizes prosody.
            return DSPTuning(voiceProcessingEnabled: false, maxAdaptiveGain: 5.0,
                             targetRMS: 0.08, limiterCeiling: 0.95,
                             preEmphasisAlpha: 0.97, highPassCutoffHz: 120,
                             agcSmoothing: 0.08)
        case .bluetooth:
            // AirPods etc. already AGC heavily and bandlimit to 8–16kHz. Don't
            // double-process — light gain, light limiter, no extra HPF (their
            // codec already strips below ~100Hz).
            //
            // CRITICAL: voiceProcessingEnabled is FALSE for bluetooth. Apple's
            // VPIO unit + AirPods is a known-bad combo — it produces silence,
            // garbled audio, or forces the device into SCO/HFP 8kHz mode
            // (instead of the much-better AAC mic profile). AirPods do their
            // own HW noise reduction; double-processing destroys quality and
            // frequently breaks capture entirely. Trust the device.
            return DSPTuning(voiceProcessingEnabled: false, maxAdaptiveGain: 3.0,
                             targetRMS: 0.08, limiterCeiling: 0.97,
                             preEmphasisAlpha: 0.97, highPassCutoffHz: 0,
                             agcSmoothing: 0.06)
        case .usb, .external:
            // Studio mic — trust it. Disable voice processing entirely (it
            // destroys quality on a good condenser). Keep just safety limiter
            // + DC removal + pre-emphasis for ASR.
            return DSPTuning(voiceProcessingEnabled: false, maxAdaptiveGain: 2.0,
                             targetRMS: 0.1, limiterCeiling: 0.97,
                             preEmphasisAlpha: 0.97, highPassCutoffHz: 80,
                             agcSmoothing: 0.05)
        case .unknown:
            // Same reasoning as .builtIn — VPIO off by default.
            return DSPTuning(voiceProcessingEnabled: false, maxAdaptiveGain: 3.5,
                             targetRMS: 0.08, limiterCeiling: 0.95,
                             preEmphasisAlpha: 0.97, highPassCutoffHz: 80,
                             agcSmoothing: 0.08)
        }
    }

    /// `mic_class` strings written by scripts/prepare-wispr-cleanup-v2.py
    /// (`InputDeviceClass` raw values). Anything else is `.unknown`.
    static func forMicClass(_ name: String?) -> DSPTuning {
        forDevice(name.flatMap(InputDeviceClass.init(rawValue:)) ?? .unknown)
    }
}

struct CaptureDSP {
    static let sampleRate: Double = 16_000
    /// ~-62 dBFS. Below this is true silence (AudioCaptureService.silenceFloorRMS).
    static let silenceFloorRMS: Float = 0.0008
    /// ~-46 dBFS post-DSP. Above this a buffer counts as voiced (AudioCaptureService.speechFloorRMS).
    static let speechFloorRMS: Float = 0.005
    /// Weak activity for the speech-presence rescue. The normal and media gates use speechFloorRMS.
    static let quietSpeechFloorRMS: Float = 0.0015

    let tuning: DSPTuning
    private(set) var smoothedRMS: Float = 0
    private(set) var adaptiveGain: Float = 1.0
    private var limiterEnv: Float = 0
    private var hpfPrevIn: Float = 0
    private var hpfPrevOut: Float = 0
    private var preEmphPrev: Float = 0
    /// Second-pass (quiet-regime) pre-emphasis history; reset to 0 outside that regime.
    private var preEmphPrev2: Float = 0
    /// Buffers processed since this recording (or device switch) started.
    private(set) var buffersSinceRecordStart: Int = 0

    // Reusable vDSP scratch, grown lazily to the largest buffer seen.
    private var preEmphScratch: [Float] = []
    private var preEmphScratch2: [Float] = []
    private var hpfInScratch: [Float] = []
    private var hpfOutScratch: [Float] = []

    init(tuning: DSPTuning) {
        self.tuning = tuning
    }

    /// Runs the whole chain in place and returns the buffer's post-DSP RMS
    /// (the value the live service meters, gates speech presence on and feeds
    /// back into the next buffer's gain decision).
    @discardableResult
    mutating func process(_ samples: inout [Float]) -> Float {
        let count = samples.count
        guard count > 0 else { return 0 }
        return samples.withUnsafeMutableBufferPointer { buffer in
            process(buffer.baseAddress!, frameCount: count)
        }
    }

    @discardableResult
    mutating func process(_ channelData: UnsafeMutablePointer<Float>, frameCount: Int) -> Float {
        guard frameCount > 0 else { return 0 }
        // Bootstrap smoothedRMS on the very first buffer so the adaptive-gain
        // stage doesn't see smoothedRMS=0 and fall into the "true silence"
        // branch, which would suppress boost on a whisper that starts the
        // moment the hotkey fires. Raw (pre-DSP) RMS.
        if buffersSinceRecordStart == 0 {
            var bootstrapRMS: Float = 0
            vDSP_rmsqv(channelData, 1, &bootstrapRMS, vDSP_Length(frameCount))
            smoothedRMS = bootstrapRMS
        }

        applyChain(channelData: channelData, frameCount: frameCount)

        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameCount))

        // Smoothed long-term RMS used by the next buffer's adaptive-gain decision.
        // Two-stage attack: fast alpha=0.5 for the first ~1s (4 buffers @ 256ms),
        // then alpha=0.1 (~2.5s time constant) to avoid pumping.
        buffersSinceRecordStart &+= 1
        let alpha: Float = buffersSinceRecordStart <= 4 ? 0.5 : 0.1
        smoothedRMS = smoothedRMS * (1.0 - alpha) + rms * alpha
        return rms
    }

    /// In-place chain on the post-resample 16kHz mono Float32 buffer. State is
    /// continuous across buffer boundaries (HPF, pre-emphasis, gain, limiter).
    private mutating func applyChain(channelData: UnsafeMutablePointer<Float>, frameCount: Int) {
        let tuning = self.tuning
        let sampleRate = Self.sampleRate
        let silenceFloorRMS = Self.silenceFloorRMS
        if preEmphScratch.count < frameCount { preEmphScratch = [Float](repeating: 0, count: frameCount) }
        if preEmphScratch2.count < frameCount { preEmphScratch2 = [Float](repeating: 0, count: frameCount) }

        // ---- Stage 1: One-pole high-pass, y[n] = a*x[n] - a*x[n-1] + a*y[n-1] ----
        // vDSP_deq22 with B = [a, -a, 0, -a, 0]; I/O carry 2 samples of history.
        if tuning.highPassCutoffHz > 0 && frameCount > 0 {
            let alpha: Float = expf(-2.0 * .pi * tuning.highPassCutoffHz / Float(sampleRate))
            let needed = frameCount + 2
            if hpfInScratch.count < needed { hpfInScratch = [Float](repeating: 0, count: needed) }
            if hpfOutScratch.count < needed { hpfOutScratch = [Float](repeating: 0, count: needed) }
            var prevIn = hpfPrevIn
            var prevOut = hpfPrevOut
            hpfInScratch.withUnsafeMutableBufferPointer { inBuf in
                hpfOutScratch.withUnsafeMutableBufferPointer { outBuf in
                    guard let inBase = inBuf.baseAddress,
                          let outBase = outBuf.baseAddress else { return }
                    inBase[0]  = 0
                    inBase[1]  = prevIn
                    outBase[0] = 0
                    outBase[1] = prevOut
                    memcpy(inBase + 2, channelData, frameCount * MemoryLayout<Float>.size)
                    var coeffs: [Float] = [alpha, -alpha, 0, -alpha, 0]
                    coeffs.withUnsafeBufferPointer { bPtr in
                        vDSP_deq22(inBase, 1, bPtr.baseAddress!, outBase, 1, vDSP_Length(frameCount))
                    }
                    prevIn  = inBase[frameCount + 1]
                    prevOut = outBase[frameCount + 1]
                    memcpy(channelData, outBase + 2, frameCount * MemoryLayout<Float>.size)
                }
            }
            hpfPrevIn = prevIn
            hpfPrevOut = prevOut
        }

        // ---- Stage 2: Pre-emphasis, y[n] = x[n] - a*x[n-1] ----
        if tuning.preEmphasisAlpha > 0 && frameCount > 0 {
            let a = tuning.preEmphasisAlpha
            let lastIn = channelData[frameCount - 1]
            let prev = preEmphPrev
            preEmphScratch.withUnsafeMutableBufferPointer { scratch in
                guard let base = scratch.baseAddress else { return }
                base[0] = prev
                if frameCount > 1 {
                    memcpy(base + 1, channelData, (frameCount - 1) * MemoryLayout<Float>.size)
                }
                var negA = -a
                vDSP_vsma(base, 1, &negA, channelData, 1, channelData, 1, vDSP_Length(frameCount))
            }
            preEmphPrev = lastIn
        }

        // ---- Stage 2b: Quiet-regime consonant lift (mumble robustness) ----
        if tuning.preEmphasisAlpha > 0 && smoothedRMS > silenceFloorRMS && smoothedRMS < 0.05 && frameCount > 0 {
            let a2: Float = 0.55
            let lastIn = channelData[frameCount - 1]
            let prev = preEmphPrev2
            preEmphScratch2.withUnsafeMutableBufferPointer { scratch in
                guard let base = scratch.baseAddress else { return }
                base[0] = prev
                if frameCount > 1 {
                    memcpy(base + 1, channelData, (frameCount - 1) * MemoryLayout<Float>.size)
                }
                var negA2 = -a2
                vDSP_vsma(base, 1, &negA2, channelData, 1, channelData, 1, vDSP_Length(frameCount))
            }
            preEmphPrev2 = lastIn
        } else {
            preEmphPrev2 = 0
        }

        // ---- Stage 3: Adaptive gain (whisper boost), from the PREVIOUS smoothedRMS ----
        let s = smoothedRMS
        let targetGain: Float
        if s < silenceFloorRMS {
            targetGain = 1.0
        } else if s < tuning.targetRMS {
            targetGain = min(tuning.maxAdaptiveGain, tuning.targetRMS / max(s, 1e-5))
        } else {
            targetGain = 1.0
        }
        adaptiveGain += (targetGain - adaptiveGain) * tuning.agcSmoothing
        let gain = adaptiveGain
        if abs(gain - 1.0) > 0.001 {
            var g = gain
            vDSP_vsmul(channelData, 1, &g, channelData, 1, vDSP_Length(frameCount))
        }

        // ---- Stage 4: Soft-knee look-ahead limiter ----
        let ceiling = tuning.limiterCeiling
        let kneeStart = ceiling * 0.5
        let attack: Float  = 1.0 - expf(-1.0 / (0.001 * Float(sampleRate)))
        let release: Float = 1.0 - expf(-1.0 / (0.050 * Float(sampleRate)))
        var env = limiterEnv
        for i in 0..<frameCount {
            let x = channelData[i]
            let absX = abs(x)
            let next = (i + 1 < frameCount) ? abs(channelData[i + 1]) : absX
            let target = max(absX, next)
            if target > env {
                env += (target - env) * attack
            } else {
                env += (target - env) * release
            }
            var gr: Float = 1.0
            if env >= ceiling {
                gr = ceiling / env
            } else if env > kneeStart {
                let t = (env - kneeStart) / (ceiling - kneeStart)
                let softReduction = ceiling / env
                gr = 1.0 + (softReduction - 1.0) * t * t
            }
            channelData[i] = x * gr
        }
        limiterEnv = env
    }
}
