// VOICE — Meeting Capture Service
// ============================================================
// Captures system audio (browser tabs, Google Meet, etc.) via
// ScreenCaptureKit and mixes it with the local microphone, then
// routes 30-second chunks through the existing Parakeet TDT
// transcription engine to build a live multi-speaker transcript.
//
// Architecture:
//   - ScreenCaptureKit SCStream: system audio at 16kHz mono
//   - AVAudioEngine: mic audio at 16kHz mono
//   - Additive mix → clamp(-1, 1) → [Float] accumulator
//   - Every 480,000 samples (~30s): dispatch to TranscriptionService
//   - Results appended to `liveTranscript`
//
// Speaker label: "MEETING" (single mixed stream — no diarization yet)
//
// Usage:
//   let svc = MeetingCaptureService(transcriptionEngine: sharedTS)
//   try await svc.startCapture()
//   // ... meeting ...
//   let segments = await svc.stopCapture()
// ============================================================

import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit
import os
import FluidAudio
import CoreAudio
import AudioToolbox
import CoreMedia

// MARK: - MeetingCaptureError

enum MeetingCaptureError: LocalizedError {
    case permissionDenied
    case engineNotReady
    case streamSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission denied. Grant it in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .engineNotReady:
            return "Transcription engine not ready. Call prepare() on TranscriptionService first."
        case .streamSetupFailed(let msg):
            return "ScreenCaptureKit stream setup failed: \(msg)"
        }
    }
}

// MARK: - MeetingCaptureService

@Observable
final class MeetingCaptureService: NSObject {

    // MARK: - Public state

    /// True while audio capture is active.
    var isCapturing: Bool = false

    /// Live elapsed seconds since startCapture() was called.
    var durationSeconds: Int = 0

    /// Accumulates transcript segments as 30-second chunks are transcribed.
    var liveTranscript: [TranscriptSegment] = []
    /// Live captions are best effort. The complete recording is saved separately.
    var liveTranscriptStatus: String = "Preparing captions"
    private var liveGeneration = UUID()
    private var liveWorker: MeetingLiveWorker?
    private var liveWorkerLoading = false
    private var liveBusy = false
    private var liveTask: Task<Void, Never>?

    /// Bundle ID of the app that triggered this capture session. Set by the
    /// caller before startCapture(). Reset to nil after stopCapture().
    var sourceApp: String? = nil

    /// Participant names scraped from the call platform's DOM by the Chrome
    /// extension. Same pattern as `sourceApp`: the caller populates this
    /// before `startCapture()` and reads it back via the `stopCapture()`
    /// tuple. Reset to `[]` after stopCapture().
    var participantNames: [String] = []

    // MARK: - On-disk audio persistence
    //
    // We stream-write the mixed 16kHz mono Float32 signal to a WAV file as
    // samples arrive. Writes hop to a dedicated background queue so the audio
    // tap thread is never blocked by file I/O. Failures are logged with the
    // `[AUDIO-PERSIST]` tag and tear down the writer; the rest of the capture
    // (live transcription) continues uninterrupted.
    private var audioFileWriter: AVAudioFile?
    // Internal access (was private) so the live-draft checkpoint timer in
    // VoiceApp can capture the in-progress WAV path even before stopCapture.
    private(set) var audioFileURL: URL?
    private let audioFileFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private let audioWriteQueue = DispatchQueue(label: "voice.meeting.audiowrite", qos: .utility)
    private let audioWriterLock = NSLock()
    // Includes the block currently writing. Bound both retained PCM and queue
    // metadata if the filesystem stalls; two MiB is about 32 s at 16 kHz mono.
    private let audioWriteByteLimit = 2 * 1024 * 1024
    private let audioWriteBlockLimit = 256
    private var audioWriterGeneration = UUID()
    private var audioWritePendingBytes = 0
    private var audioWritePendingBlocks = 0
    private var audioWriterAcceptingSamples = false
    private var audioWriterStopRequested = false

    // MARK: - Private constants

    // All mixer state and processing live on this queue. The timer leaves one
    // second for callbacks from the two independent capture paths to arrive.
    private let timelineQueue = DispatchQueue(label: "voice.meeting.timeline", qos: .userInitiated)
    private var timeline: MeetingAudioTimelineMixer?
    private var timelineSession = UUID()
    private var timelineStream: SCStream?
    private var timelineTimer: DispatchSourceTimer?
    private var timelineWarned = false
    private let timelineLateness: Double = 1.0

    private let sampleRate: Double = 16_000
    private let chunkSamples: Int  = 240_000   // 15 s × 16 000 Hz

    // MARK: - Dependencies

    private let transcriptionEngine: TranscriptionService

    // MARK: - ScreenCaptureKit handles

    private var scStream: SCStream?

    // MARK: - Mic capture (AVAudioEngine)

    private let audioEngine = AVAudioEngine()

    // MARK: - Sample accumulator & synchronisation

    /// Mixed samples accumulated until the next 30-second chunk fires.
    private var accumulator: [Float] = []
    private var accumulatorLock = NSLock()

    /// Absolute sample-count of the session start (used to compute chunkStartTime).
    private var totalSamplesProcessed: Int = 0


    // MARK: - Timer for durationSeconds

    private var durationTimer: Task<Void, Never>?

    // MARK: - Watchdog + verbose-status + restart state (Phase: stop-detection fixes)
    //
    // Added to chase the "36-minute meeting → 1.7-minute WAV" bug where SCStream
    // + mic capture silently dies after ~100s. None of these replace existing
    // behavior — they augment it.

    /// 1-second ticker that watches `totalSamplesProcessed + accumulator.count`
    /// and posts a stall notification + tries to restart the engine + SCStream
    /// if no growth for 5s. Cancelled in stopCapture().
    private var watchdogTask: Task<Void, Never>?

    /// 30-second verbose-status logger. Logs sample count, sample rate, writer
    /// state, stream state. Cancelled in stopCapture().
    private var statusLogTask: Task<Void, Never>?

    /// Wall-clock timestamp of the last time we saw a non-zero sample arrival.
    /// Used by the watchdog to decide if audio has stalled.
    private var lastSampleArrivalAt: Date = Date()
    private let lastSampleArrivalLock = NSLock()

    /// Counter snapshot used by the watchdog to detect "no growth in 5s".
    /// (totalSamplesProcessed + accumulator.count) at the moment the watchdog
    /// last sampled it.
    private var lastWatchdogSampleCount: Int = 0

    /// Mic-health counters. Lifetime sample counts since capture start, used
    /// by the 10s health log to verify mic + sys are both flowing. If
    /// `micSampleCount` stops growing while `sysSampleCount` keeps growing,
    /// the user's own voice is missing from the recording — we log loudly.
    ///
    /// Both counters are mutated with `&+=` from two real-time threads (the
    /// AVAudioEngine input-tap callback and the SCStream sample-buffer delegate)
    /// and read concurrently from the MainActor mic-health Task and the
    /// watchdog. Guard them with a dedicated `OSAllocatedUnfairLock` wrapping a
    /// tiny `SampleCounters` struct so increments and snapshot-reads are atomic
    /// without ever touching `accumulatorLock` (which is held for longer
    /// accumulator work and would stall the audio thread). Critical sections are
    /// minimal — never held across an `await` or any audio processing.
    private struct SampleCounters {
        var mic: UInt64 = 0
        var sys: UInt64 = 0
    }
    private let sampleCounters = OSAllocatedUnfairLock(initialState: SampleCounters())
    private var lastMicHealthSnapshotMic: UInt64 = 0
    private var lastMicHealthSnapshotSys: UInt64 = 0
    private var micHealthTask: Task<Void, Never>?

    /// True if a `didStopWithError` came in and we should attempt one restart.
    /// Reset when stopCapture() runs or when the restart succeeds.
    private var hasAttemptedStreamRestart: Bool = false

    /// True if the watchdog has fired a restart this session. Prevents repeated
    /// restart storms — we attempt once per stall window.
    private var hasAttemptedWatchdogRestart: Bool = false

    /// Tracks the last few writer-failure timestamps. The writer is only fully
    /// disabled after 3 failures within 10 seconds.
    private var writerFailureTimestamps: [Date] = []
    private let writerFailureLock = NSLock()

    /// True once we've registered for AVAudioEngine.configurationChangeNotification.
    /// We only register once per service instance.
    private var configChangeObserver: NSObjectProtocol?

    /// True if the last sample arrival included system audio. The watchdog logs
    /// this so we can tell from the logs which source has stopped.
    private var lastSampleWasSystem: Bool = false
    private var lastSampleWasMic: Bool = false

