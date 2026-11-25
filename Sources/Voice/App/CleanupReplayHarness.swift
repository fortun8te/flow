// Flow — headless production replay for the S1-mini post-training data
// ============================================================
//   Flow --cleanup-prepare CONFIG.json   saved audio → exact S1 inputs (prepared.jsonl)
//   Flow --cleanup-run     CONFIG.json   stored S1 inputs → Flow's final text (stock.jsonl)
//
//   capture DSP      CaptureDSP (the struct AudioCaptureService runs per tap buffer)
//   .caf + sizes     same settings and lead/trail padding as startWritingToFile /
//                    stopWritingToFile; the 20,000 / 36,000-byte rules of stopRecording
//   ASR              TranscriptionService.transcribeFile (own 14.5 s chunker), selected model
//   presence gate    SpeechPresenceGate (media playing = false)
//   text prep        DictationTextPreparation.prepare (TextFormatter, stop word, press enter)
//   cleanup          Qwen3Polisher.polish with the live finish task's parameters, observed
//                    through ShadowCleanupObserver, then DictationTextPreparation.finalize
//
// No UI, pill, sounds, paste, clipboard, history rows or event log. Cloud cleanup is
// forced off and privacy mode on for the process (volatile argument domain). Runs
// sequentially under nice 10, appends one JSON line per item, skips ids already done
// and logs progress to stderr.
// ============================================================

import AVFoundation
import Accelerate
import Darwin
import Foundation

@MainActor
enum CleanupReplayHarness {
    // MARK: Configuration

    struct PrepareConfiguration: Decodable {
        let input: String
        let output: String
        /// Process at most this many pending clips (for spot checks).
        let limit: Int?
        /// Small proofs only (limit ≤ 5): run beside a Flow that holds the backend lock.
        let allowWhileFlowRunning: Bool?
        /// ASR measurement only: no cleanup model is loaded and each clip is decoded with
        /// vocabulary boosting off and on (`parakeet_raw` / `parakeet_boosted`). Light enough
        /// to run beside Flow for up to `maximumConcurrentASRClips` clips.
        let asrOnly: Bool?
        /// Experiment overrides for `voice.asrVocabularyBoostCbw` / `...MinSimilarity` (this process only).
        let boostCbw: Double?
        let boostMinSimilarity: Double?
        /// Replaces the trusted term list for this process (`userProperNouns`; dictionary cleared).
        let boostTerms: [String]?

        enum CodingKeys: String, CodingKey {
            case input, output, limit
            case allowWhileFlowRunning = "allow_while_flow_running"
            case asrOnly = "asr_only"
            case boostCbw = "boost_cbw"
            case boostMinSimilarity = "boost_min_similarity"
            case boostTerms = "boost_terms"
        }
    }

    struct RunConfiguration: Decodable {
        let input: String
        let output: String
        let s1Variant: String?
        let limit: Int?
        let allowWhileFlowRunning: Bool?
        /// Optional engine override for this process only: "s1-mini", "whispernow-tuned" or "qwen3".
        let cleanupModel: String?
        /// Optional dictation adapter for this process only: "v3c" or "t4" pin one; "auto" routes by length.
        let cleanupAdapter: String?
        /// true: run each row as the live finish task does for raw ASR text (sections, empty and no-speech
        /// rules, final pass, real-word pass, preferred spelling, paragraphs). See `liveFinishClean`.
        let liveFinish: Bool?

        enum CodingKeys: String, CodingKey {
            case input, output, limit
            case s1Variant = "s1_variant"
            case allowWhileFlowRunning = "allow_while_flow_running"
            case cleanupModel = "cleanup_model"
            case cleanupAdapter = "cleanup_adapter"
            case liveFinish = "live_finish"
        }
    }

    struct PrepareJob: Decodable {
        let id: String
        let audio: String
        let bundleID: String?
        let micClass: String?
        /// false for audio that is already post-DSP (shadow-mode WAVs, Flow's own .caf).
        let dsp: Bool?

        enum CodingKeys: String, CodingKey {
            case id, audio, dsp
            case bundleID = "bundle_id", micClass = "mic_class"
        }
    }

    struct RunJob: Decodable {
        let id: String
        let text: String?
        let bundleID: String?

        enum CodingKeys: String, CodingKey {
            case id, text
            case bundleID = "bundle_id"
        }
    }

    static let maximumConcurrentProofClips = 5
    static let maximumConcurrentASRClips = 80
    static let supportedVariants = ["stock"]

    // MARK: Entry points (exit codes: 0 done, 1 failed, 2 bad config, 75 Flow running)

