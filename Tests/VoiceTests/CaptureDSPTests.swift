import Accelerate
import AVFoundation
import Foundation
import Testing
@testable import Voice

/// Frozen, verbatim copy of AudioCaptureService's DSP code as it was before the
/// CaptureDSP extraction (13 Nov 2026, AudioCaptureService.swift.bak-20261113-replay):
/// the first-buffer bootstrap and smoothed-RMS update from processAudioBuffer, and
/// applyDSPChain with its scratch helpers. Do not edit; it is the reference the
/// shared chain must match bit for bit.
private final class LegacyCaptureDSP {
    private let sampleRate: Double = 16000
    private let silenceFloorRMS: Float = 0.0008
    private var smoothedRMS: Float = 0
    private var adaptiveGain: Float = 1.0
    private var limiterEnv: Float = 0
    private var hpfPrevIn: Float = 0
    private var hpfPrevOut: Float = 0
    private var preEmphPrev: Float = 0
    private var preEmphPrev2: Float = 0
    private var buffersSinceRecordStart: Int = 0
    private var preEmphScratch: [Float] = []
    private var preEmphScratch2: [Float] = []
    private var hpfInScratch: [Float] = []
    private var hpfOutScratch: [Float] = []
    let tuning: DSPTuning

    init(tuning: DSPTuning) { self.tuning = tuning }

