// VOICE — Audio Capture Service
// ============================================================
// Handles all audio input: microphone via AVAudioEngine and
// system audio via ScreenCaptureKit (macOS 14+).
//
// Architecture:
// - Microphone: AVAudioEngine.inputNode tap → 16kHz mono Float32
// - System audio: SCStream with audio-only config → same format
// - Both feed the same PCM path for transcription and recording
// - The visualizer uses the post-DSP level
//
// TWEAK: sampleRate — 16000 is optimal for Whisper/Parakeet (don't change unless needed)
// TWEAK: bufferSize — 4096 samples = ~256ms chunks. Larger = more latency, less CPU
// TWEAK: fftSize — 32 bins for visualizer. More bins = more detail, more CPU
// TWEAK: silenceThreshold — energy level below which we consider silence
// ============================================================

import AVFoundation
import AudioToolbox
import CoreAudio
import Accelerate
import ScreenCaptureKit

// MARK: - Input Device Classification
// We tune the DSP chain per input device because the OS-level voice processing
// (AEC/AGC/NS) and the raw signal quality vary wildly across mic types:
//   - builtIn: noisy (fans, keys, room), narrow dynamic range, weak bass → max NS, moderate AGC
//   - bluetooth/AirPods: already does aggressive on-device NS+AGC → light touch from us
//   - usb/external: usually a studio-grade signal → minimal processing, trust the input
enum InputDeviceClass: String {
    case builtIn
    case bluetooth
    case usb
    case external
    case unknown
}

// DSPTuning and the DSP chain itself live in CaptureDSP.swift, shared with
// the headless `--cleanup-prepare` replay so the two cannot drift.

/// Best-effort human-readable name of the current default input device
/// (e.g. "AirPods Pro", "MacBook Pro Microphone", "Blue Yeti"). Used for
/// diagnostics so production logs identify what was actually being used.
fileprivate func currentInputDeviceName(_ deviceID: AudioDeviceID) -> String {
    guard deviceID != 0 else { return "<no device>" }
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<CFString?>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &name)
    guard status == noErr, let cfName = name?.takeRetainedValue() else {
        return "<id=\(deviceID)>"
    }
    return cfName as String
}

/// Detect the class of the current default input device by querying CoreAudio
/// for its transport type. We can't always tell which physical device the user
/// picked, so this is best-effort — falls back to .unknown on any failure.
fileprivate func detectInputDeviceClass(_ deviceID: AudioDeviceID) -> InputDeviceClass {
    guard deviceID != 0 else { return .unknown }

    var transport: UInt32 = 0
    var tsize = UInt32(MemoryLayout<UInt32>.size)
    var taddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let tstatus = AudioObjectGetPropertyData(deviceID, &taddr, 0, nil, &tsize, &transport)
    guard tstatus == noErr else { return .unknown }

    switch transport {
    case kAudioDeviceTransportTypeBuiltIn:    return .builtIn
    case kAudioDeviceTransportTypeBluetooth,
         kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
    case kAudioDeviceTransportTypeUSB:        return .usb
    case kAudioDeviceTransportTypeAggregate,
         kAudioDeviceTransportTypeVirtual,
         kAudioDeviceTransportTypeAirPlay,
         kAudioDeviceTransportTypeHDMI,
         kAudioDeviceTransportTypeDisplayPort: return .external
    default: return .unknown
    }
}

// MARK: - AudioCaptureService

@Observable
class AudioCaptureService {
    // TWEAK: Audio format settings
    private let sampleRate: Double = 16000      // Whisper/Parakeet expects 16kHz
    private let bufferSize: AVAudioFrameCount = 4096  // ~256ms per buffer
    private let fftBinCount = 32                // TWEAK: Number of visualizer bars

    // TWEAK: Silence detection
    // Absolute floor: anything below this is treated as digital silence (mic muted /
    // disconnected). Whispers normally sit around -50 to -30 dBFS → RMS ~0.003 to 0.03,
    // so we use a very low absolute floor and an adaptive RMS-aware check on top of it.
    //
    // MUMBLE-ROBUSTNESS NOTE (verified May 2026): 0.0008 (~-62 dBFS) is intentionally
    // below where any real mumble sits — typical mumble RMS is 0.002–0.008 (-54 to
    // -42 dBFS), 2.5x to 10x above this floor. Lowering the floor further would
    // mostly trigger on noise; raising it would clip whispered words. The adaptive
    // gain stage (stage 3 in CaptureDSP) is what makes the mumble audible —
    // not a permissive floor. Voice-processing (AEC/AGC/NS) is OFF across the
    // board (see DSPTuning), so nothing in our chain is crushing whisper signals.
    private let silenceFloorRMS: Float = CaptureDSP.silenceFloorRMS  // 0.0008, ~-62 dBFS — below this is true silence

    // ============================================================
    // SPEECH-PRESENCE GATE (VAD) — anti-hallucination
    // ============================================================
    // Whisper/Parakeet-family models emit phantom phrases ("Thank you.",
    // "Thanks for watching.", "you", etc.) when fed silence or non-speech
    // room noise. To guarantee "no speech in → no text out", we measure an
    // AUDIO-based speech-presence signal during capture (it can't be fooled
    // by the text the model invents) and expose it to the finalize path,
    // which drops the transcript to empty when the clip was effectively silent.
    //
    // The signal is the total VOICED DURATION: the wall-clock duration of
    // post-DSP buffers whose RMS exceeded `speechFloorRMS`. We accumulate it
    // per recording starting at startMicrophoneCapture and read a snapshot at
    // stop/claim time.
    //
    // TWEAK: speechFloorRMS — a frame counts as "voiced" only above this.
    // It sits ~6x above the absolute silence floor (0.0008). RMS is measured
    // POST-DSP (adaptive gain applied), so quiet whispers get boosted toward
    // ~targetRMS (0.08) before this check. Track weaker input separately for the recognition check.
    // Room noise / breathing / HVAC after a 120Hz HPF sits well below it.
    private let speechFloorRMS: Float = CaptureDSP.speechFloorRMS   // 0.005, ~-46 dBFS post-DSP — above this a frame is "voiced"
    /// Accumulated voiced duration (seconds) for the current recording —
    /// sum of buffer durations whose post-DSP RMS exceeded speechFloorRMS.
    /// Read via `voicedDurationSeconds`; reset on each capture start.
    private var voicedDurationSec: Double = 0
    private var quietVoicedDurationSec: Double = 0
    /// Total wall-clock duration (seconds) of every buffer captured this recording.
    /// The media-leak guard divides voiced time by this to get the speech share.
    private var capturedDurationSec: Double = 0
    /// Peak post-DSP RMS observed across the whole current recording. A second,
    /// cheaper signal: if the loudest frame never cleared the speech floor the
    /// clip is certainly non-speech. Reset on each capture start.
    private var recordingPeakRMS: Float = 0

    /// Snapshot of the current recording's speech-presence signal. Read by the
    /// finalize path (RecordingCoordinator) to decide whether to keep the
    /// transcript. `voicedSeconds` is the total time spent above speechFloorRMS;
    /// `peakRMS` is the loudest post-DSP frame seen. Safe to read after
    /// stopCapture() — these are plain values updated on the audio thread and
    /// only read once capture has been torn down.
    var voicedDurationSeconds: Double { voicedDurationSec }
    var quietVoicedDurationSeconds: Double { quietVoicedDurationSec }
    var capturedDurationSeconds: Double { capturedDurationSec }
    var recordingPeakRMSValue: Float { recordingPeakRMS }

    // State
    var isCapturing = false
    /// Most recent selected input or fallback, for non-disruptive status UI.
    private(set) var microphoneStatus: String = ""
    /// Name of the microphone the current or last recording uses (after any silent-start failover).
    private(set) var activeMicrophoneName: String?
    /// Silent-start failover state. Audio-thread fields are guarded by `probeLock`, read from the main thread.
    private let probeLock = NSLock()
    private var capturedBuffers = 0
    /// Audio thread only: loudest sample in the first `MicrophoneFailover.probeSeconds` of this recording.
    private var startupPeak: Float = 0
    private var startupCheckScheduled = false
    /// Main thread only: at most one failover per recording.
    private var failedOverThisRecording = false
    var audioLevels: [Float] = Array(repeating: 0, count: 32)
    var currentRMS: Float = 0
    /// Peak |sample| from the last processed buffer (0…1+). Useful for surfacing
    /// limiter activity / clipping in diagnostics.
    var currentPeak: Float = 0
    /// Normalized 0..1 "is the mic hearing me" level for UI meters. Computed
    /// with a perceptual curve (sqrt on RMS, scaled so conversational speech
    /// sits at ~0.4-0.7 and whispers register visibly at ~0.1-0.2) so the
    /// waveform pill always breathes when the user is making sound — even on
    /// a quiet built-in MacBook mic. Updated every buffer (~25-256ms).
    var currentInputLevel: Float = 0
    /// Wispr's pill level: decibels above the quietest sound heard so far, over a 20 dB
    /// range, averaged every 150 ms (main process `Jr` scaler, -60 dB lowest floor).
    var barLevel: Float = 0
    private var barLevelFloorDb: Float = 0          // audio thread only
    private var pendingBarLevels: [Float] = []      // main thread only
    private var barLevelTimer: Timer?               // main thread only
    /// The per-buffer DSP chain and all of its state (HPF / pre-emphasis
    /// history, smoothed RMS, adaptive gain, limiter envelope, buffer count).
    /// Shared with the headless replay (`Flow --cleanup-prepare`); see
    /// CaptureDSP.swift. Replaced with a fresh instance on every recording
    /// start and device switch. Audio thread only once capture is running.
    private var dsp = CaptureDSP(tuning: DSPTuning.forDevice(.builtIn))
    /// Detected input device class, used to tune the processing chain per device.
    private var inputClass: InputDeviceClass = .builtIn
    /// Diagnostic counter — buffers processed since last DSP log line.
    private var buffersSinceDSPLog: Int = 0
    /// Rolling per-second peak |sample| value, used to surface near-silent
    /// recordings in logs. If this stays <0.001 for the entire session the
    /// user's mic is muted / routed wrong / capturing the wrong device.
    private var peakSampleThisSecond: Float = 0
    private var lastPeakLogAt: Date = Date()
    /// One-shot flag so we log "visualizer using post-DSP samples" exactly once
    /// per recording, the first time we see a non-silent buffer. Lets us confirm
    /// from the logs that the visualizer is reading the post-DSP signal (the one
    /// that has adaptive gain applied) rather than the raw input.
    private var loggedPostDSPVisualizer: Bool = false

