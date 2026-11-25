// VOICE — Transcription Service (FluidAudio / Parakeet TDT 0.6B v3)
// ============================================================
// Matches macparakeet's architecture exactly:
//   prepare()       — downloads + pre-warms AsrManager once at launch
//   start()         — instant: just resets state, no model loading
//   feed()          — no-op: audio is captured to file by AudioCaptureService
//   stop()          — resets state only; returns []. Caller must call transcribeFile().
//   transcribeFile() — passes URL directly to FluidAudio (fastest path, no manual
//                     resampling or [Float] intermediate). ~150ms for any length.
//
// WHY URL-based transcription:
//   manager.transcribe(url:) lets FluidAudio handle file reading, format conversion,
//   and chunking internally. Passing [Float] requires manual resampling + a large
//   array copy across the actor boundary. The URL path is what macparakeet uses.
//
// WHY no accumulation in feed():
//   AudioCaptureService already writes captured 16kHz mono PCM to a .caf file
//   (via startWritingToFile). RecordingCoordinator calls transcribeFile(url:) on
//   that file after stop(). No double-buffering needed.
// ============================================================

import Foundation
import AVFoundation
import FluidAudio

@Observable
final class TranscriptionService: TranscriptionEngine {
    // MARK: - Public state

    var modelState: ModelState = .notDownloaded
    var isReady = false
    var lastError: String?
    private(set) var activeModelID: SpeechModelID?

    // MARK: - Partial-text stream

    /// Each emission is the cumulative best-guess transcript so far (not a delta).
    let partialText: AsyncStream<String>
    private let partialContinuation: AsyncStream<String>.Continuation

    // MARK: - FluidAudio handles

    /// Exposed so RecordingCoordinator can share the already-loaded models
    /// with SlidingWindowAsrManager for the live-partials path. The models
    /// are safe to share — they're read-only after loadModels().
    private(set) var asrModels: AsrModels?

    /// Single pre-warmed batch engine reused for all transcription calls.
    /// loadModels() runs once at prepare() — CoreML compiles once, all subsequent
    /// calls reuse the compiled model cache.
    private var batchManager: AsrManager?
    private var batchDecoderLayerCount: Int = 0
    private let workLock = NSLock()
    private var activeTranscriptions = 0
    private var _lastVocabularyBoost: ASRVocabularyBoost.Report?

    /// What acoustic vocabulary boosting did on the latest `transcribeFile`
    /// (nil when boosting was off). Read by the replay harness.
    var lastVocabularyBoost: ASRVocabularyBoost.Report? {
        workLock.lock(); defer { workLock.unlock() }
        return _lastVocabularyBoost
    }

    /// `voice.asrVocabularyBoost`, overridable per instance (replay harness).
    var vocabularyBoostOverride: Bool?

    var hasInFlightTranscription: Bool {
        workLock.lock(); defer { workLock.unlock() }
        return activeTranscriptions > 0
    }

    private func claimDecoder() throws -> (manager: AsrManager, layers: Int) {
        workLock.lock(); defer { workLock.unlock() }
        guard let manager = batchManager else { throw TranscriptionError.notInitialized }
        activeTranscriptions += 1
        return (manager, batchDecoderLayerCount)
    }

    private func releaseDecoder() {
        workLock.lock()
        activeTranscriptions -= 1
        let idle = activeTranscriptions == 0
        workLock.unlock()
        if idle {
            NotificationCenter.default.post(name: Notification.Name("voice.speechDecoderIdle"), object: self)
        }
    }
    private let preparationLock = NSLock()
    private var preparation: (id: UUID, task: Task<Void, Error>)?

    // MARK: - Session state

    private var sessionStart: Date?

    // MARK: - Init / deinit

    init() {
        var continuation: AsyncStream<String>.Continuation!
        self.partialText = AsyncStream { continuation = $0 }
        self.partialContinuation = continuation
    }