    /// Last filter we used to start the SCStream. Held so a restart can reuse it
    /// without re-querying SCShareableContent on the audio thread.
    private var lastSCFilter: SCContentFilter?
    private var lastSCConfig: SCStreamConfiguration?

    // MARK: - Audio polish DSP state
    //
    // Lightweight DSP applied to the mic path before the mix:
    //   1. 1-pole high-pass filter @ 80Hz to kill AC hum + room rumble
    //   2. Peak-follower compressor (threshold 0.5, ratio 3:1, makeup 1.0)
    //   3. Soft-clip via tanh on the mixed output
    //   4. Optional sys-audio ducking when the user is speaking
    //
    // All gated by `voice.meetingAudioPolish` UserDefaults (default true). The
    // filter coefficient + cached gate are computed once on capture-start and
    // updated each chunk; the rest is per-sample state. Touched only from the
    // mic tap thread + the SCStream sample-handler thread (which interleave
    // through `appendMixedSamples`), so no lock is needed beyond the audio
    // serialization the framework already gives us — `appendMixedSamples` is
    // not re-entrant from a single source, and mic/sys updates only collide
    // in the mix step, which uses local stack values.

    /// True if `voice.meetingAudioPolish` is enabled. Cached on capture-start
    /// + every appendMixedSamples call (UserDefaults read is cheap but a
    /// branch on a stored Bool is cheaper still).
    private var audioPolishEnabled: Bool = true

    /// HPF state — previous input and previous output sample. 1-pole HPF:
    ///   y[n] = a * (y[n-1] + x[n] - x[n-1])
    /// where a = RC / (RC + dt), RC = 1 / (2π * fc). For fc=80Hz at 16kHz:
    ///   RC ≈ 1.989e-3, dt = 6.25e-5, a ≈ 0.9695
    private var hpfPrevIn: Float = 0
    private var hpfPrevOut: Float = 0
    private let hpfCoefficient: Float = 0.9695  // 80Hz @ 16kHz

    /// Compressor peak-follower state. Exponentially smoothed peak estimate
    /// across mic samples; recovers slowly so a single loud syllable doesn't
    /// pump quieter speech right after it.
    private var compressorPeak: Float = 0
    /// Smoothing coefficient — how fast the peak follower reacts. Higher =
    /// more responsive (more pumping); lower = smoother (slower to catch
    /// transients). 0.05 gives ~20-sample (1.25ms @ 16kHz) effective window.
    private let compressorAlpha: Float = 0.05

    // MARK: - Active-speaker timeline (Chrome extension → labelled segments)
    //
    // The "Voice Meet Bridge" extension posts /speaker events whenever Google
    // Meet's visual active-speaker indicator changes. We append them to a
    // bounded timeline here, then in transcribeChunk() look up the speaker
    // whose `active=true` event was most recent at or before the midpoint of
    // each segment. If we find a match (and they hadn't stopped talking yet),
    // we replace the segment's "MEETING" speaker label with their name.

    struct SpeakerEvent: Codable {
        let name: String
        let t: Date
        let active: Bool
    }

    private(set) var speakerTimeline: [SpeakerEvent] = []
    private let speakerLock = NSLock()
    private let speakerTimelineMaxCount = 5000

    /// Wall-clock moment startCapture() returned successfully. Used to convert
    /// per-segment relative offsets into absolute timestamps that can be
    /// looked up in `speakerTimeline`. nil while not capturing.
    private(set) var captureStartedAt: Date? = nil

    /// Guards re-entry of the restart helpers.
    private let restartLock = NSLock()

    // MARK: - Audio-based diarization (FluidAudio)
    //
    // Independent of the Chrome-extension speaker timeline. Runs the WeSpeaker
    // pipeline on each chunk so we can label segments even when the DOM hook
    // can't (Zoom, FaceTime, in-person, or just the extension being broken).
    //
    // The diarizer's internal SpeakerManager keeps speaker identity stable
    // across chunks, so a 30-minute Zoom call ends up with 2-4 stable voice
    // IDs rather than fresh IDs per chunk.
    //
    // Failure is silent — if the diarizer can't load models or processes a
    // chunk badly, we just don't apply voice-ID labels for that chunk and
    // fall back to the existing "MEETING" / extension-name path.

    private var diarizer: SpeakerDiarizer? = nil

    // MARK: - Init

    init(transcriptionEngine: TranscriptionService) {
        self.transcriptionEngine = transcriptionEngine
        super.init()
        accumulator.reserveCapacity(chunkSamples * 2)
    }

    /// Retry on a later audio chunk if the dictation model was still loading
    /// when the meeting began. Missed captions remain in the recorded WAV.
    private func prepareLiveWorkerIfReady(generation: UUID) {
        guard liveWorker == nil, !liveWorkerLoading else { return }
        guard let models = transcriptionEngine.asrModels else {
            liveTranscriptStatus = "Waiting for captions. Recording is saved."
            return
        }
        liveWorkerLoading = true
        Task { [weak self] in
            do {
                let worker = try await MeetingLiveWorker(models: models)
                await MainActor.run {
                    guard let self, self.liveGeneration == generation else { return }
                    self.liveWorkerLoading = false
                    guard self.isCapturing else { return }
                    self.liveWorker = worker
                    self.liveTranscriptStatus = "Live captions update every 15 seconds"
                }
            } catch {
                await MainActor.run {
                    guard let self, self.liveGeneration == generation else { return }
                    self.liveWorkerLoading = false
                    self.liveTranscriptStatus = "Captions unavailable. Recording is saved."
                }
            }
        }
    }

    /// Safety-net teardown. `stopCapture()` is the normal path and already tears
    /// down all of these, but if the service is deallocated without a
    /// `stopCapture()` call, the block-based NotificationCenter observer would be
    /// stranded and the background tasks/timer left running. Mirror the relevant
    /// teardown from `stopCapture()` here — synchronous only. We deliberately do
    /// NOT invoke any MainActor-isolated async work from `deinit`; we just remove
    /// the observer token and cancel the tasks.
    deinit {
        if let token = configChangeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        micHealthTask?.cancel()
        durationTimer?.cancel()
        watchdogTask?.cancel()
        statusLogTask?.cancel()
    }

    // MARK: - Permission