    static func runPrepare(configPath: String) async -> Int32 {
        guard let config = try? JSONDecoder().decode(PrepareConfiguration.self,
                                                     from: Data(contentsOf: URL(fileURLWithPath: configPath))) else {
            log("prepare", "config unreadable; expected {\"input\", \"output\"}"); return 2
        }
        let asrOnly = config.asrOnly == true
        guard claimOwnership(mode: "prepare", allowConcurrent: config.allowWhileFlowRunning == true,
                             limit: config.limit,
                             concurrentCap: asrOnly ? maximumConcurrentASRClips : maximumConcurrentProofClips)
        else { return 75 }
        configureProcess(overrides: [
            ASRVocabularyBoost.cbwKey: config.boostCbw as Any?,
            ASRVocabularyBoost.minSimilarityKey: config.boostMinSimilarity as Any?,
            "userProperNouns": config.boostTerms as Any?,
            "voice.userDictionary": config.boostTerms.map { _ in [String]() } as Any?,
        ].compactMapValues { $0 })
        let jobs: [PrepareJob]
        do { jobs = try readJSONLines(config.input) } catch {
            log("prepare", "input unreadable: \(error.localizedDescription)"); return 2
        }
        let outputURL = URL(fileURLWithPath: config.output)
        let done = completedIDs(outputURL) { $0["status"] as? String == "ok" }
        var pending = jobs.filter { !done.contains($0.id) }
        if let limit = config.limit { pending = Array(pending.prefix(max(0, limit))) }
        log("prepare", "\(jobs.count) clips in input, \(done.count) already ok, \(pending.count) to do")
        guard !pending.isEmpty else { return 0 }

        let transcription = TranscriptionService()
        do { try await transcription.prepare() } catch {
            log("prepare", "speech model unavailable: \(error.localizedDescription)"); return 1
        }
        let asrModel = modelLabel(transcription.activeModelID)
        if asrOnly { return await runASROnly(pending, transcription: transcription, asrModel: asrModel, output: outputURL) }
        guard await prepareCleanupModel(variant: "stock") else { return 1 }
        log("prepare", "asr=\(asrModel) cleanup=\(Qwen3Polisher.effectiveAutomaticCleanupModel) s1=\(s1Label("stock"))")

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-cleanup-prepare-\(getpid())", isDirectory: true)
        do { try ShadowStore.privateDirectory(workDirectory) } catch {
            log("prepare", "work folder unavailable"); return 1
        }
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let build = ShadowModeController.executableDigestPrefix()
        let environment = Environment.current()
        let formatter = TextFormatter()
        let started = Date()
        var counts: [String: Int] = [:]
        for (index, job) in pending.enumerated() {
            let clipStarted = Date()
            var line: [String: Any]
            do {
                line = try await prepareClip(job, transcription: transcription, formatter: formatter,
                                             environment: environment, workDirectory: workDirectory)
                line["status"] = "ok"
            } catch {
                line = ["id": job.id, "status": "error", "error": String(describing: error).prefix(200).description]
            }
            line["flow_build"] = build
            line["models"] = ["asr": asrModel, "s1": s1Label("stock")]
            do { try appendLine(line, to: outputURL) } catch {
                log("prepare", "output not writable: \(error.localizedDescription)"); return 1
            }
            let route = (line["route"] as? String) ?? (line["status"] as? String ?? "?")
            counts[route, default: 0] += 1
            let elapsed = Date().timeIntervalSince(started)
            let remaining = elapsed / Double(index + 1) * Double(pending.count - index - 1)
            log("prepare", String(format: "%d/%d %@ route=%@ asr=%@ms clip=%.1fs eta=%.0fmin",
                                  index + 1, pending.count, job.id, route,
                                  (line["asr_ms"] as? Int).map(String.init) ?? "-",
                                  Date().timeIntervalSince(clipStarted), remaining / 60))
        }
        log("prepare", "done: " + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        return 0
    }

    static func runCleanup(configPath: String) async -> Int32 {
        guard let config = try? JSONDecoder().decode(RunConfiguration.self,
                                                     from: Data(contentsOf: URL(fileURLWithPath: configPath))) else {
            log("run", "config unreadable; expected {\"input\", \"output\", \"s1_variant\"}"); return 2
        }
        let variant = config.s1Variant ?? "stock"
        guard supportedVariants.contains(variant) else {
            // The tuned variant needs step 15 of the plan (S1MiniPolisher.Variant); until
            // then a "wispr-v1" run would silently use the stock weights.
            log("run", "s1_variant \"\(variant)\" is not loadable in this build (only: \(supportedVariants.joined(separator: ", ")))")
            return 2
        }
        guard claimOwnership(mode: "run", allowConcurrent: config.allowWhileFlowRunning == true,
                             limit: config.limit) else { return 75 }
        var overrides: [String: Any] = config.cleanupModel.map { ["voice.cleanupModel": $0] } ?? [:]
        if let adapter = config.cleanupAdapter {
            guard adapter == "auto" || WhisperNowTunedPolisher.DictationAdapter(rawValue: adapter) != nil else {
                log("run", "cleanup_adapter \"\(adapter)\" is not one of v3c, t4, auto"); return 2
            }
            overrides[WhisperNowTunedPolisher.cleanupAdapterKey] = adapter
        }
        configureProcess(overrides: overrides)
        let jobs: [RunJob]
        do { jobs = try readJSONLines(config.input) } catch {
            log("run", "input unreadable: \(error.localizedDescription)"); return 2
        }
        let outputURL = URL(fileURLWithPath: config.output)
        let done = completedIDs(outputURL) { $0["final"] is String }
        var pending = jobs.filter { !done.contains($0.id) }
        if let limit = config.limit { pending = Array(pending.prefix(max(0, limit))) }
        log("run", "\(jobs.count) rows in input, \(done.count) already done, \(pending.count) to do, variant=\(variant)")
        guard !pending.isEmpty else { return 0 }
        guard await prepareCleanupModel(variant: variant) else { return 1 }

        let environment = Environment.current()
        // One warm-up call so the first measured row does not carry the first-token cost.
        _ = await clean(formatted: "so um I think we should send the update to the team today",
                        suspects: [], bundleID: nil, environment: environment)

        if config.liveFinish == true {
            log("run", "live finish path, adapter=\(WhisperNowTunedPolisher.routesByLength ? "routed(t4 under \(DictationRouting.longWords) words, v3c from)" : WhisperNowTunedPolisher.dictationAdapter.rawValue) engine=\(WhisperNowTunedPolisher.engineLabel)")
        }
        let started = Date()
        for (index, job) in pending.enumerated() {
            let text = job.text ?? ""
            let suspects = TextFormatter.suspectsForPolish(text)
            var sectionResults: [String]? = nil
            let outcome: Outcome
            if config.liveFinish == true {
                let live = await liveFinishClean(formatted: text, bundleID: job.bundleID, environment: environment)
                outcome = live.outcome; sectionResults = live.results
            } else {
                outcome = await clean(formatted: text, suspects: suspects, bundleID: job.bundleID,
                                      environment: environment)
            }
            var line: [String: Any] = [
                "id": job.id, "final": outcome.final, "s1_result": outcome.runResultLabel,
                "guard_refused": outcome.result == "rejected:output_guard",
                "cleanup_ms": (outcome.cleanupMs * 10).rounded() / 10, "model": variant, "route": outcome.route,
            ]
            line["control_line"] = outcome.controlLine ?? NSNull()
            if let sectionResults {
                line["results"] = sectionResults
                line["engine"] = outcome.engine ?? NSNull()
            }
            do { try appendLine(line, to: outputURL) } catch {
                log("run", "output not writable: \(error.localizedDescription)"); return 1
            }
            let elapsed = Date().timeIntervalSince(started)
            let remaining = elapsed / Double(index + 1) * Double(pending.count - index - 1)
            log("run", String(format: "%d/%d %@ %@ %.0fms eta=%.0fs", index + 1, pending.count, job.id,
                              outcome.runResultLabel, outcome.cleanupMs, remaining))
        }
        log("run", "done")
        return 0
    }

    // MARK: Process setup

    /// The spec refuses to run while Flow holds the backend lock (both would load
    /// the models and compete for the GPU/ANE). A proof of at most five items may
    /// opt in to running beside it.
    static func claimOwnership(mode: String, allowConcurrent: Bool, limit: Int?,
                               concurrentCap: Int = maximumConcurrentProofClips) -> Bool {
        guard let reason = FlowOwnership.shared.acquire() else { return true }
        if allowConcurrent, let limit, limit <= concurrentCap {
            log(mode, "Flow is running (\(reason)); continuing for a \(limit)-item proof only")
            return true
        }
        log(mode, "refusing to start: \(reason) Quit Flow first.")
        return false
    }

    static func configureProcess(overrides: [String: Any] = [:]) {
        Telemetry.isSuppressed = true
        _ = setpriority(PRIO_PROCESS, 0, 10)
        // A bare SwiftPM binary has its own defaults domain. Read the app's saved
        // settings (cleanup model, speech model, cleanup level, Wispr styles...) and
        // force local-only for this process. In-memory; nothing is written back.
        var settings = UserDefaults.standard.persistentDomain(forName: "com.example.flow") ?? [:]
        settings["voice.allowCloudPolishing"] = false
        settings["voice.allowCloudMeetingSummary"] = false
        settings["voice.privacyMode"] = true
        settings.merge(overrides) { _, new in new }
        UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
    }

    static func prepareCleanupModel(variant: String) async -> Bool {
        guard variant == "stock" else { return false }
        if Qwen3Polisher.effectiveAutomaticCleanupModel == WhisperNowTunedPolisher.settingValue {
            guard await WhisperNowTunedPolisher.shared.prepare() else {
                log("cleanup", "WhisperNow tuned could not start from \(WhisperNowTunedPolisher.modelDirectory.path)")
                return false
            }
            log("cleanup", "WhisperNow tuned ready (\(WhisperNowTunedPolisher.modelFile()?.lastPathComponent ?? "?"))")
            // S1-mini is the guard's fallback; a missing S1 only means fallbacks strip hesitations instead.
            _ = await S1MiniPolisher.shared.prepare()
            return true
        }
        guard Qwen3Polisher.effectiveAutomaticCleanupModel == "s1-mini" else { return true }
        if await S1MiniPolisher.shared.prepare() { return true }
        log("cleanup", "S1-mini could not load from \(S1MiniPolisher.defaultDirectory.path)")
        return false
    }

    // MARK: ASR-only measurement (vocabulary boosting off vs on)

    static func runASROnly(_ pending: [PrepareJob], transcription: TranscriptionService, asrModel: String,
                           output: URL) async -> Int32 {
        let terms = ASRVocabularyBoost.trustedTerms()
        let thresholds = ASRVocabularyBoost.thresholds()
        log("asr", "asr=\(asrModel) boost terms=\(terms.count) cbw=\(thresholds.cbw.map { "\($0)" } ?? "default") "
            + "minSimilarity=\(thresholds.minSimilarity.map { "\($0)" } ?? "default")")
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-asr-replay-\(getpid())", isDirectory: true)
        do { try ShadowStore.privateDirectory(workDirectory) } catch { log("asr", "work folder unavailable"); return 1 }
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        for (index, job) in pending.enumerated() {
            var line: [String: Any] = ["id": job.id, "route": "asr-only", "boost_terms": terms.count]
            let source = URL(fileURLWithPath: (job.audio as NSString).expandingTildeInPath)
            let caf = workDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).caf")
            do {
                let applyDSP = job.dsp ?? true
                _ = try await Task.detached(priority: .utility) {
                    try CaptureReplay.render(source: source, to: caf, applyDSP: applyDSP,
                                             tuning: DSPTuning.forMicClass(job.micClass))
                }.value
                transcription.vocabularyBoostOverride = false
                let t0 = Date()
                let off = try await transcription.transcribeFile(url: caf)
                line["asr_ms"] = Int(Date().timeIntervalSince(t0) * 1000)
                transcription.vocabularyBoostOverride = true
                let t1 = Date()
                let on = try await transcription.transcribeFile(url: caf)
                line["asr_boost_ms"] = Int(Date().timeIntervalSince(t1) * 1000)
                line["parakeet_raw"] = off.map(\.text).joined(separator: " ")
                line["parakeet_boosted"] = on.map(\.text).joined(separator: " ")
                let report = transcription.lastVocabularyBoost
                line["boost_replacements"] = report?.replacements ?? []
                line["boost_ctc_ran"] = report?.ctcRan ?? false
                line["boost_rejected"] = report?.rejected ?? []
                line["boost_ms"] = ((report?.milliseconds ?? 0) * 10).rounded() / 10
                line["status"] = "ok"
            } catch {
                line["status"] = "error"
                line["error"] = String(describing: error).prefix(200).description
            }
            try? FileManager.default.removeItem(at: caf)
            line["models"] = ["asr": asrModel]
            do { try appendLine(line, to: output) } catch { log("asr", "output not writable"); return 1 }
            log("asr", "\(index + 1)/\(pending.count) \(job.id) replacements=\((line["boost_replacements"] as? [String])?.count ?? 0)")
        }
        transcription.vocabularyBoostOverride = nil
        log("asr", "done")
        return 0
    }