    // Internal
    private var audioEngine: AVAudioEngine?
    private var boundInputDeviceID: AudioDeviceID?
    /// True while the input tap is installed and we're actively delivering
    /// buffers. Distinct from `audioEngine != nil` (the engine may be alive
    /// but idle, with no tap) and from `isCapturing` (which also implies a
    /// live recording session). Used so the tap closure can early-out if a
    /// stale buffer arrives during teardown.
    private var tapInstalled = false
    /// Idle grace timer. When a recording stops we remove the tap immediately
    /// (so the OS mic-in-use / orange indicator clears) but keep the
    /// AVAudioEngine instance ALIVE for a short grace window. If another
    /// recording starts within the window we reuse the same engine — no
    /// engine.start()/stop() hardware cycle. See `idleGraceSeconds` and the
    /// media-resume rationale on `stopCapture()`.
    private var idleEngineTimer: Timer?
    /// How long to keep the engine running with no active recording before we
    /// physically stop + release it. Long enough that back-to-back dictations
    /// reuse one engine (no HW cycling → no media-remote "resume"), short
    /// enough that the mic-in-use indicator clears soon after the user stops.
    private let idleGraceSeconds: TimeInterval = 25.0
    /// Callback that receives the resampled 16kHz mono PCM buffer
    /// (same buffer written to disk). Used by the live-partials sliding window.
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?
    fileprivate var audioConverter: AVAudioConverter?
    fileprivate var targetFormat: AVAudioFormat?
    private var configChangeToken: NSObjectProtocol?

    // Optional passthrough writer — when set (via startWritingToFile), every
    // resampled 16kHz mono Float32 buffer is appended to this file. Used by
    // batch transcription to read exactly the PCM retained during capture.
    private var audioFileWriter: AVAudioFile?
    /// Bytes written to the current audio file. Read by MeetingRecorder for
    /// the heartbeat log so we can verify the file is actually growing.
    private(set) var audioFileBytesWritten: Int64 = 0
    /// The on-disk URL currently being written to, if any.
    private(set) var audioFileURL: URL?
    /// Lock guarding `audioFileWriter` since the tap closures fire on a
    /// background queue while start/stop run on the main actor.
    private let writerLock = NSLock()
    /// Settings dict used to re-open the audio file if a write fails
    /// mid-recording (we then create a `-part2` sibling and keep going).
    private var audioFileSettings: [String: Any]?
    /// Monotonic suffix counter for stitched-part files (`-part2`, `-part3`).
    private var audioFilePartIndex: Int = 1
    /// All on-disk audio file URLs that have been written for the current
    /// recording. The first entry is the primary file; subsequent entries
    /// are part-2, part-3, etc. after re-open. Exposed so the caller can
    /// stitch them back together in post-processing.
    private(set) var audioFilePartURLs: [URL] = []
    /// Hard cap on how many re-opened part files we'll create in one recording
    /// before we give up and surface an error. Without this, a persistently
    /// failing writer (full disk, permission flap) can run away appending
    /// `.partN` URLs unbounded for the lifetime of the recording.
    private let maxAudioFileParts = 10
    /// Wall-clock time the engine was started; used to surface a warning
    /// once we cross the 2-hour mark on a single engine instance.
    private var engineStartedAt: Date?
    /// Set to true once we have logged the >2h warning so we don't spam.
    private var engineLongRunningWarningEmitted = false
    /// Driven by the audio tap — used to log a "still writing" heartbeat
    /// roughly every 10 seconds based on frames written, no Timer needed.
    private var framesSinceLastProgressLog: Int = 0

    /// Wall-clock of the last tap buffer we received, stored as a CFAbsoluteTime
    /// (Double) so the audio I/O thread can update it without a main-queue hop
    /// or a Date allocation on every buffer. The 8-byte aligned write is
    /// naturally atomic on arm64; the watchdog only needs an approximate
    /// timestamp (3-second tolerance), so a torn read is harmless in practice
    /// — and on Apple Silicon the read isn't torn anyway.
    /// Initialised lazily in startMicrophoneCapture.
    private var lastAudioReceivedAtCF: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    /// Periodic timer that fires `.voiceError` if no audio has arrived in
    /// >3s while we should be capturing. Created in startMicrophoneCapture,
    /// invalidated in stopCapture.
    private var silenceWatchdog: Timer?

    // MARK: - Public API

    /// Pre-warm the audio graph so the first `startMicrophoneCapture` call
    /// doesn't pay AVAudioEngine cold-start cost (~50–100ms on first record).
    ///
    /// We build a throwaway engine, touch its inputNode (resolves the audio
    /// graph and the input HAL unit), call `prepare()` to pre-allocate
    /// buffers, and discard it. We do NOT install a tap or call `start()` —
    /// the goal is to warm the OS-side audio subsystem, not to actually
    /// record. Safe to call from any thread; failures are swallowed.
    func warmup() {
        // Building an AVAudioEngine alone triggers HAL/AU initialization the
        // first time it happens in-process. We just need the side effects.
        let warmEngine = AVAudioEngine()
        _ = warmEngine.inputNode.inputFormat(forBus: 0)  // resolve input format
        warmEngine.prepare()                              // pre-alloc buffers
        // warmEngine deinits at scope exit — nothing else to clean up.
    }

    /// Start capturing from the resolved microphone.
    func startMicrophoneCapture() throws {
        // Idempotency guard: a prior capture may still be active if startRecording
        // was called twice in quick succession. Remove its tap + watchdog so we
        // don't leak a dangling tap. We DO NOT tear down the engine here — see
        // below; reusing a live engine across dictations is what stops macOS
        // from resuming the user's music on every recording.
        endActiveCapture(stopEngineNow: false)
        // Cancel any pending idle-grace teardown — we're recording again, so the
        // engine must stay up.
        idleEngineTimer?.invalidate()
        idleEngineTimer = nil

        // ENGINE LIFECYCLE / MEDIA-RESUME FIX (May 2026)
        // -------------------------------------------------
        // The capture graph is strictly INPUT-ONLY: we install a tap on
        // inputNode bus 0 and never touch mainMixerNode / outputNode / any
        // output connection, and VPIO stays OFF for every device class. So the
        // engine never engages the output bus. That is NOT what was resuming
        // the user's music.
        //
        // The real trigger was the per-dictation engine.start()/engine.stop()
        // hardware cycle. On macOS, *stopping* an input audio I/O unit nudges
        // the system now-playing / media-remote transport, which resumes a
        // media app (Apple Music / Spotify) that had been paused. Every
        // dictation did start→stop, so every dictation resumed music.
        //
        // Fix: keep the AVAudioEngine LONG-LIVED. Start it once and reuse it
        // across dictations; gate capture by installing/removing the input tap
        // rather than cycling the engine. We only physically engine.stop() after
        // an idle grace window (idleGraceSeconds) so the mic-in-use indicator
        // still clears when the user is done, while back-to-back dictations
        // never cycle the HW (and so never resume media).
        let preferredUID = UserDefaults.standard.string(forKey: MicrophonePreference.key) ?? ""
        let inputs = MicrophonePreference.inputs()
        let preferred = inputs.first { !preferredUID.isEmpty && $0.uid == preferredUID }
        let requestedInput = MicrophonePreference.resolve(preferredUID: preferredUID,
            priorityUIDs: MicrophonePreference.savedPriorityUIDs(),
            rememberedUID: MicrophoneFailover.rememberedUID(), inputs: inputs,
            defaultDeviceID: MicrophonePreference.defaultDeviceID())
        let reusedEngine: Bool
        if let existing = audioEngine, existing.isRunning, boundInputDeviceID == requestedInput {
            reusedEngine = true
        } else {
            // No live engine (cold start, or the idle grace already tore it
            // down). Build a fresh one.
            audioEngine?.stop()
            audioEngine = AVAudioEngine()
            boundInputDeviceID = nil
            reusedEngine = false
        }

        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode

        // A changed input gets a fresh engine, since a running audio unit may
        // reject rebinding. The saved preference survives a disconnect.
        guard requestedInput != 0, let unit = inputNode.audioUnit else {
            microphoneStatus = "No microphone available"
            throw NSError(domain: "Voice.Microphone", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone is available. Connect one and try again."])
        }
        do {
            var current = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let readStatus = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0, &current, &size)
            if readStatus != noErr || current != requestedInput {
                var desired = requestedInput
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0, &desired,
                                                  UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr {
                    throw NSError(domain: "Voice.Microphone", code: Int(status),
                                  userInfo: [NSLocalizedDescriptionKey: "Could not switch microphones. Try again after the microphone becomes available."])
                }
            }
            var verified = AudioDeviceID(0)
            var verifiedSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let verification = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                    kAudioUnitScope_Global, 0, &verified, &verifiedSize)
            guard verification == noErr, verified == requestedInput else {
                microphoneStatus = "Microphone could not be verified"
                throw NSError(domain: "Voice.Microphone", code: Int(verification),
                              userInfo: [NSLocalizedDescriptionKey: "Could not verify the microphone. Try again."])
            }
            boundInputDeviceID = verified
            let name = inputs.first { $0.deviceID == verified }?.name ?? "System microphone"
            activeMicrophoneName = name
            microphoneStatus = !preferredUID.isEmpty && preferred == nil ? "Preferred microphone unavailable. Using \(name)." : "Using \(name)."
            vlog("[VOICE-AC] \(microphoneStatus)")
        }