    deinit {
        partialContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Download (if needed) and load Parakeet TDT 0.6B v3. Called once at launch.
    /// Awaiting callers share a preparation. Cancelling a caller does not cancel
    /// the shared load; that caller receives cancellation after it finishes.
    func prepare() async throws {
        try Task.checkCancellation()
        guard let task = sharedPreparation() else { return }
        do {
            try await task.value
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
    }

    private func sharedPreparation() -> Task<Void, Error>? {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if isReady { return nil }
        if let preparation { return preparation.task }
        let id = UUID()
        let task = Task { [self] in
            defer { finishPreparation(id: id) }
            try await prepareOnce()
        }
        preparation = (id, task)
        return task
    }

    private func finishPreparation(id: UUID) {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if preparation?.id == id { preparation = nil }
    }

    @MainActor private func prepareOnce() async throws {
        modelState = .loading
        lastError = nil
        do {
            let requested = UserDefaults.standard.string(forKey: SpeechModelSelection.preferenceKey)
                .flatMap(SpeechModelID.init(rawValue:)) ?? .parakeetV3
            let desired = SpeechModelCatalog.descriptor(for: requested)
            let descriptor = SpeechModelLoader.artifactsPresent(desired)
                ? desired : SpeechModelCatalog.descriptor(for: .parakeetV3)
            let prepared = try await SpeechModelLoader.prepare(descriptor)
            guard installPreparedModel(prepared) else { throw TranscriptionError.notInitialized }
            if vocabularyBoostOverride ?? ASRVocabularyBoost.isEnabled {
                Task.detached(priority: .utility) { await ASRVocabularyBooster.shared.prewarm() }
            }
        } catch {
            modelState = .error("Speech model unavailable")
            lastError = "Speech model unavailable"
            throw error
        }
    }

    @MainActor @discardableResult
    func installPreparedModel(_ prepared: SpeechModelLoader.Prepared) -> Bool {
        workLock.lock()
        guard activeTranscriptions == 0 else { workLock.unlock(); return false }
        asrModels = prepared.models
        batchManager = prepared.manager
        batchDecoderLayerCount = prepared.decoderLayers
        activeModelID = prepared.id
        workLock.unlock()
        isReady = true
        modelState = .ready
        lastError = nil
        return true
    }

    // MARK: - Dictation surface

    /// Begin a new dictation session. Returns immediately — no model loading.
    func start() async throws {
        guard batchManager != nil else {
            print("[VOICE-TS] start() FAILED — batchManager nil (model not loaded)")
            throw TranscriptionError.notInitialized
        }
        sessionStart = Date()
        print("[VOICE-TS] start() OK — session marked at \(sessionStart!) (isReady=\(isReady))")
    }

    /// No-op. Audio is captured to file by AudioCaptureService; call transcribeFile() at stop.
    func feed(samples: [Float]) async { }

    /// Resets session state. Actual transcription happens in transcribeFile(url:).
    /// RecordingCoordinator calls transcribeFile on the retained audio file after this.
    func stop() async -> [TranscriptSegment] {
        print("[VOICE] stop() — session ended, caller will transcribeFile()")
        sessionStart = nil
        return []
    }

    // MARK: - Speaker state (no-op — single-speaker app)

    func resetSpeakerState() { }

    // MARK: - Batch surface (unused — MeetingRecorder not wired)

    func transcribe(
        audioChunk: [Float],
        chunkStartTime: TimeInterval
    ) async throws -> [TranscriptSegment] {
        // Write the raw Float32 PCM chunk to a temp .caf file, then hand it
        // to the existing transcribeFile() path. This is the same approach
        // AudioCaptureService uses — FluidAudio works best with file URLs.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-meeting-chunk-\(UUID().uuidString).caf")

        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.notInitialized
        }

        // Write the [Float] samples into an AVAudioPCMBuffer and save to disk.
        let frameCount = AVAudioFrameCount(audioChunk.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscriptionError.notInitialized
        }
        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData {
            audioChunk.withUnsafeBufferPointer { ptr in
                channelData[0].initialize(from: ptr.baseAddress!, count: audioChunk.count)
            }
        }

        let audioFile = try AVAudioFile(forWriting: tmpURL, settings: format.settings)
        try audioFile.write(from: buffer)

        // Transcribe via the real file path.
        var segments = try await transcribeFile(url: tmpURL)

        // Offset segment timestamps relative to the meeting session start.
        for i in segments.indices {
            segments[i].startTime += chunkStartTime
            segments[i].endTime   += chunkStartTime
        }

        return segments
    }

    // MARK: - File transcription (primary path for dictation + crash recovery)

    /// Transcribe an audio file. For audio that fits in a single Parakeet
    /// decode window (≤15 s @ 16 kHz) we hand the URL to FluidAudio unchanged
    /// — same code path as before. For longer audio we take the chunking
    /// into our own hands to side-step a boundary-merge bug in FluidAudio's
    /// `ChunkProcessor.mergeByMidpoint` (see VOICE-MERGE comment below).
    func transcribeFile(url: URL) async throws -> [TranscriptSegment] {
        let lease = try claimDecoder()
        defer { releaseDecoder() }
        let manager = lease.manager

        let t0 = Date()
        print("[VOICE-TS] transcribeFile() ENTER — \(url.lastPathComponent) at \(t0)")

        // ============================================================
        // [VOICE-MERGE] Chunk-boundary fix
        // ------------------------------------------------------------
        // FluidAudio v3's ChunkProcessor splits long audio into ~14.96s
        // windows with 2.0s overlap, decodes each chunk with a FRESH
        // decoder state (state.reset()), then attempts to merge the
        // overlapping token streams. When the two decodings of the same
        // boundary audio disagree (which is common — the chunk whose
        // window has the boundary AT THE EDGE has less acoustic context
        // and tends to mis-decode), the merge falls through to
        // `mergeByMidpoint`, which splits on TIMESTAMP alone and just
        // happens to drop the higher-context decoding. The user-visible
        // failure: tail-of-chunk-N text is *lost* AND the head-of-chunk-
        // (N+1) text appears mutated.
        //
        // Fix (strategy: drive chunking ourselves, prefer higher-
        // confidence decoding at boundaries):
        //   1. Read the audio file into a [Float] at 16 kHz.
        //   2. If the whole recording fits in one ~15s Parakeet window,
        //      ask FluidAudio for a single-shot decode — no chunking, no
        //      boundary at all. This eliminates the bug for typical
        //      dictation lengths.
        //   3. If it's longer, chunk it ourselves into ≤14.5 s windows
        //      with a 2.0 s overlap and call `manager.transcribe(samples)`
        //      on each. Each chunk stays at-or-below maxModelSamples so
        //      FluidAudio routes to its single-decode path internally —
        //      ChunkProcessor.mergeByMidpoint never runs. We then merge
        //      the per-chunk text by suffix/prefix overlap and pick the
        //      higher-confidence span at the seam.
        //
        // Trade-off: this loses FluidAudio's internal token-level dedup
        // and gets a string-level merge instead — but it eliminates the
        // class of bug where a mis-decoded boundary stomps a correct one.
        // ============================================================
        let samples: [Float]
        let tReadStart = CFAbsoluteTimeGetCurrent()
        do {
            samples = try Self.readSamplesAt16kMono(url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AudioReadError {
            throw error
        } catch {
            print("[VOICE-TS] readSamplesAt16kMono FAILED: \(error.localizedDescription)")
            throw error
        }
        let readMs = (CFAbsoluteTimeGetCurrent() - tReadStart) * 1000
        fputs("[LATENCY] ASR file-read→[Float] (\(samples.count) samples): \(Int(readMs))ms\n", stderr)
        let tDecodeStart = CFAbsoluteTimeGetCurrent()

        let maxModelSamples = 240_000              // 15s @ 16kHz (FluidAudio limit)
        let safeChunkSamples = 232_000             // ~14.5s — leaves margin under the model cap
        let overlapSamples   = 32_000              //  2.0s overlap, matches FluidAudio's ChunkProcessor

        let boost = vocabularyBoostOverride ?? ASRVocabularyBoost.isEnabled
        var boostReports: [ASRVocabularyBoost.Report] = []
        let result: ASRResult
        do {
            if samples.count <= maxModelSamples {
                // === Path A: single-shot decode — bug-free by construction ===
                print("[VOICE-MERGE] single-shot decode: \(samples.count) samples (≤ \(maxModelSamples))")
                var decoderState = TdtDecoderState.make(decoderLayers: lease.layers)
                let decoded = try await manager.transcribe(samples, decoderState: &decoderState, language: nil)
                if boost {
                    let report = await ASRVocabularyBooster.shared.rescore(
                        text: decoded.text, tokenTimings: decoded.tokenTimings, samples: samples)
                    boostReports.append(report)
                    result = Self.replacingText(of: decoded, with: report)
                } else {
                    result = decoded
                }
            } else {
                // === Path B: manual chunked decode with text-level merge ===
                print("[VOICE-MERGE] chunked decode: \(samples.count) samples → ~\(samples.count / (safeChunkSamples - overlapSamples) + 1) chunks of \(safeChunkSamples) (overlap \(overlapSamples))")
                result = try await Self.chunkedTranscribe(
                    samples: samples,
                    manager: manager,
                    decoderLayers: lease.layers,
                    chunkSamples: safeChunkSamples,
                    overlapSamples: overlapSamples,
                    sampleRate: 16_000,
                    boost: boost ? { chunk, decoded in
                        let report = await ASRVocabularyBooster.shared.rescore(
                            text: decoded.text, tokenTimings: decoded.tokenTimings, samples: chunk)
                        return report
                    } : nil,
                    reports: &boostReports
                )
            }
        } catch {
            print("[VOICE-TS] transcribeFile THREW: \(error)")
            throw error
        }

        let decodeMs = (CFAbsoluteTimeGetCurrent() - tDecodeStart) * 1000
        fputs("[LATENCY] ASR decode (Parakeet inference): \(Int(decodeMs))ms\n", stderr)
        let boostReport: ASRVocabularyBoost.Report? = boost ? ASRVocabularyBoost.Report(
            unboostedText: boostReports.map(\.unboostedText).joined(separator: " | "),
            boostedText: result.text,
            replacements: boostReports.flatMap(\.replacements),
            ctcRan: boostReports.contains(where: \.ctcRan),
            milliseconds: boostReports.reduce(0) { $0 + $1.milliseconds },
            rejected: boostReports.flatMap(\.rejected)) : nil
        workLock.lock(); _lastVocabularyBoost = boostReport; workLock.unlock()
        if let boostReport, !boostReport.replacements.isEmpty {
            print("[VOICE-VOCAB] boosted \(boostReport.replacements.count) span(s) in \(Int(boostReport.milliseconds))ms")
        }
        let trimmed = result.text.trimmingCharacters(in: .whitespaces)
        let elapsed = Date().timeIntervalSince(t0)
        print("[VOICE-TS] transcribeFile() OK → (\(trimmed.count) chars) in \(String(format: "%.2f", elapsed))s")

        guard !trimmed.isEmpty else {
            print("[VOICE-TS] transcribeFile → empty text, returning []")
            return []
        }

        // Extract suspect words from per-token confidence. FluidAudio's
        // `ASRResult.tokenTimings` carries per-token confidence (0..1). We
        // surface tokens below 0.65 to the polish layer as "suspect" — the
        // LLM gets to double-check spelling / word choice on those.
        // Join subword pieces using the decoder's explicit word boundaries.
        // FluidAudio can return a leading space instead of SentencePiece's
        // word-start marker. If no timings are available,
        // suspectWords is nil and the polisher gets no hint.
        let suspectWords: [String]? = Self.extractSuspectWords(
            from: result.tokenTimings,
            confidenceThreshold: 0.65
        )
        if let suspectWords, !suspectWords.isEmpty {
            print("[VOICE-TS] low-confidence words: \(suspectWords.count)")
        }

        // Section F (merge correctness): aggregate per-token confidence into
        // a single segment-level confidence value. Used downstream by
        // Qwen3Polisher.mergeWithMLX to pick the higher-confidence span when
        // two transcripts disagree. Falls back to `result.confidence` (the
        // ASR's own overall score) when token timings are unavailable.
        let segmentConfidence: Float
        if let timings = result.tokenTimings, !timings.isEmpty {
            let total = timings.reduce(Float(0)) { $0 + $1.confidence }
            segmentConfidence = total / Float(timings.count)
        } else {
            segmentConfidence = result.confidence
        }

        return [
            TranscriptSegment(
                speaker: "Speaker 1",
                text: trimmed,
                startTime: 0,
                endTime: result.duration,
                confidence: segmentConfidence,
                suspectWords: suspectWords,
                wordConfidences: Self.wordConfidences(from: result.tokenTimings)
            )
        ]
    }

    /// Words from the decoder's pieces, each with the lowest confidence of its pieces and its time span.
    static func wordConfidences(from timings: [TokenTiming]?) -> [ASRWordConfidence]? {
        guard let timings, !timings.isEmpty else { return nil }
        var words: [ASRWordConfidence] = []
        var current = "", low: Float = 1, start: Double?, end: Double?
        func flush() {
            let word = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty {
                words.append(ASRWordConfidence(word: word, confidence: (low * 1000).rounded() / 1000,
                                               start: start.map { ($0 * 100).rounded() / 100 },
                                               end: end.map { ($0 * 100).rounded() / 100 }))
            }
            current = ""; low = 1; start = nil; end = nil
        }
        for timing in timings {
            let piece = timing.token
            if piece.hasPrefix("\u{2581}") || piece.first?.isWhitespace == true { flush() }
            current += piece.drop(while: { $0 == "\u{2581}" || $0.isWhitespace })
            if timing.confidence.isFinite, (0...1).contains(timing.confidence) { low = min(low, timing.confidence) }
            if start == nil { start = timing.startTime }
            end = timing.endTime
        }
        flush()
        return words.isEmpty ? nil : words
    }

    // MARK: - Boundary-fix helpers (see [VOICE-MERGE] block above)

    /// Legacy fallback path — exactly the pre-fix behaviour. Only invoked
    /// when our own audio-file reader can't decode the file. Keeps Voice
    /// resilient on weird inputs (e.g. orphan recovery on a half-written
    /// .caf where the AVAudioFile path errors out).
    private func transcribeFile_legacyURL(
        url: URL,
        manager: AsrManager,
        t0: Date
    ) async throws -> [TranscriptSegment] {
        var decoderState = TdtDecoderState.make(decoderLayers: batchDecoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &decoderState, language: nil)
        let trimmed = result.text.trimmingCharacters(in: .whitespaces)
        let elapsed = Date().timeIntervalSince(t0)
        print("[VOICE-TS] transcribeFile() OK (legacy URL path) → (\(trimmed.count) chars) in \(String(format: "%.2f", elapsed))s")
        guard !trimmed.isEmpty else { return [] }
        return [TranscriptSegment(
            speaker: "Speaker 1",
            text: trimmed,
            startTime: 0,
            endTime: result.duration,
            confidence: result.confidence,
            suspectWords: nil
        )]
    }

    /// Hard limit bounds the retained 16 kHz Float array to about 660 MiB.
    /// Source audio is never deleted when conversion is refused.
    static let maxAudioDurationSeconds: Double = 3 * 60 * 60

    enum AudioReadError: LocalizedError {
        case invalidFormat
        case tooLong
        case conversionFailed
        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "Couldn't read this audio format. Your audio is still saved."
            case .tooLong: return "This recording is over 3 hours. Your audio is still saved."
            case .conversionFailed: return "Couldn't convert this recording. Your audio is still saved."
            }
        }
    }

    static func validateAudioLength(_ file: AVAudioFile) throws -> Int {
        try validateAudioMetadata(frameCount: file.length, sampleRate: file.processingFormat.sampleRate,
                                  channels: file.processingFormat.channelCount)
    }

    static func validateAudioMetadata(frameCount: Int64, sampleRate rate: Double, channels: UInt32) throws -> Int {
        guard rate.isFinite, (1_000...384_000).contains(rate),
              (1...32).contains(channels), frameCount >= 0 else { throw AudioReadError.invalidFormat }
        let seconds = Double(frameCount) / rate
        guard seconds.isFinite, seconds <= maxAudioDurationSeconds else { throw AudioReadError.tooLong }
        return Int((seconds * 16_000).rounded(.up))
    }

    /// Decode in bounded input/output blocks. Only the final mono array grows
    /// with duration; no full-size source or conversion buffer is allocated.
    static func readSamplesAt16kMono(url: URL, useNativeCAF: Bool = true) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let estimated = try validateAudioLength(file)
        let inputFormat = file.processingFormat
        if useNativeCAF, estimated > 0, isNativeCaptureCAF(url: url, file: file) {
            return try readNativeCaptureCAF(file, frameCount: estimated)
        }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000, channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192)
        else { throw AudioReadError.invalidFormat }