    // MARK: Per-clip production path (spec B, steps 1-8)

    static func prepareClip(_ job: PrepareJob, transcription: TranscriptionService, formatter: TextFormatter,
                            environment: Environment, workDirectory: URL) async throws -> [String: Any] {
        let source = URL(fileURLWithPath: (job.audio as NSString).expandingTildeInPath)
        let applyDSP = job.dsp ?? true
        var line: [String: Any] = ["id": job.id, "dsp": applyDSP, "mic_class": job.micClass ?? NSNull()]

        // 1-3. Capture replay into a .caf exactly as AudioCaptureService writes it.
        let caf = workDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).caf")
        defer { try? FileManager.default.removeItem(at: caf) }
        let replay = try await Task.detached(priority: .utility) {
            try CaptureReplay.render(source: source, to: caf, applyDSP: applyDSP,
                                     tuning: DSPTuning.forMicClass(job.micClass))
        }.value
        line["caf_bytes"] = replay.fileBytes
        line["voiced_s"] = (replay.voicedSeconds * 1000).rounded() / 1000
        line["quiet_voiced_s"] = (replay.quietVoicedSeconds * 1000).rounded() / 1000
        line["peak_rms"] = replay.peakRMS

        let context = environment.parameters(bundleID: job.bundleID)
        line["personality_style"] = context.personalityStyle
        line["polish_context"] = String(describing: context.polishContext)
        func skip(_ route: String, raw: String = "", formatted: String = "") -> [String: Any] {
            var skipped = line
            skipped["route"] = route
            skipped["parakeet_raw"] = raw
            skipped["formatted"] = formatted
            skipped["stock_final"] = formatted.isEmpty ? "" : DictationTextPreparation.finalize(polished: formatted, formatted: formatted)
            skipped["s1_input"] = NSNull(); skipped["control_line"] = NSNull(); skipped["s1_result"] = NSNull()
            return skipped
        }
        // RecordingCoordinator.stopRecording: no transcription at or under 20,000 bytes.
        guard replay.fileBytes > 20_000 else { line["asr_ms"] = 0; return skip("skip:too-small") }
        let skipPolish = replay.fileBytes < 36_000