    /// Returns true if the app has (or just gained) Screen Recording permission.
    /// Internally calls SCShareableContent to trigger the TCC prompt if needed.
    ///
    /// LAZY BY CONTRACT: this is the only place (besides `startCapture`) that
    /// touches ScreenCaptureKit, and it must ONLY be invoked from the explicit,
    /// user-initiated meeting-capture start path (VoiceApp.startMeetingCapture).
    /// Never call it eagerly at launch, from idle timers, or from auto-detection
    /// — doing so lights the macOS screen-recording indicator with no recording
    /// in progress.
    static func requestPermission() async -> Bool {
        do {
            // This call prompts the user for Screen Recording permission if not
            // already granted. Throws SCStreamError / NSError if denied.
            _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            return true
        } catch {
            print("[MeetingCapture] Permission check failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Start / Stop

    /// Start capturing system audio + microphone.
    /// Throws MeetingCaptureError.permissionDenied if ScreenCaptureKit access is denied.
    /// Bundle IDs of apps for which it is legitimate to start a meeting
    /// capture. Used by the defensive guard in `startCapture()` so that a
    /// runaway caller can never start an SCStream when no meeting app is
    /// actually frontmost. Mirrors CallAppDetector.knownCallApps plus
    /// browser bundles (which host Google Meet / Zoom-web / Teams-web).
    /// Bundles that may pass the whitelist purely from being frontmost.
    /// These are dedicated call apps where "frontmost + mic in use" is a
    /// strong-enough signal that the user is on a call (CallAppDetector
    /// already requires both before firing).
    private static let legitimateMeetingBundles: Set<String> = [
        "com.hnc.Discord",
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.apple.FaceTime",
        "desktop.WhatsApp",
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
    ]

    /// Bundles that are routinely frontmost without a call being active —
    /// Slack (typing/reading) and browsers (any tab). These must NEVER pass
    /// the whitelist just from being frontmost. They are only legitimate
    /// when the caller supplies a `sourceApp` proving the capture was
    /// triggered by a real signal — MeetBridge (browser-based Meet/Zoom-web/
    /// Teams-web), or an explicit Slack-call-app event. We accept them via
    /// the `sourceApp` path only.
    private static let proofRequiredMeetingBundles: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
    ]

    func startCapture(manual: Bool = false) async throws {
        if isCapturing {
            print("[VOICE-MEET] startCapture refused — already capturing")
            return
        }

        // ----- Defensive guard against false-positive meeting captures -----
        // The orange screen-recording indicator lights up the moment we call
        // SCStream.startCapture(), so we MUST refuse to start unless a real
        // meeting app is currently frontmost. Without this, a stale caller
        // (e.g. a notification posted after the user already left the call,
        // or a background Discord ping that fooled the detector) could turn
        // the indicator on while the user is just dictating.
        //
        // The kill switch wins over everything: if the user has explicitly
        // disabled meeting auto-detection, refuse all auto-started captures.
        // (Manual taps from the UI run through this same path; the UI is
        // expected to gate itself on the same key.)
        let disabled = UserDefaults.standard.bool(forKey: "voice.disableMeetingDetection")
        if disabled && !manual {
            print("[VOICE-MEET] startCapture refused — voice.disableMeetingDetection is true")
            throw MeetingCaptureError.streamSetupFailed("Meeting detection disabled by user")
        }
        // Belt-and-suspenders: also require the meeting-detection gate to
        // permit this capture. We mirror `BackgroundActivityGate.meetingDetectionEnabled`
        // EXACTLY here (rather than reading a single key) so the service
        // backstop never disagrees with the app-level gate.
        //
        // Logic (same as BackgroundActivityGate.meetingDetectionEnabled):
        //   - privacyMode wins → refuse
        //   - explicit `voice.enableMeetingDetection = false` → refuse
        //   - unset → DEFAULT ON (meeting recording is core product behavior)
        //   - explicit `voice.enableMeetingDetection = true` → allow
        // The orange screen-recording indicator turns on the instant we call
        // SCStream.startCapture, so guard one more time here.
        let privacyMode = UserDefaults.standard.bool(forKey: "voice.privacyMode")
        let enableOptInSet = UserDefaults.standard.object(forKey: "voice.enableMeetingDetection") != nil
        let enableOptIn = enableOptInSet
            ? UserDefaults.standard.bool(forKey: "voice.enableMeetingDetection")
            : false  // explicit opt-in, matching BackgroundActivityGate
        if !manual && (privacyMode || !enableOptIn) {
            print("[VOICE-MEET] startCapture refused — enableMeetingDetection=\(enableOptIn) (explicit=\(enableOptInSet)) privacyMode=\(privacyMode)")
            throw MeetingCaptureError.streamSetupFailed("Meeting detection opt-in required")
        }

        let frontmostBundle = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        // Frontmost alone is a sufficient signal ONLY for dedicated call
        // apps (Discord/Zoom/Teams/FaceTime/WhatsApp/Telegram). Slack and
        // browsers are routinely frontmost without a call — they require
        // explicit proof via `sourceApp` (MeetBridge or Slack-call-app event).
        let frontmostIsMeeting = frontmostBundle.map {
            Self.legitimateMeetingBundles.contains($0)
        } ?? false
        // `sourceApp` accepts BOTH tiers: a caller can pass a dedicated call-app
        // bundle (CallAppDetector path) or a proof-required bundle (MeetBridge /
        // Slack call event). Either way, having an explicit sourceApp means a
        // signal stronger than "this app is frontmost" already fired.
        let sourceIsMeeting = sourceApp.map {
            Self.legitimateMeetingBundles.contains($0)
                || Self.proofRequiredMeetingBundles.contains($0)
        } ?? false
        if !manual && !frontmostIsMeeting && !sourceIsMeeting {
            print("[VOICE-MEET] startCapture refused — no meeting app frontmost (front=\(frontmostBundle ?? "nil"), source=\(sourceApp ?? "nil"))")
            throw MeetingCaptureError.streamSetupFailed("Refused to start: no meeting app is frontmost")
        }
        print("[VOICE-MEET-START] SCStream about to start: frontmost=\(frontmostBundle ?? "nil") source=\(sourceApp ?? "nil")")
        // -------------------------------------------------------------------

        // Capture and retain audio even if the transcription model is not ready.
        // Transcription can run after the model becomes available.

        // 1. Verify/request SCK permission — throws on denial.
        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw MeetingCaptureError.permissionDenied
        }

        // 2. Configure SCStream — audio only, 16kHz mono.
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1
        // Minimise video overhead — we only want audio from the OS mix.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.width  = 2   // smallest valid non-zero dimension
        config.height = 2

        // Use an SCContentFilter that DENY-LISTS known media apps so Spotify
        // etc. don't bleed into the meeting audio. The previous allowlist
        // approach (`including: filter { !media }`) is documented to filter
        // visual content only — system audio routes through the master mix
        // and bypasses the filter entirely. The explicit `excludingApplications:`
        // initializer is what SCK actually honors for audio exclusion on
        // macOS 14+.
        guard let display = shareableContent.displays.first else {
            throw MeetingCaptureError.streamSetupFailed("No displays found — cannot create SCContentFilter")
        }
        let mediaBundleIDs: Set<String> = [
            "com.spotify.client",
            "com.apple.Music",
            "com.apple.QuickTimePlayerX",
            "io.mpv",
            "com.colliderli.iina",
            "org.videolan.vlc",
            "tv.plex.plexamp",
            "com.apple.podcasts",
            "com.apple.TV",
        ]
        let excludedApps = shareableContent.applications.filter {
            mediaBundleIDs.contains($0.bundleIdentifier)
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
        print("[VOICE-MEETING] SCContentFilter excluding \(excludedApps.count) media app(s): \(excludedApps.map(\.bundleIdentifier))")

        // Stash filter+config so the watchdog / delegate can restart the stream
        // without re-querying SCShareableContent off the audio thread.
        lastSCFilter = filter
        lastSCConfig = config

        // Pass `self` as the delegate so we get `stream(_:didStopWithError:)`
        // when the stream silently dies (e.g. Google Meet grabbing the mic
        // exclusively, system audio route changing, sandbox losing capture).
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        } catch {
            throw MeetingCaptureError.streamSetupFailed(error.localizedDescription)
        }

        // The post-meeting transcript depends on the WAV. Open it before
        // starting either capture path so failure cannot report a recording.
        try openAudioWriter()
        let session = UUID()
        let hostNow = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        timelineQueue.sync {
            timelineSession = session
            timeline = MeetingAudioTimelineMixer(origin: hostNow)
            timelineStream = stream
            timelineWarned = false
        }

        // 3. Wire microphone via AVAudioEngine.
        do {
            try setupMicCapture()
            print("[VOICE-MEET-MIC] mic tap installed (target 16kHz mono)")
        } catch {
            stopTimeline(flush: false)
            closeAudioWriter()
            throw MeetingCaptureError.streamSetupFailed("Could not start the microphone: \(error.localizedDescription)")
        }

        // 4. Kick everything off.
        do {
            try Task.checkCancellation()
            try await stream.startCapture()
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            stopTimeline(flush: false)
            closeAudioWriter()
            throw MeetingCaptureError.streamSetupFailed("Could not start meeting audio: \(error.localizedDescription)")
        }
        do {
            // ScreenCaptureKit can complete a cancelled request. Release its stream
            // through the same failure cleanup before opening the microphone.
            try Task.checkCancellation()
            try audioEngine.start()
            print("[VOICE-MEET-MIC] AVAudioEngine started — mic capture LIVE")
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            try? await stream.stopCapture()
            stopTimeline(flush: false)
            closeAudioWriter()
            throw MeetingCaptureError.streamSetupFailed("Could not start the microphone: \(error.localizedDescription)")
        }

        // 5. Voice Isolation mode for cleaner speech in meeting recordings.
        //
        // AVCaptureDevice.MicrophoneMode (available macOS 12+) exposes the mic
        // processing mode chosen by the user in Control Center. Voice Isolation
        // strips background noise and isolates the speaker — ideal for meeting
        // recordings. As of the current SDK, `preferredMicrophoneMode` is a
        // READ-ONLY class property reflecting the user's Control Center selection;
        // there is no programmatic setter exposed in macOS 12–15 headers.
        //
        // WWDC25 session 251 "Enhance your app's audio recording capabilities"
        // introduced a programmatic mic-mode API. Once the macOS 26 SDK ships a
        // confirmed writable setter (e.g. AVCaptureDevice.requestedMicrophoneMode
        // or a new AVAudioSession method), replace this block with the real call.
        // Until then we:
        //   (a) log the currently active mode so it appears in diagnostics, and
        //   (b) note that the user can enable Voice Isolation via Control Center.
        //
        // TODO: Enable programmatic setter when macOS 26 / WWDC25 API is confirmed.
        if #available(macOS 12.0, *) {
            let active = AVCaptureDevice.activeMicrophoneMode
            let preferred = AVCaptureDevice.preferredMicrophoneMode
            print(String(
                format: "[MeetingCapture] microphone mode: active=%d preferred=%d (0=standard 1=wideSpectrum 2=voiceIsolation)",
                active.rawValue, preferred.rawValue
            ))
            if active != .voiceIsolation {
                // Programmatic setter not yet available in the shipping SDK.
                // Guide the user to Control Center to enable Voice Isolation:
                //   Control Center → Mic Modes → Voice Isolation
                print("[MeetingCapture] Voice Isolation not active — enable in Control Center › Mic Modes for cleaner meeting audio")
                // When macOS 26 setter is confirmed, replace with:
                // AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                // or the new programmatic API.
            }
        }

        scStream = stream
        isCapturing = true
        totalSamplesProcessed = 0
        liveTranscript = []
        let generation = UUID()
        accumulatorLock.lock()
        liveGeneration = generation
        accumulator.removeAll(keepingCapacity: true)
        accumulatorLock.unlock()
        liveWorker = nil
        liveTranscriptStatus = "Preparing captions"
        prepareLiveWorkerIfReady(generation: generation)
        startTimelineTimer(session: session)

        // Reset the speaker timeline for the new session. The wall-clock start
        // anchor is captured AFTER stream + engine start so the offsets we
        // compute in transcribeChunk line up with when audio actually started
        // flowing, not the moment we asked SCStream to begin.
        speakerLock.lock()
        speakerTimeline.removeAll(keepingCapacity: true)
        speakerLock.unlock()
        captureStartedAt = Date()

        // Fresh diarizer state for the new session. We hold the SpeakerDiarizer
        // for the lifetime of the service (CoreML model load is expensive) but
        // reset its per-session voice-ID map so this meeting's "voice 0" is the
        // first speaker we hear, not whoever was first in the previous call.
        if diarizer == nil {
            diarizer = SpeakerDiarizer()
        }
        if let diarizer = diarizer {
            await diarizer.reset()
        }

        // Elapsed timer (fires each second).
        durationSeconds = 0
        durationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { break }
                await MainActor.run { self.durationSeconds += 1 }
            }
        }

        // Reset watchdog/restart state for the new session.
        lastSampleArrivalLock.lock()
        lastSampleArrivalAt = Date()
        lastSampleArrivalLock.unlock()
        lastWatchdogSampleCount = 0
        hasAttemptedStreamRestart = false
        hasAttemptedWatchdogRestart = false
        writerFailureLock.lock()
        writerFailureTimestamps.removeAll()
        writerFailureLock.unlock()

        // Start the 1-second audio watchdog. Detects silent SCStream / mic
        // death and posts `voiceMeetingAudioStalled` so the UI can warn the
        // user, then attempts to restart engine+stream once.
        startAudioWatchdog()

        // Reset mic-health counters and start the 10s health log. Every 10s
        // we print mic/sys sample counts so you can grep [VOICE-MEET-MIC]
        // in Console.app and confirm both sources are alive. If mic stops
        // growing while sys keeps growing, we post a notification so the
        // UI layer can surface a "mic dropped" warning.
        sampleCounters.withLock { $0 = SampleCounters() }
        lastMicHealthSnapshotMic = 0
        lastMicHealthSnapshotSys = 0
        micHealthTask?.cancel()
        micHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                guard let self, !Task.isCancelled else { break }
                let snapshot = self.sampleCounters.withLock { $0 }
                let mic = snapshot.mic
                let sys = snapshot.sys
                let micDelta = mic - self.lastMicHealthSnapshotMic
                let sysDelta = sys - self.lastMicHealthSnapshotSys
                self.lastMicHealthSnapshotMic = mic
                self.lastMicHealthSnapshotSys = sys
                let micRate = micDelta / 10  // samples/sec average
                let sysRate = sysDelta / 10
                print("[VOICE-MEET-MIC] health 10s window: mic=\(micDelta) samples (~\(micRate)/s), sys=\(sysDelta) samples (~\(sysRate)/s), total mic=\(mic) sys=\(sys)")
                if micDelta == 0 && sysDelta > 0 {
                    print("[VOICE-MEET-MIC] WARNING — mic appears dead (0 samples in 10s) but system audio still flowing. Your voice may be missing from this recording.")
                    NotificationCenter.default.post(name: Notification.Name("voice.meetingMicDropped"), object: nil)
                }
            }
        }

        // Start the 30-second verbose status logger.
        startStatusLogger()

        // Subscribe to AVAudioEngine config changes (mic device swap, another
        // app grabbing the mic exclusively, sample-rate change, etc.). On macOS
        // there is no AVAudioSession, so we listen to the engine's own notif.
        registerEngineConfigChangeObserver()

        print("[MeetingCapture] capture started — system audio + mic @ \(sampleRate) Hz mono")
    }

    /// Stop capture and return all accumulated transcript segments, the source
    /// app that triggered the session, the URL of the persisted WAV file
    /// (or nil if persistence failed / was disabled), and the participant
    /// names scraped by the Chrome extension during the session.
    func stopCapture() async -> (segments: [TranscriptSegment], sourceApp: String?, audioFileURL: URL?, participantNames: [String], speakerEventsJson: String?) {
        // Snapshot the speaker timeline under the lock and JSON-encode it. We
        // emit nil (not "[]") when no events were recorded so the storage
        // layer can store NULL and the v5 column is genuinely optional.
        func snapshotSpeakerEventsJson() -> String? {
            speakerLock.lock()
            let snapshot = speakerTimeline
            speakerLock.unlock()
            guard !snapshot.isEmpty else { return nil }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot),
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return s
        }

        guard isCapturing else {
            return (liveTranscript, sourceApp, audioFileURL, participantNames, snapshotSpeakerEventsJson())
        }

        let capturedSourceApp = sourceApp
        let capturedAudioURL = audioFileURL
        let capturedParticipantNames = participantNames
        let capturedSpeakerEventsJson = snapshotSpeakerEventsJson()

        // Stop mic.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        // Stop SCStream.
        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }

        // Flush the remaining aligned audio before closing the writer.
        stopTimeline(flush: true)

        // Cancel the timer.
        durationTimer?.cancel()
        durationTimer = nil
        micHealthTask?.cancel()
        micHealthTask = nil
        let finalCounts = sampleCounters.withLock { $0 }
        print("[VOICE-MEET-MIC] capture stopped — final totals: mic=\(finalCounts.mic) sys=\(finalCounts.sys) samples")

        // Cancel watchdog + status logger and unregister the config observer.
        // (Strictly additive — existing teardown above still runs unchanged.)
        watchdogTask?.cancel()
        watchdogTask = nil
        statusLogTask?.cancel()
        statusLogTask = nil
        if let token = configChangeObserver {
            NotificationCenter.default.removeObserver(token)
            configChangeObserver = nil
        }

        isCapturing = false
        accumulatorLock.lock()
        liveGeneration = UUID()
        accumulatorLock.unlock()
        liveTask?.cancel()
        liveWorker = nil
        liveWorkerLoading = false
        liveTranscriptStatus = "Recording finished"

        // LAZY-TRANSCRIBE: nothing to flush or drain — we never transcribed
        // in-stream. The accumulator's samples are written to the WAV directly
        // via writeSamplesToFile; the file is closed below. Transcription runs
        // post-hoc against that file.
        accumulatorLock.lock()
        accumulator.removeAll(keepingCapacity: true)
        accumulatorLock.unlock()

        // Close the on-disk writer. Hop through the write queue first so any
        // queued sample-append writes finish before the file is released.
        audioWriteQueue.sync { /* drain queued writes */ }
        closeAudioWriter()

        // Participant list order and talk frequency cannot identify a speaker.
        // Keep diarized labels anonymous until a person explicitly names them.

        print("[MeetingCapture] capture stopped — \(liveTranscript.count) segments, \(durationSeconds)s elapsed")
        sourceApp = nil
        participantNames = []
        // Clear speaker timeline + start anchor so a subsequent session starts
        // clean. The timeline is small and bounded, but we hold no benefit to
        // stale events from the previous meeting.
        speakerLock.lock()
        speakerTimeline.removeAll(keepingCapacity: false)
        speakerLock.unlock()
        captureStartedAt = nil
        // Live captions can skip chunks; force a complete post-hoc transcript from the WAV.
        return ([], capturedSourceApp, capturedAudioURL, capturedParticipantNames, capturedSpeakerEventsJson)
    }

    // MARK: - Speaker timeline API

    /// Append an active-speaker event to the timeline. Called from the
    /// MeetBridgeServer callback (main thread) for every change Google Meet's
    /// active-speaker observer reports. The timeline is bounded to the last
    /// `speakerTimelineMaxCount` events to keep memory predictable on long
    /// meetings — at ~1 event/sec per active speaker that's roughly an hour
    /// of three-way conversation.
    func recordSpeakerEvent(name: String, active: Bool, t: Date) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let event = SpeakerEvent(name: trimmed, t: t, active: active)
        speakerLock.lock()
        speakerTimeline.append(event)
        if speakerTimeline.count > speakerTimelineMaxCount {
            let overflow = speakerTimeline.count - speakerTimelineMaxCount
            speakerTimeline.removeFirst(overflow)
        }
        speakerLock.unlock()
    }

    /// Look up the speaker whose `active=true` event was most recent at or
    /// before `at`, AND whose subsequent `active=false` event (if any) is
    /// strictly after `at`. Returns nil when no speaker matches — caller
    /// keeps the default "MEETING" label in that case. Reads the timeline
    /// under the lock to stay safe against concurrent recordSpeakerEvent
    /// calls from the bridge server.
    private func speakerName(at: Date) -> String? {
        speakerLock.lock()
        let snapshot = speakerTimeline
        speakerLock.unlock()
        guard !snapshot.isEmpty else { return nil }

        // Group events by lowercase name so we can independently scan each
        // speaker's on/off history. We need the LAST active=true at or before
        // `at` whose matching active=false (if any) is after `at`.
        var bestName: String? = nil
        var bestStart: Date = .distantPast
        // Track per-name last-active-true and whether they were closed before `at`.
        var perName: [String: (lastOn: Date?, displayName: String, lastOff: Date?)] = [:]
        for ev in snapshot {
            if ev.t > at { break }
            let key = ev.name.lowercased()
            var entry = perName[key] ?? (nil, ev.name, nil)
            if ev.active {
                entry.lastOn = ev.t
                entry.displayName = ev.name
            } else {
                entry.lastOff = ev.t
            }
            perName[key] = entry
        }
        for (_, entry) in perName {
            guard let on = entry.lastOn else { continue }
            // If the most recent on/off pair shows they're still talking, the
            // last off is either nil or strictly before the last on.
            let stillTalking: Bool
            if let off = entry.lastOff { stillTalking = off < on } else { stillTalking = true }
            guard stillTalking else { continue }
            if on > bestStart {
                bestStart = on
                bestName = entry.displayName
            }
        }
        return bestName
    }

    // MARK: - Audio file persistence (streaming WAV write)

    /// Open the WAV writer at `~/Library/Application Support/Voice/Audio/meeting-<ts>-<short>.wav`.
    /// Throw before capture starts if the recording cannot be saved.
    private func openAudioWriter() throws {
        // Only reset accounting after all blocks from the preceding writer
        // have released their reservations. This method runs off the writer
        // queue; capture startup is serialized by the app's lifecycle gate.
        audioWriterLock.lock()
        audioWriterAcceptingSamples = false
        audioWriterLock.unlock()
        audioWriteQueue.sync { }
        let url = makeMeetingAudioURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            audioWriterLock.lock()
            audioWriterGeneration = UUID()
            audioWritePendingBytes = 0
            audioWritePendingBlocks = 0
            audioWriterAcceptingSamples = true
            audioWriterStopRequested = false
            audioFileWriter = file
            audioFileURL = url
            audioWriterLock.unlock()
            print("[AUDIO-PERSIST] meeting audio writer opened → \(url.lastPathComponent)")
        } catch {
            print("[AUDIO-PERSIST] failed to open meeting audio writer: \(error.localizedDescription)")
            audioWriterLock.lock()
            audioFileWriter = nil
            audioFileURL = nil
            audioWriterAcceptingSamples = false
            audioWriterLock.unlock()
            throw MeetingCaptureError.streamSetupFailed("Could not save meeting audio. Check available storage and permissions: \(error.localizedDescription)")
        }
    }

    /// Flush + close the writer. Safe to call when no writer is open.
    private func closeAudioWriter() {
        audioWriterLock.lock()
        let writer = audioFileWriter
        audioFileWriter = nil
        audioWriterAcceptingSamples = false
        audioWriterLock.unlock()
        _ = writer  // ARC release fires here; AVAudioFile.deinit flushes + closes
    }

    /// Build the on-disk URL for the meeting WAV. Format:
    /// `meeting-{yyyy-MM-ddTHH-mm-ss}-{6-char-uuid}.wav`. Colons stripped from
    /// the timestamp so the filename is portable across filesystems.
    private func makeMeetingAudioURL() -> URL {
        let appSupport: URL
        do {
            appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            appSupport = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        }
        let dir = appSupport.appendingPathComponent("Voice/Audio", isDirectory: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let stamp = fmt.string(from: Date())
        let shortID = String(UUID().uuidString.prefix(6)).lowercased()
        return dir.appendingPathComponent("meeting-\(stamp)-\(shortID).wav")
    }

    /// Hand `samples` to the background write queue. Builds an AVAudioPCMBuffer
    /// off the audio thread so the tap closure returns immediately.
    private func writeSamplesToFile(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let (byteCount, overflow) = samples.count.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        audioWriterLock.lock()
        guard audioFileWriter != nil, audioWriterAcceptingSamples else {
            audioWriterLock.unlock()
            return
        }
        let generation = audioWriterGeneration
        guard !overflow, byteCount <= audioWriteByteLimit - audioWritePendingBytes,
              audioWritePendingBlocks < audioWriteBlockLimit else {
            // Keep the writer open for accepted blocks to drain, but never
            // accumulate more samples after the first unsaved block.
            audioWriterAcceptingSamples = false
            audioWriterLock.unlock()
            requestAudioWriterStop(generation: generation, reason: "Storage is not keeping up with the recording")
            return
        }
        audioWritePendingBytes += byteCount
        audioWritePendingBlocks += 1
        let format = audioFileFormat
        // Enqueue while holding the reservation lock. A new writer first
        // disables acceptance under this same lock, then drains the queue,
        // so no reserved old block can be enqueued after that drain.
        audioWriteQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.audioWriterLock.lock()
                // A stale completion must never debit a later session.
                if self.audioWriterGeneration == generation {
                    self.audioWritePendingBytes -= byteCount
                    self.audioWritePendingBlocks -= 1
                }
                self.audioWriterLock.unlock()
            }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ) else {
                self.requestAudioWriterStop(generation: generation, reason: "Could not allocate the recording write buffer", discardWriter: true)
                return
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let ch = buffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress {
                        memcpy(ch, base, samples.count * MemoryLayout<Float>.size)
                    }
                }
            }
            // Re-check the writer under the lock right before writing so a
            // mid-flight stopCapture can't race with us holding a stale ref.
            self.audioWriterLock.lock()
            let liveWriter = self.audioWriterGeneration == generation ? self.audioFileWriter : nil
            self.audioWriterLock.unlock()
            guard let liveWriter = liveWriter else { return }
            do {
                try liveWriter.write(from: buffer)
            } catch {
                print("[AUDIO-PERSIST] Meeting audio write failed: \(error.localizedDescription)")
                self.requestAudioWriterStop(generation: generation, reason: "Could not save meeting audio", discardWriter: true)
            }
        }
        audioWriterLock.unlock()
    }

    /// Never stop capture while holding a writer/timeline lock or from their
    /// serial queues. The existing stop path drains accepted writes and keeps
    /// the partial WAV. At most one stop request is emitted for each writer.
    private func requestAudioWriterStop(generation: UUID, reason: String, discardWriter: Bool = false) {
        audioWriterLock.lock()
        guard audioWriterGeneration == generation else {
            audioWriterLock.unlock()
            return
        }
        audioWriterAcceptingSamples = false
        if discardWriter { audioFileWriter = nil }
        let shouldNotify = !audioWriterStopRequested
        audioWriterStopRequested = true
        audioWriterLock.unlock()
        guard shouldNotify else { return }
        print("[AUDIO-PERSIST] \(reason); stopping and keeping the partial recording")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioWriterLock.lock()
            let isCurrent = self.audioWriterGeneration == generation
            self.audioWriterLock.unlock()
            guard isCurrent else { return }
            NotificationCenter.default.post(name: .voiceMeetingAudioStalled, object: nil)
            NotificationCenter.default.post(name: .voiceStopMeetingRequested, object: nil)
        }
    }

    // MARK: - Mic capture setup

    private func setupMicCapture() throws {
        let inputNode = audioEngine.inputNode
        // Bind only the app's stopped input unit; never alter system settings.
        guard !audioEngine.isRunning, let unit = inputNode.audioUnit else {
            throw MeetingCaptureError.streamSetupFailed("Microphone is unavailable. Check your input and try again.")
        }
        let preferredUID = UserDefaults.standard.string(forKey: MicrophonePreference.key) ?? ""
        var selected = MicrophonePreference.resolve(preferredUID: preferredUID,
            priorityUIDs: MicrophonePreference.savedPriorityUIDs(),
            inputs: MicrophonePreference.inputs(), defaultDeviceID: MicrophonePreference.defaultDeviceID())
        guard selected != 0 else {
            throw MeetingCaptureError.streamSetupFailed("No microphone is available. Check your input and try again.")
        }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw MeetingCaptureError.streamSetupFailed("Could not select your microphone. Check your input and try again (\(status)).")
        }
        var actual: AudioDeviceID = 0
        var actualSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let readStatus = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &actualSize)
        guard readStatus == noErr, actual == selected else {
            throw MeetingCaptureError.streamSetupFailed("Could not confirm the selected microphone. Check your input and try again.")
        }
        let hwFormat = inputNode.inputFormat(forBus: 0)

        // Reset DSP state for the (re)started mic path. We do this here rather
        // than in startCapture() so engine-restarts from a config-change or
        // watchdog also get a clean filter state — otherwise the HPF carries a
        // stale `prevIn`/`prevOut` from the old device and dribbles a brief DC
        // transient into the first chunk after the restart.
        hpfPrevIn = 0
        hpfPrevOut = 0
        compressorPeak = 0
        audioPolishEnabled = (UserDefaults.standard.object(forKey: "voice.meetingAudioPolish") as? Bool) ?? true

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MeetingCaptureError.streamSetupFailed("Could not create 16kHz mono AVAudioFormat")
        }

        // If hardware is already 16kHz mono, tap directly; otherwise convert.
        let tapFormat: AVAudioFormat
        if abs(hwFormat.sampleRate - sampleRate) < 0.1 && hwFormat.channelCount == 1 {
            tapFormat = targetFormat
        } else {
            // Install the tap at the hardware format; convert in the block.
            tapFormat = hwFormat
        }

        let converter: AVAudioConverter?
        if tapFormat != targetFormat {
            // 23 Nov 2026: a 3-channel mic with no layout downmixes to silence; channels are averaged to mono in the
            // tap first (AudioCaptureService.monoMix), so the converter starts from mono.
            let from = tapFormat.channelCount > 1 && targetFormat.channelCount == 1
                ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: tapFormat.sampleRate, channels: 1, interleaved: false)!
                : tapFormat
            converter = AVAudioConverter(from: from, to: targetFormat)
        } else {
            converter = nil
        }

        let session = timelineQueue.sync { timelineSession }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, time in
            guard let self else { return }
            guard time.isHostTimeValid else { self.warnTimeline("Microphone timestamp unavailable"); return }
            let timestamp = CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(time.hostTime))
            if let conv = converter {
                // Resample / downmix to 16kHz mono.
                let ratio = self.sampleRate / tapFormat.sampleRate
                let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }
                var convError: NSError?
                var sourceConsumed = false
                conv.convert(to: outBuf, error: &convError) { _, status in
                    if sourceConsumed {
                        status.pointee = .endOfStream
                        return nil
                    }
                    sourceConsumed = true
                    status.pointee = .haveData
                    return AudioCaptureService.monoMix(buffer) ?? buffer
                }
                if convError == nil {
                    self.receiveMicBuffer(outBuf, timestamp: timestamp, session: session)
                }
            } else {
                self.receiveMicBuffer(buffer, timestamp: timestamp, session: session)
            }
        }
    }

    // MARK: - Accumulator helpers

    private func warnTimeline(_ reason: String) {
        timelineQueue.async { [weak self] in
            guard let self, self.timeline != nil, !self.timelineWarned else { return }
            self.timelineWarned = true
            print("[MeetingCapture] Audio timing problem: \(reason)")
            NotificationCenter.default.post(name: .voiceMeetingAudioStalled, object: nil)
        }
    }

    private func receiveMicBuffer(_ buffer: AVAudioPCMBuffer, timestamp: Double, session: UUID) {
        guard let channelData = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        enqueueTimeline(samples, source: .microphone, timestamp: timestamp, session: session, stream: nil)
    }

    private func enqueueTimeline(_ samples: [Float], source: MeetingAudioTimelineMixer.Source,
                                 timestamp: Double, session: UUID?, stream: SCStream?) {
        timelineQueue.async { [weak self] in
            guard let self, self.timeline != nil else { return }
            if let session, session != self.timelineSession { return }
            if let stream, self.timelineStream !== stream { return }
            let result = self.timeline!.append(samples, source: source, startTime: timestamp)
            self.sampleCounters.withLock {
                switch source {
                case .microphone: $0.mic &+= UInt64(result.accepted)
                case .system: $0.sys &+= UInt64(result.accepted)
                }
            }
            self.lastSampleArrivalLock.lock()
            if result.accepted > 0 {
                self.lastSampleArrivalAt = Date()
                switch source {
                case .microphone: self.lastSampleWasMic = true
                case .system: self.lastSampleWasSystem = true
                }
            }
            self.lastSampleArrivalLock.unlock()
            if (result.late > 0 || result.beyondWindow > 0) && !self.timelineWarned {
                self.timelineWarned = true
                print("[MeetingCapture] Dropped audio frames: late=\(result.late) outsideWindow=\(result.beyondWindow)")
                NotificationCenter.default.post(name: .voiceMeetingAudioStalled, object: nil)
            }
        }
    }

    private func drainTimeline(before time: Double) {
        while timeline != nil {
            let output = timeline!.drain(before: time)
            guard !output.microphone.isEmpty else { break }
            appendMixedSamples(mic: output.microphone, sys: output.system)
        }
    }

    private func startTimelineTimer(session: UUID) {
        timelineQueue.sync {
            let timer = DispatchSource.makeTimerSource(queue: timelineQueue)
            timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
            timer.setEventHandler { [weak self] in
                guard let self, self.timelineSession == session, self.timeline != nil else { return }
                let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
                self.drainTimeline(before: now - self.timelineLateness)
            }
            timelineTimer = timer
            timer.resume()
        }
    }

    private func stopTimeline(flush: Bool) {
        timelineQueue.sync {
            timelineTimer?.cancel()
            timelineTimer = nil
            if flush {
                let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
                drainTimeline(before: max(now, timeline?.bufferedEndTime ?? now))
            }
            timeline = nil
            timelineStream = nil
            timelineSession = UUID()
        }
    }

    /// Core mix-and-accumulate routine. One of mic/sys may be nil (we mix whatever we have).
    ///
    /// When `voice.meetingAudioPolish` is enabled (default), the mic path runs
    /// through HPF @ 80Hz → gain → peak-follower compressor before mixing, and
    /// the final mixed sample is soft-clipped through tanh instead of hard
    /// clipped. Sys audio is ducked by 0.7× while the user is speaking (mic
    /// frame peak > 0.3) so the user's voice cuts through in playback. When
    /// disabled, behavior matches the original raw mix + hard clip.
    private func appendMixedSamples(mic: [Float]?, sys: [Float]?) {
        let count = mic?.count ?? sys?.count ?? 0
        guard count > 0 else { return }

        var mixed = [Float](repeating: 0, count: count)

        // Mic gain boost. The local mic is usually MUCH quieter than the
        // SCStream system mix (system audio comes through pre-amplified by
        // the meet app, plus Meet/Zoom apply gain compensation that we can't
        // see). Without a boost the user's own voice gets drowned out in
        // playback. 3.5× lifts mic above system level so the user's own
        // voice is clearly audible. The post-mix soft-clip (or hard clip in
        // legacy mode) prevents clipping on loud peaks. User-overridable
        // via `voice.meetingMicGain`.
        let micGain: Float = {
            let stored = UserDefaults.standard.double(forKey: "voice.meetingMicGain")
            return stored > 0 ? Float(stored) : 3.5
        }()

        let polish = audioPolishEnabled

        // --- Mic pre-processing pass ---
        //
        // Build the processed mic buffer once so the mix step below stays a
        // straight read. When polish is off we just apply the gain and let the
        // legacy hard-clip path handle the rest.
        var processedMic: [Float]? = nil
        var micFramePeak: Float = 0
        if let m = mic {
            var out = [Float](repeating: 0, count: m.count)
            if polish {
                // HPF state pulled into locals so the inner loop touches stack
                // memory only — the compiler reliably keeps these in registers.
                let a = hpfCoefficient
                var prevIn = hpfPrevIn
                var prevOut = hpfPrevOut
                var peak = compressorPeak

                // Compressor params. Threshold 0.5, ratio 3:1, makeup 1.0.
                // We use a peak-follower (exponential smoothing) instead of a
                // proper attack/release envelope — way cheaper, perfectly fine
                // for speech which doesn't have sharp transients like drums.
                let threshold: Float = 0.5
                let invRatio: Float = 1.0 / 3.0  // 1/ratio for the slope below threshold
                let alpha = compressorAlpha

                for i in 0..<m.count {
                    let x = m[i]

                    // 1. High-pass filter (1-pole, ~80Hz @ 16kHz).
                    //    y[n] = a * (y[n-1] + x[n] - x[n-1])
                    let y = a * (prevOut + x - prevIn)
                    prevIn = x
                    prevOut = y

                    // 2. Apply mic gain.
                    let gained = y * micGain

                    // 3. Peak-follower compressor.
                    //    Smooth the absolute-value envelope; when it exceeds
                    //    threshold, attenuate by (1 - 1/ratio) of the overshoot.
                    let absG = abs(gained)
                    if absG > peak {
                        peak = absG  // fast attack — catch transients immediately
                    } else {
                        peak = peak + alpha * (absG - peak)  // exponential release
                    }
                    var comp: Float = gained
                    if peak > threshold {
                        // Linear-domain single-knee compressor. Overshoot above
                        // threshold gets scaled by 1/ratio. Makeup gain = 1.0
                        // (no extra boost — the soft-clip handles the ceiling).
                        let overshoot = peak - threshold
                        let allowedOvershoot = overshoot * invRatio
                        let targetPeak = threshold + allowedOvershoot
                        let gainReduction = targetPeak / peak
                        comp = gained * gainReduction
                    }

                    out[i] = comp
                    let aComp = abs(comp)
                    if aComp > micFramePeak { micFramePeak = aComp }
                }

                hpfPrevIn = prevIn
                hpfPrevOut = prevOut
                compressorPeak = peak
            } else {
                // Polish off — apply gain only; preserve legacy behavior.
                for i in 0..<m.count {
                    let g = m[i] * micGain
                    out[i] = g
                    let ag = abs(g)
                    if ag > micFramePeak { micFramePeak = ag }
                }
            }
            processedMic = out
        }

        // --- Mix ---
        //
        // Sys-audio ducking: when the user is speaking loudly (mic frame peak
        // > 0.3), attenuate the system mix to 0.7× so the user's voice cuts
        // through in playback. Speech-detection threshold is intentionally
        // conservative — short breath/keyboard noise shouldn't trigger it.
        let sysScale: Float = (polish && micFramePeak > 0.3) ? 0.7 : 1.0

        // Output limiter: soft-clip via tanh(x * 0.9) when polish is on.
        // tanh(x * 0.9) is ≈ x for |x| < 0.5, gently rolls off above 0.7, and
        // asymptotes to ±tanh(0.9) ≈ ±0.716 as |x| → ∞. To preserve perceived
        // loudness we scale the post-tanh output back up by 1/tanh(0.9), so a
        // sample at the legacy clip boundary (|x| = 1) still lands close to
        // ±1 but smoothly compressed rather than hard-cut.
        let tanhMax = tanh(Float(0.9))  // ≈ 0.7163
        let invTanhMax = 1.0 / tanhMax

        @inline(__always) func limit(_ x: Float) -> Float {
            if polish {
                return tanh(x * 0.9) * invTanhMax
            } else {
                return max(-1.0, min(1.0, x))
            }
        }

        if let m = processedMic, let s = sys {
            let len = min(m.count, s.count)
            for i in 0..<len {
                mixed[i] = limit(m[i] + s[i] * sysScale)
            }
            // If one side was longer, copy the remainder as-is (limited).
            if m.count > len {
                for i in len..<m.count { mixed[i] = limit(m[i]) }
            } else if s.count > len {
                for i in len..<s.count { mixed[i] = limit(s[i] * sysScale) }
            }
        } else if let m = processedMic {
            for i in 0..<m.count { mixed[i] = limit(m[i]) }
        } else if let s = sys {
            // Sys-only frame — no mic peak this frame, so no ducking applied.
            for i in 0..<s.count { mixed[i] = limit(s[i]) }
        }

        // Stream the mixed samples to the on-disk WAV writer. Runs on a
        // background queue so this never blocks the tap thread.
        writeSamplesToFile(mixed)

        accumulatorLock.lock()
        accumulator.append(contentsOf: mixed)
        let currentCount = accumulator.count

        var chunk: [Float]? = nil
        let chunkGeneration = liveGeneration
        let chunkStart = Double(totalSamplesProcessed) / sampleRate
        if currentCount >= chunkSamples {
            chunk = Array(accumulator.prefix(chunkSamples))
            totalSamplesProcessed += chunkSamples
            accumulator.removeFirst(chunkSamples)
        }
        accumulatorLock.unlock()
        if let chunk {
            // Never block the audio callback. At most one inference is outstanding;
            // skipped captions remain recoverable from the complete on-disk WAV.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCapturing, self.liveGeneration == chunkGeneration else { return }
                if self.liveWorker == nil { self.prepareLiveWorkerIfReady(generation: chunkGeneration) }
                guard let worker = self.liveWorker, !self.liveBusy else {
                    if self.liveWorker != nil { self.liveTranscriptStatus = "Captions behind. Recording is saved." }
                    return
                }
                self.liveBusy = true
                let generation = chunkGeneration
                self.liveTask = Task { [weak self] in
                    do {
                        let text = try await worker.transcribe(chunk)
                        await MainActor.run {
                            guard let self else { return }
                            self.liveBusy = false
                            self.liveTask = nil
                            guard self.liveGeneration == generation else { return }
                            if !text.isEmpty {
                                self.liveTranscript.append(TranscriptSegment(speaker: "Meeting", text: text, startTime: chunkStart, endTime: chunkStart + Double(chunk.count) / 16_000))
                            }
                            self.liveTranscriptStatus = "Live captions update every 15 seconds"
                        }
                    } catch {
                        await MainActor.run {
                            guard let self else { return }
                            self.liveBusy = false
                            self.liveTask = nil
                            guard self.liveGeneration == generation else { return }
                            self.liveTranscriptStatus = "Captions unavailable. Recording is saved."
                        }
                    }
                }
            }
        }
    }

    // MARK: - Watchdog + status logger + restart helpers
    //
    // Everything below is strictly additive — it does not replace any existing
    // behavior. It exists to surface and recover from the silent SCStream / mic
    // death that caused a 36-minute meeting to produce a 1.7-minute WAV.

    /// Start the 1-second watchdog. Posts `voiceMeetingAudioStalled` and
    /// attempts a single engine+stream restart when no fresh audio has arrived
    /// for >5s while `isCapturing == true`.
    private func startAudioWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { break }
                guard self.isCapturing else { continue }

                self.accumulatorLock.lock()
                let accCount = self.accumulator.count
                self.accumulatorLock.unlock()
                let currentTotal = self.totalSamplesProcessed + accCount

                self.lastSampleArrivalLock.lock()
                let lastArrival = self.lastSampleArrivalAt
                let sawSys = self.lastSampleWasSystem
                let sawMic = self.lastSampleWasMic
                self.lastSampleArrivalLock.unlock()

                let secondsSinceLastSample = Date().timeIntervalSince(lastArrival)

                // Stall trigger: no fresh samples for >5s. We also confirm the
                // raw counter hasn't grown, in case sample-arrival time updates
                // got lost. Either condition is enough.
                let counterStuck = (currentTotal == self.lastWatchdogSampleCount)
                let timeStuck = (secondsSinceLastSample >= 5.0)

                if timeStuck {
                    print("[MeetingCapture] WATCHDOG: no audio in 5s — sys=\(sawSys) mic=\(sawMic)")
                    NotificationCenter.default.post(
                        name: .voiceMeetingAudioStalled,
                        object: nil
                    )
                    if !self.hasAttemptedWatchdogRestart {
                        self.hasAttemptedWatchdogRestart = true
                        await self.attemptRestartAfterStall()
                    }
                } else if !counterStuck {
                    // Reset the "did we already restart?" guard once audio is
                    // flowing again, so a later stall can trigger another
                    // restart attempt.
                    self.hasAttemptedWatchdogRestart = false
                }

                self.lastWatchdogSampleCount = currentTotal
            }
        }
    }

    /// Start a 30-second verbose status logger. Logs sample counts, rate,
    /// writer state, and stream state. Tagged `[MeetingCapture]` for grep-ing.
    private func startStatusLogger() {
        statusLogTask?.cancel()
        statusLogTask = Task { [weak self] in
            var lastTotal = 0
            var lastAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { break }
                guard self.isCapturing else { continue }

                self.accumulatorLock.lock()
                let accCount = self.accumulator.count
                self.accumulatorLock.unlock()
                let currentTotal = self.totalSamplesProcessed + accCount

                let now = Date()
                let elapsed = now.timeIntervalSince(lastAt)
                let delta = currentTotal - lastTotal
                let rate = elapsed > 0 ? Double(delta) / elapsed : 0
                lastTotal = currentTotal
                lastAt = now

                self.audioWriterLock.lock()
                let writerOpen = self.audioFileWriter != nil
                self.audioWriterLock.unlock()
                let streamActive = self.scStream != nil
                let engineRunning = self.audioEngine.isRunning

                print(String(
                    format: "[MeetingCapture] STATUS samples=%d Δ=%d rate=%.0f/s writer=%@ stream=%@ engine=%@",
                    currentTotal, delta, rate,
                    writerOpen ? "open" : "closed",
                    streamActive ? "active" : "nil",
                    engineRunning ? "running" : "stopped"
                ))
            }
        }
    }

    /// Register for AVAudioEngine config-change notifications. When the engine
    /// reconfigures (mic device swap, sample-rate change, another app grabbing
    /// the mic exclusively — Google Meet's web stack is notorious for this),
    /// the tap is invalidated and audio stops flowing. We restart the engine.
    private func registerEngineConfigChangeObserver() {
        if configChangeObserver != nil { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isCapturing else { return }
            print("[MeetingCapture] AVAudioEngine config change — attempting to restart engine")
            Task { [weak self] in
                await self?.attemptRestartEngine()
            }
        }
    }

    /// Try to restart the AVAudioEngine after a config change or stall.
    /// Re-installs the mic tap. Logs success/failure. Strictly best-effort.
    private func attemptRestartEngine() async {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard isCapturing else { return }

        // Remove the existing tap (safe to call even if not installed) and
        // stop the engine so we can reinstall cleanly.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        do {
            try setupMicCapture()
            try audioEngine.start()
            print("[MeetingCapture] AVAudioEngine restart succeeded")
        } catch {
            print("[MeetingCapture] AVAudioEngine restart FAILED: \(error.localizedDescription)")
        }
    }

    /// Try to restart the SCStream using the stashed filter+config. Called
    /// from the `SCStreamDelegate.stream(_:didStopWithError:)` path and from
    /// the watchdog. If the restart also fails, surfaces a toast.
    private func attemptRestartStream(reason: String) async {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard isCapturing else { return }
        guard let filter = lastSCFilter, let config = lastSCConfig else {
            print("[MeetingCapture] cannot restart SCStream — no stashed filter/config (\(reason))")
            NotificationCenter.default.post(name: .voiceMeetingAudioStalled, object: nil)
            return
        }

        // Tear down the existing stream (best-effort).
        if let existing = scStream {
            try? await existing.stopCapture()
        }
        scStream = nil

        // Spin a fresh stream with the same filter+config.
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            timelineQueue.sync { timelineStream = stream }
            try await stream.startCapture()
            // Stop may have run while the stream was starting; it saw scStream == nil.
            guard isCapturing else {
                try? await stream.stopCapture()
                timelineQueue.sync { if timelineStream === stream { timelineStream = nil } }
                return
            }
            scStream = stream
            print("[MeetingCapture] SCStream restart succeeded (\(reason))")
        } catch {
            print("[MeetingCapture] SCStream restart FAILED (\(reason)): \(error.localizedDescription)")
            // Inform the UI so the user knows the recording may be incomplete.
            NotificationCenter.default.post(name: .voiceMeetingAudioStalled, object: nil)
        }
    }

    /// Joint engine + stream restart, invoked when the watchdog detects a stall.
    private func attemptRestartAfterStall() async {
        print("[MeetingCapture] watchdog attempting joint engine+stream restart")
        await attemptRestartEngine()
        await attemptRestartStream(reason: "watchdog stall")
    }
}