    /// processAudioBuffer's DSP-relevant lines, in their original order.
    func process(_ channelData: UnsafeMutablePointer<Float>, frameCount: Int) -> Float {
        if self.buffersSinceRecordStart == 0 {
            var bootstrapRMS: Float = 0
            vDSP_rmsqv(channelData, 1, &bootstrapRMS, vDSP_Length(frameCount))
            self.smoothedRMS = bootstrapRMS
        }
        applyDSPChain(channelData: channelData, frameCount: frameCount, tuning: tuning)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))
        self.buffersSinceRecordStart &+= 1
        let alpha: Float = self.buffersSinceRecordStart <= 4 ? 0.5 : 0.1
        self.smoothedRMS = self.smoothedRMS * (1.0 - alpha) + rms * alpha
        return rms
    }

    func applyDSPChain(channelData: UnsafeMutablePointer<Float>,
                               frameCount: Int,
                               tuning: DSPTuning) {
        // Ensure reusable vDSP scratch buffers exist (grown lazily, no per-buffer
        // alloc in steady state once the first frameCount has been seen).
        ensurePreEmphScratch(frameCount)

        // ---- Stage 1: One-pole high-pass (DC removal + sub-80Hz rumble) ----
        // Standard one-pole HPF: y[n] = α·(y[n-1] + x[n] - x[n-1])
        //                            = α·x[n] − α·x[n-1] + α·y[n-1]
        // α = exp(-2π·fc/fs). At fc=80Hz, fs=16kHz → α ≈ 0.9691. Gives a
        // ~ -3dB point at 80Hz, 12dB/oct rolloff below. Cheaper than a biquad
        // and good enough for DC removal — the goal isn't surgical filtering,
        // it's preventing DC offset from eating dynamic range.
        //
        // VECTORIZED (vDSP_deq22): Direct Form II 2-pole/2-zero solver.
        // Replaces the per-sample scalar feedback loop with a single
        // Accelerate call. vDSP_deq22's contract is:
        //   C[n] = A[n]*B[0] + A[n-1]*B[1] + A[n-2]*B[2]
        //                    - C[n-1]*B[3] - C[n-2]*B[4]
        // For our 1st-order HPF we collapse to:
        //   B = [α, -α, 0, -α, 0]
        // which yields y[n] = α·x[n] − α·x[n-1] + α·y[n-1]. The 2nd-order
        // slots (B[2], B[4]) are zero so it degrades cleanly to 1st-order.
        // Inputs/outputs must include 2 samples of prior history; we keep
        // only the last input/output as before (the 2-back slot is unused
        // since B[2]=B[4]=0, so any value works — we pass zeros).
        if tuning.highPassCutoffHz > 0 && frameCount > 0 {
            let alpha: Float = expf(-2.0 * .pi * tuning.highPassCutoffHz / Float(sampleRate))
            // vDSP_deq22 requires (N + 2) input and output samples — slots
            // [0] and [1] are previous input/output history, [2..N+1] are
            // current. Since our 2-back coefficients are zero we only need
            // [1] to be set correctly; [0] can be anything (we use 0).
            ensureHPFScratch(frameCount)
            hpfInScratch.withUnsafeMutableBufferPointer { inBuf in
                hpfOutScratch.withUnsafeMutableBufferPointer { outBuf in
                    guard let inBase = inBuf.baseAddress,
                          let outBase = outBuf.baseAddress else { return }
                    inBase[0]  = 0
                    inBase[1]  = self.hpfPrevIn
                    outBase[0] = 0
                    outBase[1] = self.hpfPrevOut
                    // Copy current samples into the scratch input buffer
                    // starting at offset 2.
                    memcpy(inBase + 2, channelData, frameCount * MemoryLayout<Float>.size)
                    // Coefficients: y[n] = α·x[n] − α·x[n-1] + α·y[n-1]
                    //   B[0] =  α   (current input)
                    //   B[1] = −α   (1-back input)
                    //   B[2] =  0   (2-back input)
                    //   B[3] = −α   (1-back output; sign flips: −C·B = +α·y[n-1])
                    //   B[4] =  0   (2-back output)
                    var coeffs: [Float] = [alpha, -alpha, 0, -alpha, 0]
                    coeffs.withUnsafeBufferPointer { bPtr in
                        vDSP_deq22(inBase, 1, bPtr.baseAddress!, outBase, 1, vDSP_Length(frameCount))
                    }
                    // Copy filtered output (lives at outBase[2..N+1]) back
                    // into channelData in-place. Persist last raw input
                    // BEFORE this copy clobbers channelData (last raw input
                    // is the source's last sample, which we read from the
                    // scratch input buffer where it's still untouched).
                    self.hpfPrevIn  = inBase[frameCount + 1]
                    self.hpfPrevOut = outBase[frameCount + 1]
                    memcpy(channelData, outBase + 2, frameCount * MemoryLayout<Float>.size)
                }
            }
        }

        // ---- Stage 2: Pre-emphasis (FIR: y[n] = x[n] - α·x[n-1]) ----
        // Classic ASR front-end: ~+6dB/oct above ~1kHz. Helps Parakeet
        // disambiguate stops and fricatives in real-world recordings.
        // We apply it here (rather than as a separate model-side step) because
        // we ALSO want the on-disk file to carry it — the post-hoc batch
        // re-transcription pass should see the same signal as the live one.
        //
        // VECTORIZED (vDSP): y[n] = x[n] - α·x[n-1] is a length-2 FIR. We
        // capture the last input sample first (will be next buffer's prev),
        // shift the signal one sample (using preEmphPrev as the first prev),
        // then compute y = x - α·prev via vDSP_vsmsa-style fused ops. This
        // replaces a ~4096-iteration scalar Swift loop with a single
        // vectorized pass per buffer.
        if tuning.preEmphasisAlpha > 0 && frameCount > 0 {
            let a = tuning.preEmphasisAlpha
            let lastIn = channelData[frameCount - 1]
            // Build "prev" vector in scratch: [preEmphPrev, x[0], x[1], ..., x[N-2]]
            // then compute channelData[i] = channelData[i] - a * prev[i].
            // We use vDSP_vsmsa (multiply by scalar then add) with negated alpha
            // to fuse the multiply-subtract: y = (-a)*prev + x.
            preEmphScratch.withUnsafeMutableBufferPointer { scratch in
                guard let base = scratch.baseAddress else { return }
                base[0] = self.preEmphPrev
                if frameCount > 1 {
                    // copy x[0..N-2] → scratch[1..N-1]
                    memcpy(base + 1, channelData, (frameCount - 1) * MemoryLayout<Float>.size)
                }
                var negA = -a
                // y = (-a)*prev + x, written back into channelData
                vDSP_vsma(base, 1, &negA, channelData, 1, channelData, 1, vDSP_Length(frameCount))
            }
            self.preEmphPrev = lastIn
        }

        // ---- Stage 2b: Quiet-regime consonant lift (mumble robustness) ----
        // For whisper / quiet signals (RMS < 0.05, which is the "whisper" or
        // "quiet" regime in the diagnostic log) we apply a second, gentler
        // pre-emphasis pass. This pulls the 1–4 kHz consonant region up an
        // extra ~3 dB relative to the bass region without re-amplifying the
        // sub-300 Hz mud (already cut by the 120 Hz HPF). Trade-off: tiny
        // amount of high-frequency hiss gain — irrelevant after the model's
        // own MEL front-end, and the LLM polish washes through it. Skipped
        // on normal+loud speech (no benefit, and we'd over-spike sibilants).
        // Uses smoothedRMS so the decision is stable across buffer seams,
        // not flickering on per-buffer transients.
        if tuning.preEmphasisAlpha > 0 && self.smoothedRMS > silenceFloorRMS && self.smoothedRMS < 0.05 && frameCount > 0 {
            let a2: Float = 0.55  // lighter than the 0.97 main pass — adds a
                                  // second high-shelf without over-rolling lows
            // Vectorized FIR pass — see Stage 2 above for the rationale.
            let lastIn = channelData[frameCount - 1]
            preEmphScratch2.withUnsafeMutableBufferPointer { scratch in
                guard let base = scratch.baseAddress else { return }
                base[0] = self.preEmphPrev2
                if frameCount > 1 {
                    memcpy(base + 1, channelData, (frameCount - 1) * MemoryLayout<Float>.size)
                }
                var negA2 = -a2
                vDSP_vsma(base, 1, &negA2, channelData, 1, channelData, 1, vDSP_Length(frameCount))
            }
            self.preEmphPrev2 = lastIn
        } else {
            // Decay the second-stage memory toward zero so re-entering the
            // quiet regime starts from a clean state instead of a stale prev.
            self.preEmphPrev2 = 0
        }

        // ---- Stage 3: Adaptive gain (whisper boost) ----
        // Target a long-term RMS of tuning.targetRMS. If smoothedRMS is well
        // below target → ramp gain up. If at/above → ramp back to unity.
        // We never amplify when the signal is below the absolute silence floor
        // (would just amplify noise floor when nothing's happening).
        let s = self.smoothedRMS
        let targetGain: Float
        if s < silenceFloorRMS {
            // True silence — gently relax to unity. No point boosting noise.
            targetGain = 1.0
        } else if s < tuning.targetRMS {
            // Whisper / quiet speech — boost toward target, capped.
            targetGain = min(tuning.maxAdaptiveGain, tuning.targetRMS / max(s, 1e-5))
        } else {
            // Normal or loud — no boost. Limiter (stage 4) handles the top end.
            targetGain = 1.0
        }
        // Smooth the gain change (per-buffer, not per-sample — buffers are
        // ~25-256ms so this is plenty fine-grained for human dynamics).
        self.adaptiveGain += (targetGain - self.adaptiveGain) * tuning.agcSmoothing
        let gain = self.adaptiveGain
        if abs(gain - 1.0) > 0.001 {
            var g = gain
            vDSP_vsmul(channelData, 1, &g, channelData, 1, vDSP_Length(frameCount))
        }

        // ---- Stage 4: Soft-knee look-ahead limiter ----
        // Peak-following limiter with fast attack, slow release. We track an
        // envelope of |sample| and when it exceeds the ceiling, scale the
        // sample by ceiling/env. The 1-sample look-ahead (peek at next sample)
        // keeps very fast transients (consonant attacks, P-pops on a scream)
        // from leaking through. Soft knee: blend in the gain reduction over
        // a 6dB window below the ceiling for natural-sounding compression.
        let ceiling = tuning.limiterCeiling
        let kneeStart = ceiling * 0.5  // soft knee begins here
        // Fast attack (1ms ≈ 16 samples), slow release (50ms ≈ 800 samples).
        let attack: Float  = 1.0 - expf(-1.0 / (0.001 * Float(sampleRate)))
        let release: Float = 1.0 - expf(-1.0 / (0.050 * Float(sampleRate)))
        var env = self.limiterEnv
        for i in 0..<frameCount {
            let x = channelData[i]
            let absX = abs(x)
            // One-sample look-ahead — if next sample is louder, anticipate it.
            let next = (i + 1 < frameCount) ? abs(channelData[i + 1]) : absX
            let target = max(absX, next)
            if target > env {
                env += (target - env) * attack
            } else {
                env += (target - env) * release
            }
            // Compute gain reduction with soft knee:
            //   env <= kneeStart → no reduction
            //   env >= ceiling   → reduce to ceiling
            //   between          → smooth ramp (quadratic blend)
            var gr: Float = 1.0
            if env >= ceiling {
                gr = ceiling / env
            } else if env > kneeStart {
                let t = (env - kneeStart) / (ceiling - kneeStart)  // 0..1
                let softReduction = ceiling / env
                gr = 1.0 + (softReduction - 1.0) * t * t           // ease-in
            }
            channelData[i] = x * gr
        }
        self.limiterEnv = env
    }

    @inline(__always)
    private func ensurePreEmphScratch(_ frameCount: Int) {
        if preEmphScratch.count < frameCount {
            preEmphScratch = [Float](repeating: 0, count: frameCount)
        }
        if preEmphScratch2.count < frameCount {
            preEmphScratch2 = [Float](repeating: 0, count: frameCount)
        }
    }

    /// Ensure HPF biquad scratch I/O buffers can hold `frameCount + 2` floats.
    /// `+2` for the 2-sample history slots vDSP_deq22 reads from.
    @inline(__always)
    private func ensureHPFScratch(_ frameCount: Int) {
        let needed = frameCount + 2
        if hpfInScratch.count < needed {
            hpfInScratch = [Float](repeating: 0, count: needed)
        }
        if hpfOutScratch.count < needed {
            hpfOutScratch = [Float](repeating: 0, count: needed)
        }
    }
}

