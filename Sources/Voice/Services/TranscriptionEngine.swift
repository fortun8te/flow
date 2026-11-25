// VOICE — Transcription Engine Protocol
// ============================================================
// Abstract transcription backend. Lets us swap between engines
// (WhisperKit chunk-based, FluidAudio streaming, mock for tests)
// without touching the recording pipeline.
//
// Two surfaces — both drive the same underlying model:
//   1. Streaming (dictation):  start → feed → stop, plus partial AsyncStream
//   2. Batch (long meetings):  transcribe(audioChunk:chunkStartTime:)
//
// Implementors keep their own model state. `prepare()` is the
// download-and-load step; `isReady` flips true once the model is in memory.
// ============================================================

import Foundation

// MARK: - ModelState
// Shared by all engines. Drives the UI's ready/downloading badge.

enum ModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case loading
    case ready
    case error(String)
}

// MARK: - TranscriptionEngine

protocol TranscriptionEngine: AnyObject {
    /// Live model lifecycle. Mirrors download → load → ready.
    var modelState: ModelState { get }

    /// True once the model is loaded and `start` / `transcribe` will work.
    var isReady: Bool { get }

    /// Download (if needed) and load the model into memory. Idempotent.
    func prepare() async throws

    // MARK: Streaming surface (dictation)

    /// Begin a fresh dictation session. Resets internal token state.
    func start() async throws

    /// Push 16 kHz mono Float32 PCM samples. The engine buffers internally
    /// and decodes on its own cadence. Safe to call from any actor.
    func feed(samples: [Float]) async

    /// Finalize the current session and return to idle state.
    ///
    /// Implementations that assemble transcripts inline (e.g. streaming engines)
    /// may return the final assembled segments here. Implementations that rely on
    /// a separate `transcribeFile(url:)` pass (e.g. FluidAudio / macparakeet)
    /// will return `[]` — the caller is responsible for invoking
    /// `transcribeFile(url:)` on the retained audio file after `stop()` returns.
    ///
    /// After return, the engine is idle until the next `start()`.
    func stop() async -> [TranscriptSegment]

    /// Live partial transcript while a session is active. Each emission is
    /// the *cumulative* current best-guess text, not a delta.
    var partialText: AsyncStream<String> { get }

    // MARK: Batch surface (long-form meetings)

    /// One-shot transcribe of a fixed audio buffer. Used by `MeetingRecorder`
    /// for its 30-second chunked long-form pipeline. Stateless — does not
    /// disturb a streaming session.
    func transcribe(
        audioChunk: [Float],
        chunkStartTime: TimeInterval
    ) async throws -> [TranscriptSegment]

    /// Batch-transcribe an entire audio file from disk. Used by
    /// `MeetingRecorder` for the post-meeting "re-transcribe for accuracy"
    /// pass that replaces the live streaming approximation with a canonical
    /// transcript carrying proper end-to-end timestamps.
    ///
    /// Expected file format: 16 kHz mono Float32 (the format
    /// `AudioCaptureService` writes). Other rates/channels will be downmixed
    /// + resampled by the implementation.
    func transcribeFile(url: URL) async throws -> [TranscriptSegment]

    /// Reset the speaker-detection heuristic at the start of a new dictation.
    /// Distinct from `start()` because the meeting flow does not use it.
    func resetSpeakerState()
}

// MARK: - SpeechPresenceGate
// ============================================================
// Anti-hallucination gate for the finalize path.
//
// Whisper/Parakeet-family ASR models notoriously emit phantom phrases on
// non-speech audio (silence, breathing, room tone): "Thank you.",
// "Thanks for watching.", "you", a stray "." or "♪", repeated tokens, etc.
// The user contract is: NO speech → NO output.
//
// Two layers, both consulted from RecordingCoordinator after transcribeFile:
//   1. PRIMARY — energy/VAD gate. Uses the AUDIO-derived speech-presence
//      signal (voiced duration + peak RMS) measured during capture by
//      AudioCaptureService. If the clip carried essentially no voiced audio,
//      the transcript is dropped to empty regardless of what text the model
//      hallucinated. This is audio-based so it can't be fooled by the text.
//   2. SECONDARY — hallucination-phrase suppression. If the FINAL transcript
//      (trimmed, lowercased, depunctuated) consists ONLY of a known canonical
//      hallucination phrase AND the clip's audio energy was low/short, drop it.
//      A real short "thank you" with clear speech energy survives because the
//      suppression is gated on LOW audio energy, never on the text alone.
// ============================================================

enum SpeechPresenceGate {
    // ---- Tunable thresholds (named + commented so they're easy to tune) ----

    /// PRIMARY gate. Minimum voiced audio duration (seconds) for a clip to be
    /// considered real speech. Below this we treat the capture as silence and
    /// return empty. 0.18s ≈ a single short syllable; real one-word replies
    /// ("yes", "ok", "no") run ~200–400ms of voiced audio and clear this. Set
    /// in the 0.15–0.25s band per spec — 0.18 leans toward keeping real speech.
    static let minVoicedSeconds: Double = 0.18

    /// Minimum peak for the ordinary speech gate. Weaker recordings need
    /// sustained activity and a confident, non-phantom transcript.
    static let minPeakRMS: Float = 0.004

    private static let quietMinSeconds: Double = 0.30
    private static let quietMinPeakRMS: Float = 0.0025
    private static let quietMinConfidence: Float = 0.8

    /// SECONDARY gate. Hallucination-phrase suppression only fires when voiced
    /// duration is below this. Above it, the clip clearly contained speech, so
    /// even a literal "thank you" is treated as a real utterance and kept.
    /// Higher than minVoicedSeconds: a genuine short "thank you" is ~0.4–0.7s,
    /// so 0.9s gives real speech comfortable headroom to survive.
    static let hallucinationMaxVoicedSeconds: Double = 0.9