        // 4. ASR on the saved file, production-selected model and chunker.
        let asrStarted = Date()
        let segments = try await transcription.transcribeFile(url: caf)
        line["asr_ms"] = Int(Date().timeIntervalSince(asrStarted) * 1000)
        let raw = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        // 5. Speech-presence gate (and the media-leak guard, which never fires without media).
        if !segments.isEmpty {
            let confidence = segments.compactMap(\.confidence).min()
            if let confidence, confidence.isFinite { line["asr_confidence"] = confidence }
            if SpeechPresenceGate.dropReason(joinedText: raw, voicedSeconds: replay.voicedSeconds,
                                             peakRMS: replay.peakRMS, quietVoicedSeconds: replay.quietVoicedSeconds,
                                             recognitionConfidence: confidence) != nil
                || SpeechPresenceGate.mediaLeakDropReason(joinedText: raw, voicedSeconds: replay.voicedSeconds,
                                                          capturedSeconds: replay.capturedSeconds,
                                                          mediaPlaying: false) != nil {
                return skip("dropped:vad", raw: raw)
            }
        }
        guard !raw.isEmpty else { return skip("skip:empty-transcript") }

        // 6. Text preparation.
        let preparation = DictationTextPreparation.prepare(
            segments: segments, formatter: formatter,
            pressEnterEnabled: UserDefaults.standard.bool(forKey: "voice.pressEnterCommandEnabled"),
            autoPaste: true)
        switch preparation.rejection {
        case .empty?: return skip("skip:empty-transcript", raw: raw)
        case .nonLatin?: return skip("skip:non-latin", raw: raw)
        case nil: break
        }
        let formatted = preparation.command.text
        if skipPolish { return skip("skip:short-clip", raw: raw, formatted: formatted) }