        // ===== Diagnostic snapshot of input state on hotkey press =====
        // The user reports "not really getting my audio properly" — these
        // logs let us see EXACTLY what AVAudioEngine and the OS think the
        // input device is at the moment recording starts.
        let preFormat = inputNode.inputFormat(forBus: 0)
        vlog("[VOICE-AC] Input format @ start: sr=\(preFormat.sampleRate)Hz channels=\(preFormat.channelCount) interleaved=\(preFormat.isInterleaved)")

        var osDeviceID = AudioDeviceID(0)
        var osSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var osAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                      &osAddr, 0, nil, &osSize, &osDeviceID) == noErr {
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(osDeviceID, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr,
               let cf = nameRef?.takeRetainedValue() {
                vlog("[VOICE-AC] OS default input: \(cf) (id=\(osDeviceID))")
            }
        }

        if preFormat.sampleRate <= 0 || preFormat.channelCount == 0 {
            vlog("[VOICE-AC] ERROR: invalid input format — sample rate or channel count is zero")
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["flowKind": "microphone", "message": "Mic unavailable — check input device in System Settings"]
            )
            throw NSError(domain: "VOICE-AC", code: -100,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid input format from AVAudioEngine"])
        }

        // Detect input device class and pick a DSP tuning. Done BEFORE we
        // toggle voice processing because USB studio mics want it OFF (the
        // OS-level AGC/NS destroys condenser-quality input), while built-in
        // and Bluetooth mics benefit from it (except AirPods — see DSPTuning).
        self.inputClass = detectInputDeviceClass(boundInputDeviceID ?? MicrophonePreference.defaultDeviceID())
        let tuning = DSPTuning.forDevice(self.inputClass)
        vlog("[VOICE-AC] input device: \"\(currentInputDeviceName(boundInputDeviceID ?? MicrophonePreference.defaultDeviceID()))\" class=\(self.inputClass.rawValue) — voiceProcessing=\(tuning.voiceProcessingEnabled) maxGain=\(tuning.maxAdaptiveGain)x")

        // Reset DSP state for a fresh recording.
        self.dsp = CaptureDSP(tuning: tuning)
        self.buffersSinceDSPLog = 0
        self.loggedPostDSPVisualizer = false
        // Reset the speech-presence (VAD) accumulators for a fresh recording.
        self.voicedDurationSec = 0
        self.quietVoicedDurationSec = 0
        self.capturedDurationSec = 0
        self.recordingPeakRMS = 0
        probeLock.lock()
        capturedBuffers = 0
        probeLock.unlock()
        startupPeak = 0
        startupCheckScheduled = false
        failedOverThisRecording = false

        // Opt into (or out of) AVAudioEngine voice processing per-device.
        // When enabled: gives us system-level AEC + AGC + NS — big quality
        // improvement for ASR in real-world conditions (typing, fans, room
        // reverb, voice too quiet). Must be set BEFORE the first call to
        // inputFormat / installTap, otherwise it throws kAudioUnitErr_Initialized.
        // Failures are non-fatal — we fall back to raw mic input.
        do {
            try inputNode.setVoiceProcessingEnabled(tuning.voiceProcessingEnabled)
            if tuning.voiceProcessingEnabled {
                vlog("[VOICE-AC] voice processing enabled (AEC + AGC + NS)")
                // On macOS 14+ we can tune the AGC behavior; on older releases
                // these properties no-op. The default AGC is conservative —
                // we leave it on but ensure our own adaptive-gain stage
                // handles whispers that AGC misses.
                #if os(macOS)
                if #available(macOS 14.0, *) {
                    inputNode.isVoiceProcessingAGCEnabled = true
                    inputNode.isVoiceProcessingBypassed = false
                    // CRITICAL: Disable "other audio" ducking entirely. The
                    // previous config (enableAdvancedDucking=true, duckingLevel=.default)
                    // caused music playing in Apple Music / Spotify / Safari on
                    // AirPods + external headphones to drop dramatically the
                    // moment we started capture. Voice should be a passive
                    // listener; never touch the user's playback mix.
                    // .min asks Core Audio to apply the smallest possible
                    // reduction (effectively none), and advanced ducking off
                    // disables the AVAudioEngine voice-processing AU's
                    // proprietary "other audio" attenuation. Together these
                    // make recording fully transparent to the playback bus.
                    inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                            enableAdvancedDucking: false,
                            duckingLevel: .min)
                }
                #endif
            } else {
                vlog("[VOICE-AC] voice processing DISABLED (studio mic — trusting input)")
            }
        } catch {
            vlog("[VOICE-AC] voice processing unavailable: \(error.localizedDescription)")
        }

        // Bluetooth High-Quality Recording (AirPods LAV-quality mic).
        //
        // iOS 26 introduces AVAudioSessionCategoryOptionBluetoothHighQualityRecording
        // which keeps AirPods in their high-bitrate AAC microphone profile instead of
        // falling back to the narrow-band SCO/HFP codec. On macOS, AVAudioSession is
        // not available and the Bluetooth stack is managed differently — AirPods
        // already prefer the higher-quality AAC profile when no active phone call is
        // in progress. The option is explicitly marked API_UNAVAILABLE(macos) in the
        // macOS SDK (AVAudioSessionTypes.h: API_AVAILABLE(ios(26.0)) API_UNAVAILABLE(macos)).
        //
        // TODO: If Apple adds an equivalent macOS API in a future SDK, enable here:
        //
        // if #available(macOS 26.0, *) {
        //     // Enable when SDK confirms macOS availability:
        //     // try AVAudioSession.sharedInstance().setCategory(
        //     //     .playAndRecord,
        //     //     mode: .measurement,
        //     //     options: [.bluetoothHighQualityRecording]
        //     // )
        // }
        //
        // For now: when a Bluetooth mic is detected, log the device name. The
        // presence of "Hands-Free" in the name indicates SCO/HFP 8kHz fallback
        // mode (another app has an active call session). Pure AAC mode shows
        // the clean device name ("AirPods Pro", "AirPods Max") at 24kHz.
        if self.inputClass == .bluetooth {
            let btName = currentInputDeviceName(boundInputDeviceID ?? MicrophonePreference.defaultDeviceID())
            let qualityHint = btName.lowercased().contains("hands-free") || btName.lowercased().contains("handsfree")
                ? "WARNING: HFP/SCO 8kHz fallback mode detected — close any active call in another app for full-quality AAC mic"
                : "AAC mic profile likely active (good)"
            vlog("[VOICE-AC] Bluetooth mic: \"\(btName)\" — \(qualityHint)")
        }

        // Install tap + build converter for the current default input device.
        // Extracted into a helper so the route-change observer can re-run it
        // (the device's sample rate / channel count may have changed when the
        // user plugged in AirPods, switched to a USB mic, etc.).
        try installInputTap(on: inputNode)

        // Handle audio route changes (headphones plugged/unplugged, AirPods
        // disconnect, default input switched in Sound prefs, etc.).
        //
        // The engine itself is not enough — when the device class changes,
        // the input node's format changes too, so the old tap is reading
        // against a stale format and either produces silence (rate mismatch
        // → converter chokes) or 0-channel buffers. We must:
        //   1. stop the engine
        //   2. remove the old tap
        //   3. re-detect device class + tuning + voice-processing setting
        //   4. re-read inputFormat and rebuild the converter
        //   5. install a fresh tap at the new native format
        //   6. start the engine again
        // Without all 6, the moment a user plugs in AirPods mid-recording,
        // capture goes silent for the rest of the session.
        // Register the route-change observer once per engine instance. On a
        // reused engine the token from the previous recording is still valid
        // (it survives endActiveCapture(stopEngineNow:false)), so we only add
        // it when we actually built a fresh engine.
        if !reusedEngine {
            if let token = configChangeToken {
                NotificationCenter.default.removeObserver(token)
                configChangeToken = nil
            }
            configChangeToken = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                guard let self = self, self.isCapturing else { return }
                self.handleConfigurationChange()
            }
        }

        if reusedEngine {
            // No HW cycle — the engine was already running from a prior
            // dictation within the idle grace window. This is the path that
            // avoids the media-remote "resume" on the user's music.
            vlog("[VOICE-AC] AVAudioEngine REUSED (already running) — no HW start/stop cycle")
            Telemetry.log("audio.engine_lifecycle", properties: ["action": "reused"])
        } else {
            do {
                try engine.start()
                vlog("[VOICE-AC] AVAudioEngine STARTED at \(Date()) (running=\(engine.isRunning))")
                Telemetry.log("audio.engine_lifecycle", properties: ["action": "started"])
            } catch {
                vlog("[VOICE-AC] AVAudioEngine.start THREW: \(error.localizedDescription)")
                Telemetry.log("audio.capture_start_failed", properties: [
                    "error": "\(error.localizedDescription)"
                ])
                throw error
            }
        }
        tapInstalled = true
        isCapturing = true
        engineStartedAt = engineStartedAt ?? Date()
        engineLongRunningWarningEmitted = false

        // Observability — capture lifecycle + media-safety markers.
        // voice_processing is logged because a voice-processing (VPIO) input
        // unit on macOS behaves like a playAndRecord session and its teardown
        // can emit a media-remote "play" that resumes the user's music. We keep
        // VPIO OFF across all device classes (see DSPTuning), so capture is a
        // pure record-only unit that does not register with the now-playing /
        // media-remote transport. Logging it makes that invariant auditable
        // from events.jsonl if the music-autoplay bug ever resurfaces.
        Telemetry.log("audio.capture_start", properties: [
            // Engine identifier so events.jsonl can attribute any media-autoplay
            // event to the right audio engine (this dictation-capture engine vs
            // the wake-word engine vs the SoundEffects output engine).
            "engine": "dictation_capture",
            "device": currentInputDeviceName(boundInputDeviceID ?? MicrophonePreference.defaultDeviceID()),
            "device_class": self.inputClass.rawValue,
            "voice_processing": inputNode.isVoiceProcessingEnabled,
            "input_sr": preFormat.sampleRate,
            "input_ch": Int(preFormat.channelCount)
        ])

        // Tell the pill when dictation starts on a different microphone than last time,
        // so it can show "Using <mic>" for a moment, as the reference does.
        let micName = currentInputDeviceName(boundInputDeviceID ?? MicrophonePreference.defaultDeviceID())
        let lastMic = UserDefaults.standard.string(forKey: "flow.lastMicName")
        if lastMic != micName {
            UserDefaults.standard.set(micName, forKey: "flow.lastMicName")
            if lastMic != nil {
                let label = self.inputClass.rawValue == "builtIn" ? "Built-in mic (recommended)" : micName
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name("flow.micSwitched"), object: nil,
                                                    userInfo: ["label": label])
                }
            }
        }

        // Watchdog: if no audio arrives for 3s while we should be capturing,
        // assume the mic died (permission revoked, device disconnected, HAL
        // wedged) and surface a user-visible error so the recording isn't
        // silently empty. Timer fires on the main run loop.
        self.lastAudioReceivedAtCF = CFAbsoluteTimeGetCurrent()
        self.silenceWatchdog?.invalidate()
        self.silenceWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isCapturing else { return }
            if CFAbsoluteTimeGetCurrent() - self.lastAudioReceivedAtCF > 3.0 {
                vlog("[VOICE] No audio received in 3s — likely permission revoked or device disconnected")
                NotificationCenter.default.post(
                    name: .voiceError,
                    object: nil,
                    userInfo: ["flowKind": "microphone", "message": "Microphone not responding — check permissions"]
                )
                self.silenceWatchdog?.invalidate()
                self.silenceWatchdog = nil
            }
        }
    }

    /// Start capturing system audio (all apps or specific app).
    /// Requires Screen Recording permission on macOS.
    func startSystemAudioCapture() async throws {
        // Idempotency: tear down any in-flight mic capture first so we don't
        // leak the AVAudioEngine + tap + watchdog when switching capture modes.
        // Fully release the mic engine here (stopEngineNow:true) — we're
        // switching to the ScreenCaptureKit output-tap path and won't reuse the
        // input engine, so there's no benefit to keeping it warm and we don't
        // want a stray idle-grace timer stopping it mid system-audio session.
        endActiveCapture(stopEngineNow: true)

        // TWEAK: To capture a specific app (e.g., Chrome for Google Meet),
        // filter by bundleIdentifier in the SCShareableContent query below.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Capture all audio (system-wide)
        // TWEAK: To filter specific apps, create SCContentFilter with specific windows/apps
        let filter = SCContentFilter(display: content.displays.first!, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true  // Don't capture our own audio
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1

        // TWEAK: We don't need video — set minimum to reduce overhead
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1fps minimum

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)

        let audioHandler = AudioStreamHandler { [weak self] buffer in
            self?.processAudioBuffer(buffer)
        }
        try stream.addStreamOutput(audioHandler, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()

        isCapturing = true
        // System-audio capture is pure output-tapping via ScreenCaptureKit; it
        // never opens an input/voice-processing unit, so it can't nudge media.
        Telemetry.log("audio.capture_start", properties: ["source": "system_audio"])
    }

    /// Begin writing every resampled 16 kHz mono Float32 buffer to a `.caf`
    /// file at `url`. Calling again closes the previous file first. Throws
    /// if AVAudioFile can't be created (bad path, permissions).
    ///
    /// Format choice: CAF + Float32 mono @ 16 kHz keeps the file losslessly
    /// identical to what the streaming engine sees, which is what we need
    /// for a faithful batch re-transcription pass at meeting end.
    func startWritingToFile(url: URL) throws {
        // Close any previous file first.
        stopWritingToFile()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        // .caf settings — Float32, mono, 16 kHz.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false
        ]

        // Make sure the parent directory exists.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        _ = format // appease analyzer; settings dict drives format

        writerLock.lock()
        self.audioFileWriter = file
        self.audioFileURL = url
        self.audioFileBytesWritten = 0
        self.audioFileSettings = settings
        self.audioFilePartIndex = 1
        self.audioFilePartURLs = [url]
        self.framesSinceLastProgressLog = 0
        // Lead-in zero padding (~120ms @ 16kHz). Parakeet decodes a right-
        // context window per token and tends to drop the very first word
        // when the audio starts mid-syllable (hotkey-to-record latency
        // means the user is often already speaking when capture begins).
        // Cheap zeros give the encoder a clean run-up before real audio.
        if let padBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1920) {
            padBuffer.frameLength = 1920  // 120ms at 16kHz
            if let ch = padBuffer.floatChannelData?[0] {
                memset(ch, 0, Int(padBuffer.frameLength) * MemoryLayout<Float>.size)
            }
            try? file.write(from: padBuffer)
            self.audioFileBytesWritten = Int64(1920) * 4
        }
        writerLock.unlock()
    }

    /// All on-disk part URLs for the current/most-recent recording.
    /// Returns the primary URL plus any `-partN` siblings created by
    /// the re-open-on-write-failure path. Caller is responsible for
    /// stitching these together in post-processing.
    func currentAudioFileParts() -> [URL] {
        writerLock.lock(); defer { writerLock.unlock() }
        return audioFilePartURLs
    }

    /// Stop the on-disk passthrough writer. Safe to call when no writer is
    /// active. Subsequent samples will not be persisted until
    /// `startWritingToFile` is called again.
    /// Stops the writer only if it is still the one for `url`. A session that finishes after a new
    /// recording has started must not close that new recording's file (sol/01 finding 1). Returns
    /// false, and leaves the writer alone, when the writer belongs to someone else.
    @discardableResult
    func stopWritingToFile(ifURL url: URL) -> Bool {
        writerLock.lock()
        let owned = audioFileURL == url
        writerLock.unlock()
        guard owned else { return false }
        stopWritingToFile()
        return true
    }

    /// True while the writer for `url` is still the active one.
    func isWritingToFile(_ url: URL) -> Bool {
        writerLock.lock(); defer { writerLock.unlock() }
        return audioFileURL == url
    }

    func stopWritingToFile() {
        // Capture the writer reference before clearing it so that AVAudioFile's
        // deinit (which flushes and closes the file) fires OUTSIDE the lock.
        // If AVAudioFile.deinit ever acquires an internal Core Audio lock, doing
        // so inside writerLock creates a lock-ordering hazard with the audio tap
        // callback (which holds writerLock while calling writer.write(_:)).
        let closing: AVAudioFile?
        writerLock.lock()
        closing = audioFileWriter
        // Trailing zero padding (~60ms @ 16kHz) before close. Symmetric to
        // the lead-in pad in startWritingToFile — gives Parakeet's right-
        // context window enough samples to finalize the last token's
        // duration prediction. Without this the final word can be clipped
        // ("that" → "tha") on tight push-to-talk stops.
        if let writer = closing, let format = targetFormat,
           let padBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960) {
            padBuffer.frameLength = 960  // 60ms at 16kHz
            if let ch = padBuffer.floatChannelData?[0] {
                memset(ch, 0, Int(padBuffer.frameLength) * MemoryLayout<Float>.size)
            }
            try? writer.write(from: padBuffer)
            audioFileBytesWritten &+= Int64(960) * 4
        }
        audioFileWriter = nil
        audioFileURL = nil
        writerLock.unlock()
        _ = closing  // deinit fires here, outside the lock
    }

    /// Stop all audio capture.
    ///
    /// IDEMPOTENT: safe to call any number of times; a no-op once capture is
    /// already stopped (beyond re-arming the idle-grace timer, which is cheap).
    ///
    /// MEDIA-RESUME FIX: this does NOT call `engine.stop()`. Stopping the input
    /// audio unit is what nudged macOS's media-remote transport into resuming
    /// the user's paused music on every dictation. Instead we remove the input
    /// tap immediately (which clears the OS mic-in-use / orange indicator) and
    /// leave the AVAudioEngine *running* for a short idle grace window. If a new
    /// recording starts within that window we reuse the same engine (no HW
    /// cycle → no media resume). Only after `idleGraceSeconds` of no recording
    /// do we physically stop + release the engine — see `releaseEngine()`.
    ///
    /// This path issues no media-remote command of any kind: removing a tap and
    /// (later) stopping a record-only, VPIO-off input unit is the only audio API
    /// it touches. There is no MPRemoteCommandCenter / now-playing call anywhere
    /// in this service.
    func stopCapture() {
        // Snapshot the VAD signals into the telemetry BEFORE we tear down — the
        // accumulators themselves are left intact so the finalize path
        // (RecordingCoordinator) can still read voicedDurationSeconds /
        // recordingPeakRMSValue after this returns, exactly as before.
        let wasCapturing = isCapturing
        endActiveCapture(stopEngineNow: false)

        if wasCapturing {
            // Logical capture_stop marker. NOTE: with the long-lived engine this
            // is no longer a hardware teardown — the engine keeps running until
            // the idle grace elapses. Kept for the existing audit trail; the new
            // `audio.engine_lifecycle` events distinguish real start/stop.
            Telemetry.log("audio.capture_stop", properties: [
                "engine": "dictation_capture",
                "voiced_seconds": voicedDurationSec,
                "peak_rms": recordingPeakRMS
            ])
        }

        // Arm (or re-arm) the idle-grace teardown. If no new recording starts
        // within idleGraceSeconds we physically stop + release the engine so the
        // mic-in-use indicator clears. Back-to-back dictations cancel this timer
        // in startMicrophoneCapture and reuse the engine.
        if audioEngine != nil {
            idleEngineTimer?.invalidate()
            idleEngineTimer = Timer.scheduledTimer(withTimeInterval: idleGraceSeconds,
                                                   repeats: false) { [weak self] _ in
                guard let self = self, !self.isCapturing else { return }
                self.releaseEngine(reason: "idle_grace")
            }
        }

        // Note: stopWritingToFile() is intentionally NOT called here. The
        // owner (MeetingRecorder) controls the file lifecycle separately so
        // it can finalize the file deterministically after stopCapture()
        // returns, and so a momentary engine restart on
        // AVAudioEngineConfigurationChange doesn't truncate the file.
    }

    /// Tear down the *active capture* (tap + watchdog + UI level state) without
    /// necessarily stopping the engine. The single place that removes the input
    /// tap, so both stopCapture() and a re-entrant startMicrophoneCapture() go
    /// through it. Idempotent.
    ///
    /// - Parameter stopEngineNow: when true, also physically stops + releases
    ///   the engine immediately (used by `releaseEngine`); when false, the
    ///   engine is left running for the idle-grace window.
    private func endActiveCapture(stopEngineNow: Bool) {
        if tapInstalled, let engine = audioEngine {
            // Remove the tap BEFORE any (deferred) engine stop. Removing the tap
            // alone does not touch the now-playing / media-remote transport;
            // only stopping the unit does, which is why we defer that.
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        isCapturing = false
        audioLevels = Array(repeating: 0, count: fftBinCount)
        visualizerPriorBins = Array(repeating: 0, count: fftBinCount)
        currentInputLevel = 0
        currentRMS = 0
        currentPeak = 0
        silenceWatchdog?.invalidate()
        silenceWatchdog = nil
        onPCMBuffer = nil

        if stopEngineNow {
            releaseEngine(reason: "explicit")
        }
    }

    /// Physically stop and release the AVAudioEngine. This is the ONLY place
    /// that calls `engine.stop()` for the mic path. Stopping the input unit can
    /// nudge macOS into resuming paused media, so we do it as rarely as
    /// possible — only after the idle grace window, or on an explicit teardown
    /// (e.g. switching to system-audio capture). Idempotent.
    private func releaseEngine(reason: String) {
        idleEngineTimer?.invalidate()
        idleEngineTimer = nil
        if let token = configChangeToken {
            NotificationCenter.default.removeObserver(token)
            configChangeToken = nil
        }
        if let engine = audioEngine {
            // Belt-and-suspenders: make sure no tap survives the stop.
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
            vlog("[VOICE-AC] AVAudioEngine STOPPED + released (reason=\(reason))")
            Telemetry.log("audio.engine_lifecycle", properties: ["action": "stopped", "reason": reason])
        }
        audioEngine = nil
        boundInputDeviceID = nil
        engineStartedAt = nil
        engineLongRunningWarningEmitted = false
    }

    // MARK: - Internal Processing

    /// (Re-)install the input tap and audio converter using the input node's
    /// CURRENT native format. Used both for initial startup and for route
    /// changes — must be safe to call when an existing tap may already be
    /// installed (we remove it first).
    ///
    /// Throws if the device reports an invalid format (0 channels / 0 Hz),
    /// which happens when permission was revoked or the device disappeared.
    private func installInputTap(on inputNode: AVAudioInputNode) throws {
        // Remove any prior tap idempotently — installing twice on the same bus
        // is a CoreAudio crash ("Cannot install tap on output channels 0..0").
        inputNode.removeTap(onBus: 0)

        // Read the device's NATIVE format AFTER voice-processing toggling has
        // settled. AirPods native = 16kHz/1ch over the mic profile; built-in =
        // 48kHz/1ch; USB varies (44.1/48/96kHz). Hard-coding 48kHz against a
        // 16kHz device produces silence (the converter is fed wrong-rate data
        // and just generates zeros). Native-format-in, converter-to-16kHz-out
        // is the only configuration that works across all device classes.
        let inputFormat = inputNode.inputFormat(forBus: 0)
        vlog("[VOICE-AC] mic input format: sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount) interleaved=\(inputFormat.isInterleaved) voiceProcessing=\(inputNode.isVoiceProcessingEnabled)")

        // Guard against the "zero-channel mic" failure mode that happens when
        // mic permission was just revoked or the input device disappeared
        // mid-session. AVAudioEngine will install the tap but the closure
        // never fires — recording silently produces 0 bytes. Surface it.
        if inputFormat.channelCount == 0 || inputFormat.sampleRate <= 0 {
            vlog("[VOICE-AC] FATAL: invalid mic input format — permission revoked or device missing")
            throw NSError(domain: "AudioCaptureService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable — check permissions and device selection"])
        }

        // Target format Whisper expects — 16kHz mono Float32.
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        // Audio converter for resampling whatever-the-device-gives-us → 16kHz mono.
        // Rebuilt on every tap install because the input format may have
        // changed (e.g. AirPods 16kHz → built-in 48kHz). A stale converter
        // configured for the old rate silently produces wrong output.
        // 23 Nov 2026: a multi-channel mic (this MacBook gives 3 channels, no layout) is averaged to mono here first,
        // then resampled. AVAudioConverter's own 3 -> 1 downmix gave exact zeros, and a channel map kept only ~1/10 of
        // the level ("microphone is too quiet"). Averaging keeps the full level (measured 0.0036 vs 0.0038 raw).
        let converterInput = inputFormat.channelCount > 1
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)!
            : inputFormat
        guard let converter = AVAudioConverter(from: converterInput, to: targetFormat) else {
            throw NSError(domain: "AudioCaptureService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
        }
        // Resampling quality: default is .medium (linear-ish). For ASR we want
        // .max which uses a long sinc kernel — eliminates aliasing on
        // 44.1/48k → 16k downsample and preserves consonant clarity.
        // Medium quality is plenty for 16kHz ASR — Mastering kernel was burning CPU on every buffer.
        converter.sampleRateConverterQuality = Int(AVAudioQuality.medium.rawValue)
        self.audioConverter = converter
        self.targetFormat = targetFormat
        self.tapInputFormat = (inputFormat.sampleRate, inputFormat.channelCount)

        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: inputFormat  // Use native format — required by AVAudioEngine
        ) { [weak self] buffer, _ in
            guard let self = self else { return }
            // Drop any buffer that arrives while we're not actively capturing.
            // With the long-lived engine the tap is removed on stopCapture()
            // but a buffer may already be in flight; ignoring it keeps a stale
            // frame from polluting the next recording's VAD accumulators.
            guard self.isCapturing else { return }
            // Update the watchdog timestamp in-place — CFAbsoluteTime is a
            // single 8-byte aligned Double, naturally atomic on arm64. No
            // main-queue hop, no Date allocation, no closure capture cost per
            // buffer (this fires every ~85ms during recording).
            self.lastAudioReceivedAtCF = CFAbsoluteTimeGetCurrent()
            self.processAudioBuffer(buffer)
        }
    }

    /// Re-configure the audio graph after a route change. macOS posts this
    /// when: AirPods connect/disconnect, headphones plugged/unplugged,
    /// default input changed in Sound prefs, USB audio interface hot-plug,
    /// or the system sample rate changes for any reason.
    ///
    /// Without a full reconfigure, the engine often runs but the tap fires
    /// against a stale format — typically producing silence on the new device.
    /// Sample rate and channels the current tap was built for.
    private var tapInputFormat: (sampleRate: Double, channels: AVAudioChannelCount)?

    /// A route change that leaves the engine running on the same kind of device at the same
    /// format needs nothing. macOS posts one ~90 ms after every cold engine start
    /// (events.jsonl 21 Nov 2026: `audio.device` builtIn → builtIn right after
    /// `audio.engine_lifecycle started`); rebuilding then stopped the engine on the main
    /// thread mid-press and dropped the first audio of the dictation.
    static func routeChangeNeedsRebuild(engineRunning: Bool, oldClass: String, newClass: String,
                                        oldFormat: (sampleRate: Double, channels: AVAudioChannelCount)?,
                                        newFormat: (sampleRate: Double, channels: AVAudioChannelCount)) -> Bool {
        guard engineRunning, oldClass == newClass, let oldFormat else { return true }
        return oldFormat.sampleRate != newFormat.sampleRate || oldFormat.channels != newFormat.channels
    }

    /// `force` rebuilds even when the route looks unchanged (a failover has already bound a new device).
    private func handleConfigurationChange(force: Bool = false) {
        guard let engine = self.audioEngine else { return }
        let liveFormat = engine.inputNode.inputFormat(forBus: 0)
        let liveClass = detectInputDeviceClass(boundInputDeviceID ?? MicrophonePreference.defaultDeviceID())
        if !force, !Self.routeChangeNeedsRebuild(engineRunning: engine.isRunning, oldClass: inputClass.rawValue,
                                         newClass: liveClass.rawValue, oldFormat: tapInputFormat,
                                         newFormat: (liveFormat.sampleRate, liveFormat.channelCount)) {
            Telemetry.log("audio.device_unchanged", properties: ["device_class": liveClass.rawValue,
                                                                 "input_sr": liveFormat.sampleRate])
            return
        }
        vlog("[VOICE-AC] route change — reconfiguring for new device: \"\(currentInputDeviceName(boundInputDeviceID ?? MicrophonePreference.defaultDeviceID()))\"")

        // Stop the engine before mutating the graph. Restarting without
        // stopping causes intermittent CoreAudio asserts on macOS.
        engine.stop()

        // Re-detect the device class and re-apply voice processing per the
        // new device's tuning. The previous device may have had VPIO enabled
        // (built-in) and the new one may need it disabled (AirPods, USB mic).
        let newClass = detectInputDeviceClass(boundInputDeviceID ?? MicrophonePreference.defaultDeviceID())
        let oldClass = self.inputClass
        self.inputClass = newClass
        let newTuning = DSPTuning.forDevice(newClass)
        vlog("[VOICE-AC] device class transition: \(oldClass.rawValue) → \(newClass.rawValue) — voiceProcessing=\(newTuning.voiceProcessingEnabled)")
        // Observability — a route change restarts the engine (stop→start). With
        // VPIO off this is media-safe, but log it so we can correlate any future
        // media-autoplay report with a device switch.
        Telemetry.log("audio.device", properties: [
            "device": currentInputDeviceName(boundInputDeviceID ?? MicrophonePreference.defaultDeviceID()),
            "from_class": oldClass.rawValue,
            "to_class": newClass.rawValue,
            "voice_processing": newTuning.voiceProcessingEnabled
        ])

        let inputNode = engine.inputNode
        do {
            try inputNode.setVoiceProcessingEnabled(newTuning.voiceProcessingEnabled)
            #if os(macOS)
            if #available(macOS 14.0, *), newTuning.voiceProcessingEnabled {
                inputNode.isVoiceProcessingAGCEnabled = true
                inputNode.isVoiceProcessingBypassed = false
                inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false,
                        duckingLevel: .min)
            }
            #endif
        } catch {
            vlog("[VOICE-AC] route-change voice-processing toggle failed: \(error.localizedDescription)")
        }

        // Reset DSP state — the old envelopes / smoothed RMS / adaptive gain
        // were tuned for the previous device's level + frequency response.
        // Carrying them over produces a brief gain/limiter glitch on switch.
        self.dsp = CaptureDSP(tuning: newTuning)

        // Rebuild tap + converter at the new device's native format.
        do {
            try installInputTap(on: inputNode)
        } catch {
            vlog("[VOICE-AC] route-change tap install failed: \(error.localizedDescription)")
            // The engine is stopped and we couldn't reinstall the tap. Mark
            // capture as no longer active so downstream state is consistent and
            // the silence watchdog doesn't fire a second, redundant error.
            isCapturing = false
            silenceWatchdog?.invalidate()
            silenceWatchdog = nil
            Telemetry.log("audio.capture_stop", properties: [
                "reason": "route_change_reconfig_failed"
            ])
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["flowKind": "microphone", "message": "Audio device changed but reconfiguration failed — try stopping and restarting recording"]
            )
            return
        }

        do {
            try engine.start()
            // Reset the watchdog clock so we don't immediately fire the
            // "no audio in 3s" alarm during the brief device-switch gap.
            self.lastAudioReceivedAtCF = CFAbsoluteTimeGetCurrent()
            let newFormat = inputNode.inputFormat(forBus: 0)
            vlog("[VOICE-AC] Post-reconfigure format: sr=\(newFormat.sampleRate)Hz channels=\(newFormat.channelCount)")
            vlog("[VOICE-AC] route change complete — engine restarted (running=\(engine.isRunning))")
        } catch {
            vlog("[VOICE-AC] route-change engine restart failed: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            isCapturing = false
            silenceWatchdog?.invalidate()
            silenceWatchdog = nil
            Telemetry.log("audio.capture_stop", properties: [
                "reason": "route_change_restart_failed"
            ])
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["flowKind": "microphone", "message": "Audio device changed and the microphone couldn't restart — stop and start recording again"]
            )
        }
    }

    /// Main thread, once per recording, 300 ms after the first buffer. A near-silent selected microphone is
    /// probed against the other connected microphones; the first one with signal takes over for the rest of
    /// the recording and is remembered for later recordings. Nothing changes when no other mic is audible.
    private func startupSilenceCheck(peak: Float) {
        guard isCapturing, !failedOverThisRecording, MicrophoneFailover.isSilent(peak: peak) else { return }
        let current = boundInputDeviceID ?? 0
        let candidates = Array(MicrophoneFailover.candidates(current: current, inputs: MicrophonePreference.inputs()).prefix(3))
        guard !candidates.isEmpty else {
            vlog("[VOICE-AC] startup silence on \(activeMicrophoneName ?? "mic"), no other microphone connected")
            return
        }
        failedOverThisRecording = true
        vlog("[VOICE-AC] startup silence (peak \(peak)) on \(activeMicrophoneName ?? "mic") — probing \(candidates.count) other mic(s)")
        Task.detached(priority: .userInitiated) { [weak self] in
            var probes: [(input: MicrophonePreference.Input, peak: Float)] = []
            for candidate in candidates {
                let probe = MicrophoneFailover.probePeak(candidate)
                probes.append((candidate, probe))
                if !MicrophoneFailover.isSilent(peak: probe) { break }
            }
            let found = MicrophoneFailover.firstAudibleCandidate(probes)
            await MainActor.run { [weak self] in
                guard let self, let found, self.isCapturing else {
                    vlog("[VOICE-AC] failover: no other microphone showed signal — keeping the selected one")
                    return
                }
                self.switchInput(to: found)
            }
        }
    }

    /// Rebinds the running recording to another input device, then rebuilds the tap exactly as a route change does.
    private func switchInput(to input: MicrophonePreference.Input) {
        guard let engine = audioEngine, let unit = engine.inputNode.audioUnit else { return }
        engine.stop()
        var device = input.deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            vlog("[VOICE-AC] failover: could not bind \(input.name) (status \(status)) — keeping the selected one")
            handleConfigurationChange(force: true)
            return
        }
        boundInputDeviceID = input.deviceID
        activeMicrophoneName = input.name
        microphoneStatus = "Using \(input.name) (the selected microphone was silent)."
        MicrophoneFailover.remember(uid: input.uid)
        vlog("[VOICE-AC] failover: switched to \(input.name) for the rest of this recording and remembered it")
        Telemetry.log("audio.failover", properties: ["to_class": rankLabel(input)])
        handleConfigurationChange(force: true)
    }

    private func rankLabel(_ input: MicrophonePreference.Input) -> String {
        input.isPhysicalExternal ? "external" : (input.transport == kAudioDeviceTransportTypeBuiltIn ? "builtIn" : "other")
    }

    /// True once the engine has delivered its first buffer for this recording. The start cue waits for it.
    var hasCapturedBuffer: Bool {
        probeLock.lock(); defer { probeLock.unlock() }
        return capturedBuffers > 0
    }

    /// Wispr sends the mean of the slices received in each 150 ms window, and nothing
    /// when none arrived. Stops itself once capture ends.
    private func enqueueBarLevels(_ levels: [Float]) {
        pendingBarLevels.append(contentsOf: levels)
        guard barLevelTimer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if !self.isCapturing { self.barLevel = 0; self.pendingBarLevels = []; timer.invalidate(); self.barLevelTimer = nil; return }
            guard !self.pendingBarLevels.isEmpty else { return }
            self.barLevel = self.pendingBarLevels.reduce(0, +) / Float(self.pendingBarLevels.count)
            self.pendingBarLevels = []
        }
        RunLoop.main.add(timer, forMode: .common)
        barLevelTimer = timer
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // TWEAK: Resample input to 16kHz mono Float32 (Whisper format)
        let resampled = resample(buffer) ?? buffer
        guard let channelData = resampled.floatChannelData?[0] else { return }
        let frameCount = Int(resampled.frameLength)
        guard frameCount > 0 else { return }

        // ====================================================================
        // DSP CHAIN (operates in-place on the resampled buffer so the on-disk
        // file, the live transcription samples, and the visualizer all see
        // the exact same processed signal):
        //   1. High-pass filter (DC removal + sub-80Hz rumble cut)
        //   2. Pre-emphasis (consonant boost for Parakeet)
        //   3. Adaptive gain — boosts whispers, leaves normal speech alone
        //   4. Soft-knee look-ahead limiter — catches screams / "P" pops
        // All four stages are sample-by-sample one-pole / IIR — vectorizable
        // but cheap enough at 16kHz mono (~16k mul/adds per second per stage)
        // that the loop form is fine and keeps the limiter envelope tight.
        // ====================================================================
        // Bar level from the raw microphone, in 40 ms slices like Wispr's packets.
        var sliceLevels: [Float] = []
        let slice = 640
        var start = 0
        while start < frameCount {
            let count = min(slice, frameCount - start)
            var sliceRMS: Float = 0
            vDSP_rmsqv(channelData + start, 1, &sliceRMS, vDSP_Length(count))
            let db = 20 * log10(max(sliceRMS, 1e-7))
            if db < barLevelFloorDb { barLevelFloorDb = max(-60, db) }
            sliceLevels.append(max(0, min(1, (db - barLevelFloorDb) / 20)))
            start += count
        }
        DispatchQueue.main.async { [weak self] in self?.enqueueBarLevels(sliceLevels) }

        // Shared chain (CaptureDSP.swift): first-buffer RMS bootstrap, HPF,
        // pre-emphasis, adaptive gain, limiter, then the smoothed-RMS update
        // for the next buffer. Returns this buffer's post-DSP RMS.
        let rms = dsp.process(channelData, frameCount: frameCount)

        // 1. Peak for level metering & diagnostics (RMS comes from the chain).
        var peak: Float = 0
        vDSP_maxmgv(channelData, 1, &peak, vDSP_Length(frameCount))

        // Speech-presence (VAD) accumulation. This is the AUDIO-based signal
        // the finalize path uses to suppress Whisper-family hallucinations on
        // silent/non-speech captures. A buffer counts as "voiced" when its
        // post-DSP RMS clears speechFloorRMS; we add that buffer's wall-clock
        // duration to the running total. Tracked on the audio thread only.
        if rms > recordingPeakRMS { recordingPeakRMS = rms }
        let bufferSeconds = Double(frameCount) / sampleRate
        capturedDurationSec += bufferSeconds
        if rms >= speechFloorRMS { voicedDurationSec += bufferSeconds }
        if rms >= CaptureDSP.quietSpeechFloorRMS { quietVoicedDurationSec += bufferSeconds }

        probeLock.lock()
        capturedBuffers += 1
        probeLock.unlock()
        if capturedDurationSec - bufferSeconds < MicrophoneFailover.probeSeconds {
            startupPeak = max(startupPeak, peak)
        }
        if !startupCheckScheduled, capturedDurationSec >= MicrophoneFailover.probeSeconds {
            startupCheckScheduled = true
            let windowPeak = startupPeak
            DispatchQueue.main.async { [weak self] in self?.startupSilenceCheck(peak: windowPeak) }
        }

        // Per-second peak diagnostic — surfaces silent-capture failures
        // (mic muted, wrong device, kernel HAL wedged) within 1s.
        self.peakSampleThisSecond = max(self.peakSampleThisSecond, peak)
        if Date().timeIntervalSince(self.lastPeakLogAt) > 1.0 {
            vlog("[VOICE-AC] Audio peak last 1s: \(self.peakSampleThisSecond)")
            if self.peakSampleThisSecond < 0.001 {
                vlog("[VOICE-AC] WARNING: capturing near-silence — mic may be muted or routed wrong")
            }
            self.peakSampleThisSecond = 0
            self.lastPeakLogAt = Date()
        }
        // (The smoothed-RMS update for the next buffer's gain decision now
        // happens at the end of dsp.process; nothing in between reads it.)

        // Periodic DSP diagnostics (every ~40 buffers ≈ 10s) so we can see
        // whether AGC kicked in, whether the limiter fired, and what range we're in.
        self.buffersSinceDSPLog += 1
        if self.buffersSinceDSPLog >= 40 {
            self.buffersSinceDSPLog = 0
            let rmsDb = 20 * log10(max(rms, 1e-7))
            let peakDb = 20 * log10(max(peak, 1e-7))
            let regime: String
            if rms < 0.005      { regime = "whisper" }
            else if rms < 0.05  { regime = "quiet"   }
            else if rms < 0.2   { regime = "normal"  }
            else                { regime = "LOUD"    }
            vlog(String(format: "[VOICE-AC] DSP rms=%.2fdB peak=%.2fdB gain=%.2fx regime=%@ device=%@",
                         rmsDb, peakDb, self.dsp.adaptiveGain, regime, self.inputClass.rawValue))
        }

        // 2. The meter uses the full-buffer RMS from the processed samples.
        // Reading pre-DSP RMS would leave the bars flat on quiet input.
        if !loggedPostDSPVisualizer && rms >= silenceFloorRMS {
            loggedPostDSPVisualizer = true
            vlog("[VOICE-AC] visualizer using post-DSP samples")
        }
        let newLevels = computeVisualizerLevels(overallRMS: rms, isRecording: isCapturing)

        // Perceptual level for the UI meter. RMS of typical speech sits in
        // ~0.02-0.15; a sqrt + scale lifts that to ~0.2-0.85 so the bars
        // actually move. We apply a minimum visible floor while recording is
        // active (0.02) so the waveform shows a faint pulse even on genuine
        // room-silence — prevents the pill from looking "dead / not recording".
        // When not recording (idle state) we return 0 so the waveform rests cleanly.
        let perceptual: Float
        if rms < silenceFloorRMS {
            perceptual = isCapturing ? 0.02 : 0.0
        } else {
            perceptual = max(isCapturing ? 0.02 : 0.0, min(1.0, sqrtf(rms) * 2.4))
        }

        // Update @Observable properties on main thread to avoid data races.
        DispatchQueue.main.async { [weak self] in
            self?.currentRMS = rms
            self?.currentPeak = peak
            self?.currentInputLevel = perceptual
            self?.audioLevels = newLevels
        }

        // 2b. Deliver resampled PCM buffer to the live partials subscriber.
        onPCMBuffer?(resampled)

        // 3. Passthrough write to disk when retaining audio.
        // We write the SAME `resampled` buffer the streaming engine sees so
        // the on-disk file is byte-faithful to what got transcribed live.
        // Errors here are swallowed — a write failure mid-meeting must not
        // kill the recording. The lock is uncontended in steady state.
        writerLock.lock()
        if let writer = audioFileWriter {
            do {
                try writer.write(from: resampled)
                // Each frame is 1 channel * 4 bytes. Approx — exact size on
                // disk depends on the .caf header but this is fine for a
                // heartbeat sanity check.
                audioFileBytesWritten &+= Int64(frameCount) * 4
                framesSinceLastProgressLog += frameCount
                // Progress heartbeat ~every 10s of audio (16k * 10 = 160k frames).
                if framesSinceLastProgressLog >= 160_000 {
                    let durationSeconds = Double(audioFileBytesWritten / 4) / sampleRate
                    vlog("[VOICE] audio file progress: bytes=\(audioFileBytesWritten) (~\(Int(durationSeconds))s)")
                    framesSinceLastProgressLog = 0
                }
            } catch {
                vlog("[VOICE] audio file write failed: \(error.localizedDescription) — attempting reopen")
                // Failure recovery: drop the broken handle, open a new
                // `-partN` file next to the original, and try once more.
                // Stitching across parts is handled in post-processing.
                if let originalURL = audioFileURL, let settings = audioFileSettings {
                    audioFileWriter = nil
                    // Bail out if we've already hit the part cap — runaway
                    // reopens mean the disk/permissions aren't going to
                    // recover, so stop capturing and tell the user.
                    if audioFilePartURLs.count >= maxAudioFileParts {
                        vlog("[VOICE] audio file reopen aborted: hit maxAudioFileParts=\(maxAudioFileParts)")
                        writerLock.unlock()
                        stopCapture()
                        NotificationCenter.default.post(
                            name: .voiceError,
                            object: nil,
                            userInfo: ["flowKind": "microphone", "message": "Audio write keeps failing — recording stopped"]
                        )
                        return
                    }
                    audioFilePartIndex += 1
                    let partURL = originalURL
                        .deletingPathExtension()
                        .appendingPathExtension("part\(audioFilePartIndex)")
                        .appendingPathExtension(originalURL.pathExtension)
                    do {
                        let newFile = try AVAudioFile(
                            forWriting: partURL,
                            settings: settings,
                            commonFormat: .pcmFormatFloat32,
                            interleaved: false
                        )
                        try newFile.write(from: resampled)
                        audioFileWriter = newFile
                        audioFilePartURLs.append(partURL)
                        audioFileBytesWritten &+= Int64(frameCount) * 4
                        vlog("[VOICE] audio file reopened at \(partURL.lastPathComponent)")
                    } catch {
                        vlog("[VOICE] audio file reopen failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        writerLock.unlock()

        // Long-running engine sanity check: emit a single warning once
        // we cross 2h on the same AVAudioEngine instance so we can spot
        // potential resource accumulation in the logs. The 4-hour cap in
        // MeetingRecorder still enforces the hard stop.
        if let startedAt = engineStartedAt,
           !engineLongRunningWarningEmitted,
           Date().timeIntervalSince(startedAt) > 2 * 60 * 60 {
            engineLongRunningWarningEmitted = true
            vlog("[VOICE] WARNING: AVAudioEngine has been running >2h — long-recording territory")
        }

    }

    /// Average every channel of a float buffer into one (nil when it is already mono or not float).
    static func monoMix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        guard channels > 1, let src = buffer.floatChannelData,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let n = Int(buffer.frameLength), dst = out.floatChannelData![0]
        var scale = 1 / Float(channels)
        vDSP_vsmul(src[0], 1, &scale, dst, 1, vDSP_Length(n))
        for c in 1..<channels { vDSP_vsma(src[c], 1, &scale, dst, 1, dst, 1, vDSP_Length(n)) }
        return out
    }

    /// Resample input buffer (any format/rate) to 16kHz mono Float32.
    /// Returns nil if no converter is set up (e.g. system audio path).
    private func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = audioConverter, let target = targetFormat else {
            return nil
        }
        let buffer = Self.monoMix(buffer) ?? buffer

        // Calculate output capacity based on sample rate ratio
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            return nil
        }

        var error: NSError?
        var inputProvided = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputProvided = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            return nil
        }
        return outputBuffer
    }

    /// I/O-thread-private prior bin values used as the smoothing basis. Owning this
    /// array on the I/O thread (rather than reading the @Observable audioLevels
    /// across threads) eliminates a torn-read data race that produced waveform
    /// glitches and the occasional crash on stop. Only mutated inside
    /// computeVisualizerLevels and reset by resetVisualizerSmoothing on stop.
    private var visualizerPriorBins: [Float] = []
    /// Pre-computed deterministic per-bin variation multipliers (0.65…1.35).
    /// Built once on first use; reused across all `computeVisualizerLevels`
    /// calls. Eliminates a per-buffer `sinf(phase)` loop and a per-buffer
    /// `[Float](repeating:count:)` allocation for `rawLevels`.
    private var visualizerVariation: [Float] = []
    /// Scratch buffer for the EMA-smoothed result returned to the UI. Same
    /// length as fftBinCount; reused across calls.
    private var visualizerResultScratch: [Float] = []

    /// Reset the I/O-thread smoothing buffer. Call from the same thread that
    /// owns the audio tap (I/O) or before installing the tap.
    fileprivate func resetVisualizerSmoothing() {
        visualizerPriorBins = Array(repeating: 0, count: fftBinCount)
    }

    /// Compute visualizer bar levels from the full, post-DSP buffer's RMS.
    ///
    /// The previous implementation sliced the time-domain buffer into 32 equal
    /// frequency bands and computed per-band RMS. This is NOT a spectrum —
    /// it's just slicing the waveform in time. Nearly all speech energy sits in
    /// the first few bands while the rest are near zero, so most bars were dead.
    /// Multiplying by 8.0 was also far too low: conversational speech produces
    /// RMS ≈ 0.01–0.08 → band RMS ≈ 0.001–0.01 → * 8 = 0.008–0.08, which
    /// after pow(x, 0.55) in WaveformView is still below the 0.06 floor.
    ///
    /// New approach:
    ///   1. Reuse the DSP chain's overall RMS for the buffer.
    ///   2. Scale to 0..1 with a multiplier tuned so conversational speech
    ///      (RMS ~0.03) maps to ~0.5 and whispers (~0.005) map to ~0.10.
    ///   3. Spread to all 32 bins with per-bin seeded variation (±35%) so the
    ///      waveform has organic shape rather than a single uniform bar height.
    ///   4. Apply EMA smoothing per bin (smoothing=0.3) for continuity.
    ///
    /// The WaveformView.level(for:) mirror mapping and gamma curve are unchanged.
    private func computeVisualizerLevels(overallRMS: Float,
                                         isRecording: Bool) -> [Float] {
        if visualizerPriorBins.count != fftBinCount {
            visualizerPriorBins = Array(repeating: 0, count: fftBinCount)
        }
        // Scale so conversational speech (RMS ~0.03) → ~0.5.
        // Whispers (~0.005) → ~0.08; yelling (~0.15) → ~1.0 (clamped).
        // TWEAK: increase this multiplier if bars still look too quiet.
        var scaled = min(1.0, overallRMS * 18.0)

        // Recording-state breathing pulse: when the user is actively recording
        // but the room is genuinely silent, the pill would otherwise sit at the
        // 6% floor and look completely dead — easy to mistake for "not
        // recording." We mix in a slow, deterministic sine (~0.4 Hz, ±0.065
        // amplitude) so the visualizer breathes gently. Deterministic (timer-
        // driven, not random) so the motion looks like a heartbeat, not noise.
        // Only applied while recording; when idle, the View's `idleBlob`
        // handles the idle visual state and we return clean zeros.
        if isRecording && scaled < 0.04 {
            let t = Date().timeIntervalSinceReferenceDate * 0.4 * 2.0 * .pi
            let pulseAmplitude: Float = 0.065  // mid of 0.05…0.08 range
            let pulse = pulseAmplitude * Float(sin(t))
            // Bias to positive so we always add some life — pulse oscillates
            // 0..2*amp around the floor rather than ±amp around zero.
            scaled = min(1.0, scaled + (pulse + pulseAmplitude))
        }

        // Per-bin variation: cached on first use. Multipliers are deterministic
        // (sinf of golden-ratio-spaced phases) so we compute them exactly once
        // per process and reuse the array for every buffer. Previously this
        // ran fftBinCount sinf() calls + a 32-float allocation EVERY audio
        // buffer (~4-12 Hz). Now: zero per-buffer work for the variation.
        if visualizerVariation.count != fftBinCount {
            var v = [Float](repeating: 0, count: fftBinCount)
            for i in 0..<fftBinCount {
                let phase = Float(i) * 1.618034
                v[i] = 1.0 + 0.35 * sinf(phase)
            }
            visualizerVariation = v
        }
        if visualizerResultScratch.count != fftBinCount {
            visualizerResultScratch = [Float](repeating: 0, count: fftBinCount)
        }

        // EMA smoothing: 0.3 = ~3-frame attack at 30Hz → fast but not jumpy.
        // Fused into the variation pass so we only walk the bins once and
        // never allocate per call:
        //   result[i] = prior[i]*smoothing + (scaled * variation[i])*(1-smoothing)
        let smoothing: Float = 0.3
        let oneMinusSmoothing: Float = 1.0 - smoothing
        for i in 0..<fftBinCount {
            let raw = min(1.0, scaled * visualizerVariation[i])
            visualizerResultScratch[i] = visualizerPriorBins[i] * smoothing + raw * oneMinusSmoothing
            visualizerPriorBins[i] = visualizerResultScratch[i]
        }
        return visualizerResultScratch
    }
}

// MARK: - SCStream Audio Handler
// Bridges ScreenCaptureKit's CMSampleBuffer output to AVAudioPCMBuffer.

private class AudioStreamHandler: NSObject, SCStreamOutput {
    let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let formatDesc = sampleBuffer.formatDescription else { return }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        // Copy sample data
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)

        if let data = dataPointer, let channelData = pcmBuffer.floatChannelData {
            memcpy(channelData[0], data, length)
        }

        onBuffer(pcmBuffer)
    }
}