// MARK: - SCStreamDelegate (stop detection)

extension MeetingCaptureService: SCStreamDelegate {

    /// Fired when the stream stops on its own — typically because another app
    /// grabbed exclusive access to the audio device, the user revoked Screen
    /// Recording permission, or the system audio route changed. Without a
    /// delegate this was completely silent, which is exactly how a 36-minute
    /// meeting wound up as a 1.7-minute WAV file.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[MeetingCapture] SCStream didStopWithError: \(error.localizedDescription)")
        guard isCapturing else { return }

        // Attempt one restart with the same filter. If that also fails, the
        // restart helper posts `voiceMeetingAudioStalled` so the UI can warn.
        if !hasAttemptedStreamRestart {
            hasAttemptedStreamRestart = true
            Task { [weak self] in
                await self?.attemptRestartStream(reason: "didStopWithError")
            }
        } else {
            print("[MeetingCapture] SCStream already restarted once this session — giving up")
            NotificationCenter.default.post(name: .voiceMeetingAudioStalled, object: nil)
        }
    }
}

// MARK: - SCStreamOutput (system audio delegate)

extension MeetingCaptureService: SCStreamOutput {

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Extract the audio format from the sample buffer description.
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }

        let srcSampleRate = asbd.pointee.mSampleRate
        let srcChannels   = Int(asbd.pointee.mChannelsPerFrame)
        let numFrames     = CMSampleBufferGetNumSamples(sampleBuffer)

        guard numFrames > 0 else { return }

        // Extract raw bytes from the CMBlockBuffer.
        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &dataLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let ptr = dataPointer, dataLength > 0 else { return }

        // The audio from SCStream with channelCount=1 and sampleRate=16000 arrives
        // as interleaved Float32. Convert to [Float], downmixing if needed.
        let floatCount = dataLength / MemoryLayout<Float>.size
        let rawSamples = Array(UnsafeBufferPointer(
            start: UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self),
            count: floatCount
        ))

        let samples: [Float]
        if srcChannels <= 1 || rawSamples.count == numFrames {
            // Already mono.
            samples = rawSamples
        } else {
            // Downmix multi-channel to mono by averaging channels.
            var mono = [Float](repeating: 0, count: numFrames)
            let ch = srcChannels
            for frame in 0..<numFrames {
                var sum: Float = 0
                for c in 0..<ch {
                    let idx = frame * ch + c
                    if idx < rawSamples.count { sum += rawSamples[idx] }
                }
                mono[frame] = sum / Float(ch)
            }
            samples = mono
        }

        // If the stream gave us a different sample rate (shouldn't happen since we
        // requested 16kHz in the config, but be defensive), resample simply via
        // linear interpolation before mixing.
        let finalSamples: [Float]
        if abs(srcSampleRate - sampleRate) < 0.1 {
            finalSamples = samples
        } else {
            finalSamples = linearResample(samples, from: srcSampleRate, to: sampleRate)
        }

        guard let clock = stream.synchronizationClock else {
            warnTimeline("System audio clock unavailable")
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        let timestamp = CMTimeGetSeconds(hostTime)
        guard timestamp.isFinite else { warnTimeline("System audio timestamp unavailable"); return }
        enqueueTimeline(finalSamples, source: .system, timestamp: timestamp, session: nil, stream: stream)
    }

    /// Simple linear interpolation resampler (fallback — normally unused).
    private func linearResample(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        let ratio = srcRate / dstRate
        let outputCount = Int(Double(input.count) / ratio)
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIdx = Double(i) * ratio
            let lo = Int(srcIdx)
            let hi = min(lo + 1, input.count - 1)
            let t = Float(srcIdx - Double(lo))
            output[i] = input[lo] * (1 - t) + input[hi] * t
        }
        return output
    }
}


/// Uses its own decoder/manager so live captions do not mutate the shared dictation decoder.
private actor MeetingLiveWorker {
    private let manager: AsrManager
    private let decoderLayers: Int
    init(models: AsrModels) async throws {
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        self.decoderLayers = await manager.decoderLayerCount
    }
    func transcribe(_ samples: [Float]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