        // 7-8. Cleanup as the live finish task runs it, then finalize.
        let suspects = Array(Set(segments.compactMap(\.suspectWords).flatMap { $0 }
                                 + TextFormatter.suspectsForPolish(formatted)))
        let outcome = await clean(formatted: formatted, suspects: suspects, bundleID: job.bundleID,
                                  environment: environment)
        line["route"] = outcome.route
        line["parakeet_raw"] = raw
        line["formatted"] = formatted
        line["stock_final"] = outcome.final
        line["s1_input"] = outcome.route == "s1" ? (outcome.input ?? NSNull()) : NSNull()
        line["control_line"] = outcome.route == "s1" ? (outcome.controlLine ?? NSNull()) : NSNull()
        line["s1_result"] = outcome.result ?? NSNull()
        line["cleanup_ms"] = (outcome.cleanupMs * 10).rounded() / 10
        return line
    }

    // MARK: Cleanup (shared by both modes)

    /// What the live finish task (VoiceApp, `pendingFinishTask`) derives before polishing.
    struct Parameters {
        let polishContext: LLMPolisher.PolishContext
        let appContextLabel: String?
        let cleanupLevel: String
        let personalityStyle: String
    }

    struct Environment {
        let profile: WisprPersonalizationProfile?
        let importedStyles: Bool

        static func current() -> Environment {
            let imported = UserDefaults.standard.bool(forKey: "voice.wisprContextStylesEnabled")
            return Environment(profile: imported ? WisprPersonalizationProfile.load() : nil, importedStyles: imported)
        }

        func parameters(bundleID: String?) -> Parameters {
            let imported = importedStyles ? profile?.style(forBundleID: bundleID) : nil
            return Parameters(polishContext: CursorPaster.polishContext(forBundleID: bundleID),
                              appContextLabel: Qwen3Polisher.appContextLabel(forBundleID: bundleID),
                              cleanupLevel: CleanupLevel.current.rawValue,
                              personalityStyle: imported ?? PersonalityStyle.current.rawValue)
        }
    }

    struct Outcome {
        let final: String
        let route: String
        let input: String?
        let controlLine: String?
        /// ShadowCleanupObserver label: accepted, unchanged, rejected:<r>, unavailable:<r>.
        let result: String?
        let engine: String?
        let cleanupMs: Double

        /// `--cleanup-run` vocabulary: rules-only skips are "skipped:<reason>".
        var runResultLabel: String {
            guard let result else { return "skipped:" + route.replacingOccurrences(of: "skip:", with: "") }
            if engine == "rules", let colon = result.firstIndex(of: ":") {
                return "skipped:" + result[result.index(after: colon)...]
            }
            return result
        }
    }

    static func clean(formatted: String, suspects: [String], bundleID: String?,
                      environment: Environment) async -> Outcome {
        let parameters = environment.parameters(bundleID: bundleID)
        let polishEnabled = UserDefaults.standard.object(forKey: "polishEnabled") as? Bool ?? true
        if CleanupLevel.current == .none || !polishEnabled {
            return Outcome(final: DictationTextPreparation.finalize(polished: formatted, formatted: formatted),
                           route: "skip:polish-off", input: nil, controlLine: nil, result: nil, engine: nil,
                           cleanupMs: 0)
        }
        let vocabulary = Array(Set(ProperNounVocabulary.current() + CombinedDictionary.terms()))
        let observer = ShadowCleanupObserver()
        let started = CFAbsoluteTimeGetCurrent()
        var polished = await ShadowCleanupTrace.$observer.withValue(observer) {
            await Qwen3Polisher.shared.polish(
                formatted,
                context: parameters.polishContext,
                suspectWords: suspects.isEmpty ? nil : suspects,
                userVocabulary: vocabulary.isEmpty ? nil : vocabulary,
                fieldContext: nil,
                appContextLabel: parameters.appContextLabel,
                cleanupLevel: parameters.cleanupLevel,
                personalityStyle: parameters.personalityStyle)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        // VoiceApp: an empty polish result falls back to the formatted text.
        if polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            polished = formatted
        }
        let final = DictationTextPreparation.finalize(polished: polished, formatted: formatted)
        let route = observer.route
            ?? (Qwen3Polisher.effectiveAutomaticCleanupModel == "s1-mini" ? "skip:unknown" : "skip:engine-local:qwen3")
        return Outcome(final: final, route: route, input: observer.input, controlLine: observer.controlLine,
                       result: observer.result, engine: observer.engine, cleanupMs: ms)
    }

    /// Live finish task (VoiceApp `pendingFinishTask`) for the WhisperNow T4/T5 route, from raw ASR text:
    /// sections for long or multi-line drafts, the no-speech and empty-answer rules, then the same post chain
    /// (finalize, DictationFinalPass, real-word pass, preferred spelling, DictationParagraphs).
    /// Not replayed: deadlines, the PC route (off by default) and DraftDecisionGate (off under privacy mode).
    final class ResultLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        private var lastEngine: String?
        func add(_ result: String?, engine: String?) {
            lock.withLock { items.append(result ?? "none"); if let engine { lastEngine = engine } }
        }
        var results: [String] { lock.withLock { items } }
        var engine: String? { lock.withLock { lastEngine } }
    }

    static func liveFinishClean(formatted: String, bundleID: String?,
                                environment: Environment) async -> (outcome: Outcome, results: [String]) {
        let parameters = environment.parameters(bundleID: bundleID)
        let polishEnabled = UserDefaults.standard.object(forKey: "polishEnabled") as? Bool ?? true
        let preferredWords = ProperNounVocabulary.preferredSpellingTerms()
        var seen = Set<String>()
        let vocabulary = (preferredWords + ProperNounVocabulary.current() + CombinedDictionary.terms())
            .filter { seen.insert($0.lowercased()).inserted }
        let suspects = TextFormatter.suspectsForPolish(formatted)
        let usesTuned = Qwen3Polisher.effectiveAutomaticCleanupModel == WhisperNowTunedPolisher.settingValue
        let usesModelTranscript = usesTuned && (WhisperNowTunedPolisher.usesT2Contracts || WhisperNowTunedPolisher.usesT4)
        let log = ResultLog()
        let polishDraft: @Sendable (String, Bool) async -> String = { text, isSection in
            let observer = ShadowCleanupObserver()
            let output = await ShadowCleanupTrace.$observer.withValue(observer) {
                await Qwen3Polisher.shared.polish(text, context: parameters.polishContext,
                    suspectWords: isSection || suspects.isEmpty ? nil : suspects,
                    userVocabulary: vocabulary.isEmpty ? nil : vocabulary, fieldContext: nil,
                    appContextLabel: parameters.appContextLabel, cleanupLevel: parameters.cleanupLevel,
                    personalityStyle: parameters.personalityStyle)
            }
            log.add(observer.result, engine: observer.engine)
            return output
        }
        let started = CFAbsoluteTimeGetCurrent()
        var finalText: String
        var route = "single"
        if CleanupLevel.current == .none || !polishEnabled {
            finalText = formatted; route = "skip:polish-off"
        } else if parameters.polishContext != .code, Qwen3Polisher.isEnabled,
                  formatted.count > 1_200 || formatted.contains(where: \.isNewline) {
            route = "sections"
            let ranges = DictationTextPreparation.cleanupSections(in: formatted)
            let result = await DictationTextPreparation.cleanSections(in: formatted, ranges: ranges,
                deadline: .now + .seconds(600)) { section in
                let edited = await polishDraft(section, true)
                return await DraftDecisionGate.shouldKeepOriginal(section, edited: edited) ? nil : edited
            }
            finalText = result.text
        } else {
            finalText = await polishDraft(formatted, false)
        }
        if route == "single", await DraftDecisionGate.shouldKeepOriginal(formatted, edited: finalText) {
            finalText = formatted; route = "single:decision-meaning"
        }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        func outcome(_ text: String) -> Outcome {
            Outcome(final: text, route: route, input: formatted, controlLine: nil,
                    result: log.results.joined(separator: "|"), engine: log.engine, cleanupMs: ms)
        }
        if WhisperNowCleanupDecision.isConfirmedNoSpeech(polished: finalText, formatted: formatted) {
            return (outcome(""), log.results)
        }
        if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { finalText = formatted }
        let level = parameters.cleanupLevel
        finalText = T2CleanupOptions.finalizedTranscript(candidate: finalText, preparedASR: formatted,
            level: level, recognizedT2: usesModelTranscript)
            ?? DictationTextPreparation.finalize(polished: finalText, formatted: formatted)
        finalText = DictationFinalPass.apply(finalText)
        if polishEnabled && level != "none" {
            finalText = DictationReferee.dictationPass(finalText, isCode: parameters.polishContext == .code)
        }
        // tinynext recheck, as the live finish task runs it (suspects here are the formatter's; live adds
        // the recognizer's low-confidence words). Model-less, it returns the text unchanged.
        if polishEnabled && level != "none" && parameters.polishContext != .code {
            let rechecked = LowConfidenceRecheck.recheck(finalText, suspects: suspects, protectedTerms: vocabulary)
            if !rechecked.changes.isEmpty { log.add("tinynext:\(rechecked.changes.count)", engine: nil) }
            finalText = rechecked.text
        }
        if parameters.polishContext != .code {
            finalText = ProperNounVocabulary.applyPreferredSpelling(finalText, terms: preferredWords)
        }
        if polishEnabled && level != "none" {
            finalText = parameters.polishContext == .code
                ? DictationParagraphs.format(finalText)
                : DictationParagraphs.formatDictation(finalText, isEmail: parameters.polishContext == .email)
        }
        return (outcome(finalText), log.results)
    }

    // MARK: Labels

    nonisolated static func modelLabel(_ id: SpeechModelID?) -> String {
        guard let id else { return "unknown" }
        let revision = SpeechModelCatalog.descriptor(for: id).pinnedRevision.map { "@" + $0.prefix(8) } ?? ""
        return id.rawValue + revision
    }

    nonisolated static func s1Label(_ variant: String) -> String {
        variant + "@" + S1MiniPolisher.weightsSHA256.prefix(8)
    }

    // MARK: JSONL I/O

    nonisolated static func readJSONLines<T: Decodable>(_ path: String) throws -> [T] {
        let text = try String(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return try decoder.decode(T.self, from: Data(trimmed.utf8))
        }
    }

    /// Ids already written to `output` that satisfy `isDone` (resume support).
    nonisolated static func completedIDs(_ output: URL, isDone: ([String: Any]) -> Bool) -> Set<String> {
        guard let text = try? String(contentsOf: output, encoding: .utf8) else { return [] }
        var ids = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String, isDone(object) else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// One sorted-key JSON line, appended and fsynced; the file is created 0600.
    nonisolated static func appendLine(_ object: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
        _ = fsync(fd)
    }

    nonisolated static func log(_ mode: String, _ message: String) {
        fputs("[cleanup-\(mode)] \(message)\n", stderr)
    }
}