/// Deterministic speech-like fixture: a pitched, amplitude-modulated tone with
/// noise, moving through silence, whisper, quiet, normal and clipping-loud
/// sections so every DSP branch (silence relax, quiet-regime 2b, gain boost,
/// limiter knee and ceiling) is exercised.
private func fixture(seconds: Double = 12, seed: UInt64 = 7) -> [Float] {
    var state = seed
    func noise() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2_000_001 - 1_000_000) / 1_000_000
    }
    let count = Int(seconds * 16_000)
    let levels: [Float] = [0.0, 0.002, 0.006, 0.03, 0.15, 0.9, 1.6, 0.004, 0.0003, 0.08, 0.5, 0.01]
    return (0..<count).map { i in
        let t = Double(i) / 16_000
        let level = levels[min(levels.count - 1, Int(t))]
        let voice = sin(2 * .pi * 140 * t) * 0.6 + sin(2 * .pi * 1_900 * t) * 0.25 + sin(2 * .pi * 3_700 * t) * 0.1
        let envelope = 0.55 + 0.45 * sin(2 * .pi * 3.1 * t)
        return level * Float(voice * envelope) + level * 0.15 * noise() + 0.01 * level
    }
}

@Suite("Capture DSP extraction")
struct CaptureDSPTests {
    static let classes: [InputDeviceClass] = [.builtIn, .bluetooth, .usb, .external, .unknown]