        let maxSamples = Int(maxAudioDurationSeconds * 16_000)
        var samples = [Float]()
        samples.reserveCapacity(estimated)
        var eof = false
        var readError: Error?
        while true {
            try Task.checkCancellation()
            output.frameLength = 0
            let previousPosition = file.framePosition
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                if eof || file.framePosition >= file.length {
                    eof = true
                    state.pointee = .endOfStream
                    return nil
                }
                input.frameLength = 0
                do {
                    let remaining = AVAudioFrameCount(min(Int64(input.frameCapacity), file.length - file.framePosition))
                    try file.read(into: input, frameCount: min(requested, remaining))
                } catch {
                    readError = error
                    eof = true
                    state.pointee = .endOfStream
                    return nil
                }
                guard input.frameLength > 0 else {
                    eof = true
                    state.pointee = .endOfStream
                    return nil
                }
                state.pointee = .haveData
                return input
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if status == .error { throw AudioReadError.conversionFailed }
            let count = Int(output.frameLength)
            guard samples.count <= maxSamples - count else { throw AudioReadError.tooLong }
            if count > 0 {
                guard let channel = output.floatChannelData?[0] else { throw AudioReadError.invalidFormat }
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
            }
            if status == .endOfStream { break }
            // Avoid spinning forever if the converter cannot make progress.
            if count == 0 && (eof || file.framePosition == previousPosition) { throw AudioReadError.conversionFailed }
        }
        return samples
    }

    static func isNativeCaptureCAF(url: URL, file: AVAudioFile) -> Bool {
        let source = file.fileFormat
        let processing = file.processingFormat
        // Core Audio can report an interleaved on-disk layout for a mono CAF.
        // The buffer handed back by AVAudioFile must be exactly the ASR format.
        return url.pathExtension.lowercased() == "caf"
            && source.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM
            && source.commonFormat == .pcmFormatFloat32
            && source.sampleRate == 16_000
            && source.channelCount == 1
            && processing.commonFormat == .pcmFormatFloat32
            && processing.sampleRate == 16_000
            && processing.channelCount == 1
            && !processing.isInterleaved
    }

    private static func readNativeCaptureCAF(_ file: AVAudioFile, frameCount: Int) throws -> [Float] {
        guard let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384),
              let channel = block.floatChannelData?[0] else { throw AudioReadError.invalidFormat }
        var samples = [Float]()
        samples.reserveCapacity(frameCount)
        while samples.count < frameCount {
            try Task.checkCancellation()
            let remaining = min(Int(block.frameCapacity), frameCount - samples.count)
            let previousPosition = file.framePosition
            block.frameLength = 0
            try file.read(into: block, frameCount: AVAudioFrameCount(remaining))
            let count = Int(block.frameLength)
            if count == 0 { break }
            guard count <= remaining, file.framePosition > previousPosition else { throw AudioReadError.conversionFailed }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        }
        return samples
    }

    /// Chunk a long sample array into ~14.5 s windows with 2 s overlap,
    /// decode each via the single-shot path (`manager.transcribe(samples)`
    /// stays ≤ maxModelSamples so it bypasses ChunkProcessor entirely),
    /// then string-merge the per-chunk outputs using confidence-weighted
    /// overlap dedup at each seam.
    ///
    /// Each `manager.transcribe(samples:)` call uses a FRESH decoder state.
    /// We accept slight intra-chunk LM context loss (the boundary words get
    /// fresh state) in exchange for not relying on FluidAudio's broken
    /// token-window merger.
    private static func chunkedTranscribe(
        samples: [Float],
        manager: AsrManager,
        decoderLayers: Int,
        chunkSamples: Int,
        overlapSamples: Int,
        sampleRate: Int,
        boost: (([Float], ASRResult) async -> ASRVocabularyBoost.Report)? = nil,
        reports: inout [ASRVocabularyBoost.Report]
    ) async throws -> ASRResult {
        precondition(chunkSamples > overlapSamples * 2, "chunk must be more than 2× overlap")

        struct ChunkOut {
            let index: Int
            let text: String
            let confidence: Float
            let timings: [TokenTiming]?
            let trailingOverlapHasSignal: Bool
        }

        var outputs: [ChunkOut] = []
        var chunkStart = 0
        var idx = 0
        var silentWindows = 0
        let stride = chunkSamples - overlapSamples

        while chunkStart < samples.count {
            try Task.checkCancellation()
            let end = min(chunkStart + chunkSamples, samples.count)
            if !hasAcousticSignal(samples[chunkStart..<end]) {
                silentWindows += 1
                if end == samples.count { break }
                chunkStart += stride
                idx += 1
                continue
            }
            // Array(samples[chunkStart..<end]) goes through the Sequence
            // initialiser — element-by-element copy. unsafeUninitializedCapacity
            // + memcpy is a single bulk copy per chunk. For multi-chunk audio
            // this is hot — every saved alloc matters.
            let sliceCount = end - chunkStart
            let slice: [Float] = samples.withUnsafeBufferPointer { src in
                [Float](unsafeUninitializedCapacity: sliceCount) { dest, initCount in
                    memcpy(dest.baseAddress!, src.baseAddress! + chunkStart, sliceCount * MemoryLayout<Float>.stride)
                    initCount = sliceCount
                }
            }
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            // FluidAudio requires ≥ minimumRequiredSamples; pad final tiny tail.
            let minSamples = sampleRate / 4 // 250ms
            let toDecode: [Float]
            if slice.count < minSamples {
                // Tail too short by itself — fold it into the previous chunk
                // by extending the previous decoder's range. Since we already
                // emitted the previous chunk, just drop this tail; the prior
                // chunk's overlap should already cover it. (overlapSamples ≥
                // this floor.)
                print("[VOICE-MERGE] chunk \(idx) tail <250ms, skipping (covered by prior overlap)")
                break
            } else {
                toDecode = slice
            }

            var r = try await manager.transcribe(toDecode, decoderState: &decoderState, language: nil)
            try Task.checkCancellation()
            // Vocabulary boosting runs per window, before the seam merge, so the
            // token timings stay on the window's own clock.
            if let boost {
                let report = await boost(toDecode, r)
                reports.append(report)
                r = replacingText(of: r, with: report)
            }
            let txt = r.text.trimmingCharacters(in: .whitespaces)
            print("[VOICE-MERGE] chunk \(idx) start=\(chunkStart) len=\(slice.count) conf=\(String(format: "%.3f", r.confidence))")
            if !txt.isEmpty {
                outputs.append(ChunkOut(
                    index: idx,
                    text: txt,
                    confidence: r.confidence,
                    timings: r.tokenTimings,
                    trailingOverlapHasSignal: hasAcousticSignal(samples[max(end - overlapSamples, chunkStart)..<end])
                ))
            }
            if end == samples.count { break }
            chunkStart += stride
            idx += 1
        }
        if silentWindows > 0 { print("[VOICE-MERGE] skipped \(silentWindows) digital-silence windows") }

        // Deduplicate text only across adjacent, overlapping windows that
        // actually share audio. Repeated words across a pause can both be real.
        guard !outputs.isEmpty else {
            return ASRResult(text: "", confidence: 0, duration: 0, processingTime: 0, tokenTimings: nil)
        }
        var merged = outputs[0].text
        var mergedConf = outputs[0].confidence
        var allTimings: [TokenTiming] = outputs[0].timings ?? []
        let overlapWordBudget = 10 // 2s overlap ≈ 6-8 words at normal speech; 10 caps false-positive risk

        for i in 1..<outputs.count {
            let previous = outputs[i - 1]
            let r = outputs[i]
            let previousWordCount = previous.text.split(separator: " ", maxSplits: overlapWordBudget).count
            let (joined, keptSide) = mergeChunkBoundary(
                left: merged,
                right: r.text,
                leftConf: previous.confidence,
                rightConf: r.confidence,
                maxWords: min(overlapWordBudget, previousWordCount),
                sharesAudio: r.index == previous.index + 1 && previous.trailingOverlapHasSignal
            )
            merged = joined
            mergedConf = max(mergedConf, r.confidence)
            if let t = r.timings { allTimings.append(contentsOf: t) }
            print("[VOICE-MERGE] chunk \(previous.index)-\(r.index) boundary: kept=\(keptSide) confL=\(String(format: "%.3f", previous.confidence)) confR=\(String(format: "%.3f", r.confidence))")
        }

        let totalDur = TimeInterval(samples.count) / TimeInterval(sampleRate)
        return ASRResult(
            text: merged,
            confidence: mergedConf,
            duration: totalDur,
            processingTime: 0,
            tokenTimings: allTimings.isEmpty ? nil : allTimings
        )
    }

    /// Only exact digital silence can be skipped. A faint whisper still goes to the decoder.
    static func hasAcousticSignal(_ samples: ArraySlice<Float>) -> Bool {
        samples.contains { $0 != 0 }
    }

    /// The decode with its text replaced by the boosted text (timings kept).
    static func replacingText(of result: ASRResult, with report: ASRVocabularyBoost.Report) -> ASRResult {
        guard report.boostedText != report.unboostedText else { return result }
        return ASRResult(text: report.boostedText, confidence: result.confidence, duration: result.duration,
                         processingTime: result.processingTime, tokenTimings: result.tokenTimings)
    }

    /// Merge two chunk transcripts by finding the longest word-level overlap
    /// at the L-suffix / R-prefix seam. The higher-confidence side's copy of
    /// the overlap region wins. Returns the merged string and a tag for
    /// which side was preferred ("left", "right", or "none" when no overlap
    /// was detected).
    static func mergeChunkBoundary(
        left: String,
        right: String,
        leftConf: Float,
        rightConf: Float,
        maxWords: Int,
        sharesAudio: Bool
    ) -> (String, String) {
        guard sharesAudio else { return (left + " " + right, "none") }
        let lWords = left.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let rWords = right.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !lWords.isEmpty, !rWords.isEmpty else {
            return ((left + " " + right).trimmingCharacters(in: .whitespaces), "none")
        }

        // Look for the longest k such that lWords.suffix(k) ≈ rWords.prefix(k)
        // — case-insensitive, punctuation-stripped match. We scan k from the
        // budget down so the first hit is the longest.
        let maxK = min(maxWords, lWords.count, rWords.count)
        let punct = CharacterSet.punctuationCharacters
        // Pre-normalize the L-tail and R-head ONCE. The previous implementation
        // re-normalized the same words on every k iteration (O(maxK²) string
        // work). One pass is O(maxK).
        let lTailNorm: [String] = lWords.suffix(maxK).map { $0.lowercased().trimmingCharacters(in: punct) }
        let rHeadNorm: [String] = rWords.prefix(maxK).map { $0.lowercased().trimmingCharacters(in: punct) }
        var bestK = 0
        let requireMatches = 2 // at least 2 consecutive matching words to declare overlap
        for k in stride(from: maxK, through: requireMatches, by: -1) {
            // Slice the pre-normalized prefix/suffix without re-normalizing.
            // For the L tail of size k we want the last k entries of lTailNorm.
            let lStart = lTailNorm.count - k
            // Allow a small mismatch tolerance: require ≥ 60 % matches AND
            // first + last token to match. This handles the case where the
            // boundary words mis-decoded ("trade" vs "treat") but the rest
            // of the overlap is intact.
            var hits = 0
            for j in 0..<k where lTailNorm[lStart + j] == rHeadNorm[j] { hits += 1 }
            let ratio = Double(hits) / Double(k)
            // Tighter guard: ≥75% word match AND first AND last word of the
            // window agree. Raising from 60% + first-only prevents false-
            // positive overlaps from eating non-overlap content at the seam.
            if ratio >= 0.75
                && lTailNorm[lStart] == rHeadNorm[0]
                && lTailNorm[lStart + k - 1] == rHeadNorm[k - 1] {
                bestK = k
                break
            }
        }

        if bestK == 0 {
            // No detectable overlap. Just concatenate with a space.
            return ((left + " " + right).trimmingCharacters(in: .whitespaces), "none")
        }

        // Pick the higher-confidence side's copy of the overlap region.
        if leftConf >= rightConf {
            // Keep L's overlap; drop R's prefix-of-bestK and append the rest.
            let rTail = Array(rWords.dropFirst(bestK))
            let merged = (lWords + rTail).joined(separator: " ")
            return (merged, "left")
        } else {
            // Keep R's overlap; drop L's suffix-of-bestK and append R as-is.
            let lHead = Array(lWords.dropLast(bestK))
            let merged = (lHead + rWords).joined(separator: " ")
            return (merged, "right")
        }
    }

    /// Return up to 16 distinct uncertain words from recognition timings.
    /// Punctuation alone does not indicate uncertainty about a spoken word.
    static func extractSuspectWords(
        from timings: [TokenTiming]?,
        confidenceThreshold: Float
    ) -> [String]? {
        guard let timings, !timings.isEmpty else { return nil }

        let wordStartMarker = "\u{2581}"
        var currentWord = ""
        var currentMin: Float = .greatestFiniteMagnitude
        var seen = Set<String>()
        var suspect: [String] = []

        func flush() {
            let word = currentWord.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentMin < confidenceThreshold, !word.isEmpty, seen.insert(word.lowercased()).inserted {
                suspect.append(word)
            }
            currentWord.removeAll(keepingCapacity: true)
            currentMin = .greatestFiniteMagnitude
        }

        for timing in timings {
            let piece = timing.token
            if piece.hasPrefix(wordStartMarker) || piece.first?.isWhitespace == true {
                flush()
                if suspect.count == 16 { return suspect }
            }
            let content = piece.drop(while: { $0 == "▁" || $0.isWhitespace })
            currentWord += content
            if content.contains(where: { $0.isLetter || $0.isNumber }),
               timing.confidence.isFinite, (0...1).contains(timing.confidence) {
                currentMin = min(currentMin, timing.confidence)
            }
        }
        flush()
        return suspect.isEmpty ? nil : suspect
    }
}