    /// Hallucination phrases are only dropped when the clip is also quiet.
    /// Real speech measured 0.024-0.042 peak; a real short "yeah" at 0.0134 was
    /// wrongly dropped, so the energy check below keeps anything clearly voiced.
    static let hallucinationMaxPeakRMS: Float = 0.010

    /// Canonical Whisper/Parakeet hallucination outputs, normalized
    /// (lowercased, depunctuated, whitespace-collapsed). If the entire
    /// transcript reduces to exactly one of these AND audio energy was low,
    /// it's dropped. Keep this list tight — only phrases that are (a) common
    /// model artifacts and (b) implausible as a real standalone dictation.
    static let hallucinationPhrases: Set<String> = [
        "",                         // empty after depunctuation (lone "." / "♪" / "...")
        "you",
        "thank you",
        "thanks",
        "thank you very much",
        "thanks for watching",
        "thank you for watching",
        "thanks for watching the video",
        "please subscribe",
        "please subscribe to my channel",
        "subscribe",
        "like and subscribe",
        "bye",
        "bye bye",
        "okay",
        "so",
        "yeah",
        "hmm",
        "uh",
        "um",
        "music",          // bracketed cues like "[Music]" / "♪" collapse to this
        "applause",       // "[Applause]"
        "silence",        // "[silence]" / "(silence)"
        "transcribed by",
    ]

    /// Normalize transcript text for hallucination matching: lowercase, strip
    /// everything that isn't a letter/number/space (drops punctuation, "♪",
    /// bracket cues' brackets), collapse whitespace, trim. "[Music] ♪" → "music",
    /// "Thank you." → "thank you", "..." → "".
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        var lastWasSpace = true  // start true so leading space is dropped
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if ch.isWhitespace || ch == "_" {
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
            }
            // all other chars (punctuation, ♪, brackets, etc.) are dropped
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Decide whether to KEEP the transcript given the audio-derived
    /// speech-presence signal. Returns nil to keep, or a short reason string to
    /// DROP (used for logging). `joinedText` is the full assembled transcript.
    static func dropReason(joinedText: String,
                           voicedSeconds: Double,
                           peakRMS: Float,
                           quietVoicedSeconds: Double = 0,
                           recognitionConfidence: Float? = nil,
                           mediaPlaying: Bool = false) -> String? {
        if voicedSeconds < minVoicedSeconds || peakRMS < minPeakRMS {
            // The ordinary cutoff can miss whispers already decoded correctly.
            // Require weak audio across multiple buffers and a confident phrase.
            if !mediaPlaying, quietVoicedSeconds >= quietMinSeconds, peakRMS >= quietMinPeakRMS,
               (recognitionConfidence ?? 0) >= quietMinConfidence {
                let text = normalize(joinedText)
                if text.split(separator: " ").count >= 2 && !hallucinationPhrases.contains(text) { return nil }
            }
            return "silent capture (voiced=\(String(format: "%.3f", voicedSeconds))s peakRMS=\(String(format: "%.4f", peakRMS)))"
        }

        // SECONDARY: low-energy clip whose entire text is a known hallucination.
        // Only when voiced audio is short — a real, energetic "thank you" passes.
        if voicedSeconds < hallucinationMaxVoicedSeconds && peakRMS < hallucinationMaxPeakRMS {
            let norm = normalize(joinedText)
            if hallucinationPhrases.contains(norm) {
                return "hallucination phrase \"\(norm)\" on low-energy clip (voiced=\(String(format: "%.3f", voicedSeconds))s)"
            }
        }
        return nil
    }

    // ---- Media-leak guard (music / video bleeding into the mic) ----

    /// MEDIA-LEAK GUARD. Only transcripts of at most this many words can be
    /// dropped. Longer dictation is never touched.
    static let mediaLeakMaxWords = 3

    /// MEDIA-LEAK GUARD. Speech share = voiced seconds / captured seconds. Below
    /// this, most of the capture was not speech, so a short transcript is likely
    /// lyrics or video dialogue leaking in. Set conservatively: continuous music
    /// keeps the share high, so this guard mainly catches brief bleed.
    static let mediaLeakMaxSpeechShare: Double = 0.25

    /// Decide whether to DROP a short transcript that is probably media bleed.
    /// Requires all of: media is playing on the default output, the transcript is
    /// at most `mediaLeakMaxWords` words, and the speech share is low. Returns a
    /// short reason for logging, or nil to keep the transcript.
    static func mediaLeakDropReason(joinedText: String,
                                    voicedSeconds: Double,
                                    capturedSeconds: Double,
                                    mediaPlaying: Bool) -> String? {
        guard mediaPlaying, capturedSeconds > 0 else { return nil }
        let words = normalize(joinedText).split(separator: " ").count
        guard words > 0, words <= mediaLeakMaxWords else { return nil }
        let share = voicedSeconds / capturedSeconds
        guard share < mediaLeakMaxSpeechShare else { return nil }
        return "media leak: \(words) word(s) at speech share \(String(format: "%.2f", share)) while media plays"
    }
}

// MARK: - TranscriptionError

enum TranscriptionError: LocalizedError {
    case notInitialized
    case modelNotFound
    case audioFormatError
    case streamingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Transcription engine not initialized. Call prepare() first."
        case .modelNotFound:
            return "Parakeet model not found. It may still be downloading."
        case .audioFormatError:
            return "Audio format error. Expected 16kHz mono Float32."
        case .streamingFailed(let msg):
            return "Streaming transcription failed: \(msg)"
        }
    }
}