// MARK: - Capture replay (pure; unit-tested)

/// Re-creates what AudioCaptureService would have written for `source`: the tap
/// buffers (4,096 frames at the file's own rate), each resampled to 16 kHz mono
/// Float32 with the capture converter settings, run through CaptureDSP, framed by
/// the same zero padding, and written as the same `.caf`. Speech presence is
/// accumulated per buffer exactly as `processAudioBuffer` does.
enum CaptureReplay {
    static let tapFrames: AVAudioFrameCount = 4096
    static let leadInPadFrames = 1920    // startWritingToFile
    static let trailingPadFrames = 960   // stopWritingToFile

    struct Result {
        var voicedSeconds: Double = 0
        var quietVoicedSeconds: Double = 0
        var capturedSeconds: Double = 0
        var peakRMS: Float = 0
        var fileBytes: Int = 0
        /// Post-DSP samples in file order, without the padding (for tests).
        var samples: [Float] = []
    }

    enum Failure: Error { case unreadable, conversionFailed }

    static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: CaptureDSP.sampleRate, channels: 1, interleaved: false)!
    }

    /// AudioCaptureService.startWritingToFile settings.
    static var cafSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: CaptureDSP.sampleRate, AVNumberOfChannelsKey: 1,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true,
         AVLinearPCMIsBigEndianKey: false]
    }

    static func render(source: URL, to destination: URL, applyDSP: Bool, tuning: DSPTuning) throws -> Result {
        let buffers = applyDSP ? try tapBuffers(source) : try postDSPBuffers(source)
        var result = Result()
        var dsp = CaptureDSP(tuning: tuning)
        for buffer in buffers {
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channel = buffer.floatChannelData?[0] else { continue }
            let rms: Float
            if applyDSP {
                rms = dsp.process(channel, frameCount: frames)
            } else {
                var value: Float = 0
                vDSP_rmsqv(channel, 1, &value, vDSP_Length(frames))
                rms = value
            }
            if rms > result.peakRMS { result.peakRMS = rms }
            let seconds = Double(frames) / CaptureDSP.sampleRate
            result.capturedSeconds += seconds
            if rms >= CaptureDSP.speechFloorRMS { result.voicedSeconds += seconds }
            if rms >= CaptureDSP.quietSpeechFloorRMS { result.quietVoicedSeconds += seconds }
            result.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: destination, settings: cafSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        // Post-DSP audio from Flow (shadow WAV, retained .caf) already carries the padding.
        if applyDSP { try file.write(from: silence(frames: leadInPadFrames)) }
        for buffer in buffers where buffer.frameLength > 0 { try file.write(from: buffer) }
        if applyDSP { try file.write(from: silence(frames: trailingPadFrames)) }
        file.close()
        result.fileBytes = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        return result
    }

    /// Native-rate 4,096-frame reads, each converted on its own like `resample(_:)`.
    static func tapBuffers(_ source: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: source)
        let inputFormat = file.processingFormat
        let target = targetFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: target),
              let tap = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: tapFrames) else { throw Failure.unreadable }
        converter.sampleRateConverterQuality = Int(AVAudioQuality.medium.rawValue)
        let ratio = target.sampleRate / inputFormat.sampleRate
        var out: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            tap.frameLength = 0
            try file.read(into: tap, frameCount: tapFrames)
            guard tap.frameLength > 0 else { break }
            guard let converted = AVAudioPCMBuffer(pcmFormat: target,
                    frameCapacity: AVAudioFrameCount(Double(tap.frameLength) * ratio + 1024)) else { throw Failure.conversionFailed }
            var provided = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if provided { state.pointee = .noDataNow; return nil }
                provided = true
                state.pointee = .haveData
                return tap
            }
            if status == .error || error != nil { throw Failure.conversionFailed }
            out.append(converted)
        }
        return out
    }

    /// Already-processed 16 kHz audio, re-cut into 4,096-frame buffers for the presence gate.
    static func postDSPBuffers(_ source: URL) throws -> [AVAudioPCMBuffer] {
        let samples = try TranscriptionService.readSamplesAt16kMono(url: source)
        var out: [AVAudioPCMBuffer] = []
        var start = 0
        while start < samples.count {
            let count = min(Int(tapFrames), samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { throw Failure.conversionFailed }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + start, count: count) }
            out.append(buffer)
            start += count
        }
        return out
    }

    static func silence(frames: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        memset(buffer.floatChannelData![0], 0, frames * MemoryLayout<Float>.size)
        return buffer
    }
}