    /// Feeds identical buffers through the frozen pre-refactor code and CaptureDSP.
    func compare(_ cls: InputDeviceClass, bufferSizes: [Int]) {
        let input = fixture()
        let tuning = DSPTuning.forDevice(cls)
        let legacy = LegacyCaptureDSP(tuning: tuning)
        var shared = CaptureDSP(tuning: tuning)
        var start = 0, index = 0, mismatches = 0
        while start < input.count {
            let size = min(bufferSizes[index % bufferSizes.count], input.count - start)
            var a = Array(input[start..<start + size])
            var b = a
            let rmsA = a.withUnsafeMutableBufferPointer { legacy.process($0.baseAddress!, frameCount: size) }
            let rmsB = shared.process(&b)
            if rmsA.bitPattern != rmsB.bitPattern { mismatches += 1 }
            for i in 0..<size where a[i].bitPattern != b[i].bitPattern { mismatches += 1 }
            start += size; index += 1
        }
        #expect(mismatches == 0, "\(cls.rawValue) sizes \(bufferSizes): \(mismatches) differing values")
    }

    @Test("Bit-identical to the old in-place chain in 4,096-frame buffers, every device class")
    func identicalTapBuffers() {
        for cls in Self.classes { compare(cls, bufferSizes: [4096]) }
    }

    @Test("Bit-identical with 48 kHz-tap-sized and irregular buffers")
    func identicalOtherBuffers() {
        for cls in Self.classes {
            compare(cls, bufferSizes: [1365, 1366])
            compare(cls, bufferSizes: [512, 4096, 37, 2048, 1])
        }
    }

    @Test("The fixture exercises the gain boost, the limiter and the quiet regime")
    func fixtureCoversBranches() {
        var dsp = CaptureDSP(tuning: .forDevice(.builtIn))
        var samples = fixture()
        var maxGain: Float = 1, sawQuiet = false
        var start = 0
        while start < samples.count {
            let size = min(4096, samples.count - start)
            samples.withUnsafeMutableBufferPointer { _ = dsp.process($0.baseAddress! + start, frameCount: size) }
            maxGain = max(maxGain, dsp.adaptiveGain)
            if dsp.smoothedRMS > CaptureDSP.silenceFloorRMS && dsp.smoothedRMS < 0.05 { sawQuiet = true }
            start += size
        }
        #expect(maxGain > 2)
        #expect(sawQuiet)
        // The soft limiter (1 ms attack) pulled the clipping-loud section down.
        let inputPeak = fixture().map { abs($0) }.max() ?? 0
        let outputPeak = samples.map { abs($0) }.max() ?? 0
        #expect(inputPeak > 1.5 && outputPeak < inputPeak * 0.8)
    }

    @Test("Very soft built-in microphone input survives capture's speech gate when confidently decoded")
    func softCaptureMeetsSpeechPresenceGate() {
        let quiet = Array(fixture(seconds: 3)[32_000..<48_000])
        var dsp = CaptureDSP(tuning: .forDevice(.builtIn))
        var peak: Float = 0
        var voiced = 0.0
        var quietVoiced = 0.0
        for start in stride(from: 0, to: 32_000, by: 1_600) {
            let offset = start % quiet.count
            var samples = Array(quiet[offset..<offset + 1_600])
            let rms = dsp.process(&samples)
            peak = max(peak, rms)
            if rms >= CaptureDSP.speechFloorRMS { voiced += 0.1 }
            if rms >= CaptureDSP.quietSpeechFloorRMS { quietVoiced += 0.1 }
        }
        #expect(SpeechPresenceGate.dropReason(joinedText: "Please check the input level.", voicedSeconds: voiced,
            peakRMS: peak, quietVoicedSeconds: quietVoiced, recognitionConfidence: 0.92) == nil)
    }

    @Test("mic_class strings map to the device tunings")
    func micClass() {
        #expect(DSPTuning.forMicClass("builtIn") == .forDevice(.builtIn))
        #expect(DSPTuning.forMicClass("usb") == .forDevice(.usb))
        #expect(DSPTuning.forMicClass("bluetooth") == .forDevice(.bluetooth))
        #expect(DSPTuning.forMicClass("something") == .forDevice(.unknown))
        #expect(DSPTuning.forMicClass(nil) == .forDevice(.unknown))
    }
}

@Suite("Cleanup replay capture")
struct CaptureReplayTests {
    func writeWAV(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString).wav")
        try ShadowStore.wavData(samples: samples).write(to: url)
        return url
    }

    @Test("16 kHz WAV: 4,096-frame taps through CaptureDSP, padded .caf of the live size")
    func rendersLikeCapture() throws {
        let input = Array(fixture(seconds: 3).map { max(-1, min(1, $0 * 0.5)) })
        let wav = try writeWAV(input)
        let caf = wav.deletingPathExtension().appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: caf) }
        let result = try CaptureReplay.render(source: wav, to: caf, applyDSP: true, tuning: .forDevice(.usb))

        // Expected: the WAV as Parakeet would read it, cut into 4,096-frame buffers, through CaptureDSP.
        let decoded = try TranscriptionService.readSamplesAt16kMono(url: wav)
        var dsp = CaptureDSP(tuning: .forDevice(.usb))
        var expected: [Float] = []
        var voiced = 0.0, peak: Float = 0
        var start = 0
        while start < decoded.count {
            var chunk = Array(decoded[start..<min(start + 4096, decoded.count)])
            let rms = dsp.process(&chunk)
            peak = max(peak, rms)
            if rms >= CaptureDSP.speechFloorRMS { voiced += Double(chunk.count) / 16_000 }
            expected += chunk
            start += 4096
        }
        #expect(result.samples == expected)
        #expect(result.peakRMS == peak)
        #expect(abs(result.voicedSeconds - voiced) < 1e-9)
        #expect(abs(result.capturedSeconds - 3) < 1e-6)

        let written = try TranscriptionService.readSamplesAt16kMono(url: caf)
        #expect(written.count == 1920 + input.count + 960)
        #expect(written.prefix(1920).allSatisfy { $0 == 0 } && written.suffix(960).allSatisfy { $0 == 0 })
        #expect(Array(written[1920..<(1920 + input.count)]) == expected)
        #expect(result.fileBytes > (1920 + input.count + 960) * 4)
    }

    @Test("Post-DSP audio (dsp: false) is copied unchanged, without extra padding")
    func copiesPostDSP() throws {
        let input = Array(fixture(seconds: 1.5).map { max(-1, min(1, $0 * 0.3)) })
        let wav = try writeWAV(input)
        let caf = wav.deletingPathExtension().appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: caf) }
        let result = try CaptureReplay.render(source: wav, to: caf, applyDSP: false, tuning: .forDevice(.builtIn))
        let decoded = try TranscriptionService.readSamplesAt16kMono(url: wav)
        #expect(result.samples == decoded)
        #expect(try TranscriptionService.readSamplesAt16kMono(url: caf) == decoded)
    }

    @Test("Resume reads only finished ids; lines are sorted JSON with unescaped slashes")
    func resume() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try CleanupReplayHarness.appendLine(["id": "a", "status": "ok", "audio": "x/y"], to: url)
        try CleanupReplayHarness.appendLine(["id": "b", "status": "error"], to: url)
        #expect(CleanupReplayHarness.completedIDs(url) { $0["status"] as? String == "ok" } == ["a"])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("{\"audio\":\"x/y\",\"id\":\"a\",\"status\":\"ok\"}\n"))
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }
}
