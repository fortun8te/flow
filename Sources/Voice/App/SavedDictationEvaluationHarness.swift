import Foundation
import CryptoKit

/// Replays saved audio through the production decoder and shared text/delivery
/// preparation. Never constructs AppDelegate, capture, CursorPaster or a writer.
@MainActor
enum SavedDictationEvaluationHarness {
    struct Configuration: Decodable {
        let manifest: String
        let output: String
        let speechModel: String
        let cleanupModel: String
        var passes: Int? = 1
        var maximumSeconds: Double? = 600
        var personalityStyle: String? = "neutral"
    }
    struct Prediction: Codable {
        let sourceID: String
        let language: String?
        let pass: Int
        let status: String
        let raw: String
        let formatted: String
        let final: String
        let effectiveSpeechModel: String
        let effectiveCleanupEngine: String
        let decodeMilliseconds: Double
        let cleanupMilliseconds: Double
        let totalMilliseconds: Double
        let historicalASRAgreement: LocalASREvaluationHarness.Agreement?
        let cleanupAnchors: LocalCleanupEvaluationHarness.AnchorAssessment?
        let finalAnchors: LocalCleanupEvaluationHarness.AnchorAssessment?
        let delivery: DictationTextPreparation.DeliveryIntent?
    }
    struct Receipt: Codable {
        let schemaVersion = 1
        let coverage = "Production saved-file decoder, shared formatter/script/command gates, production S1 routing, shared finalization and delivery intent. No microphone, UI, clipboard, history writes, cloud or downloads."
        let missingCoverage = "Original capture energy/media/short-clip metadata and field context are unavailable. Capture gates, multi-model merge, actual insertion and live pill transitions are not replayed."
        let reference = "Historical Wispr ASR is an unverified hypothesis; disagreement is not transcription accuracy."
        let speechModel: String
        let cleanupModel: String
        let personalityStyle: String
        let modelLoadMilliseconds: Double
        let cleanupLoadMilliseconds: Double
        let selectedClips: Int
        let attempted: Int
        let successful: Int
        let empty: Int
        let failed: Int
        let rejectedScript: Int
        let anchorFailures: Int
        let effectiveEngines: [String: Int]
        let medianPipelineMilliseconds: Double?
        let p95PipelineMilliseconds: Double?
        let medianCleanupMilliseconds: Double?
        let stoppedForBudget: Bool
    }
    enum Failure: Error { case invalidConfiguration, missingLocalModel, modelActivation, invalidAudio, insecureOutput }

    static func run(_ config: Configuration) async throws {
        guard let speech = SpeechModelID(rawValue: config.speechModel),
              ["s1-mini", "none"].contains(config.cleanupModel),
              (1...3).contains(config.passes ?? 1), (1...96).contains((try? JSONDecoder().decode(LocalASREvaluationHarness.Manifest.self,
                from: Data(contentsOf: URL(fileURLWithPath: config.manifest))).clips.count) ?? 0) else { throw Failure.invalidConfiguration }
        let style = config.personalityStyle ?? "neutral"
        // Process-local overrides, not persistent app settings. Private input
        // remains data; it cannot opt into a provider or change these policies.
        UserDefaults.standard.setVolatileDomain([
            "voice.privacyMode": true, "voice.allowCloudPolishing": false,
            "voice.allowCloudMeetingSummary": false, "voice.cleanupModel": "s1-mini",
            "polishEnabled": config.cleanupModel != "none", "llmPolishEnabled": true,
            "cleanupLevel": "light", "personalityStyle": style,
            "voice.stopWordEnabled": false, "voice.pressEnterCommandEnabled": false,
            "autoPaste": false, "autoCopy": false
        ], forName: UserDefaults.argumentDomain)
        guard !Qwen3Polisher.cloudAllowed(optIn: UserDefaults.standard.bool(forKey: "voice.allowCloudPolishing"),
                                          privacyMode: UserDefaults.standard.bool(forKey: "voice.privacyMode")) else { throw Failure.invalidConfiguration }
        let descriptor = SpeechModelCatalog.descriptor(for: speech)
        guard SpeechModelLoader.artifactsPresent(descriptor) else { throw Failure.missingLocalModel }
        let loadStart = DispatchTime.now().uptimeNanoseconds
        let prepared = try await SpeechModelLoader.prepare(descriptor)
        let transcription = TranscriptionService()
        guard transcription.installPreparedModel(prepared), transcription.activeModelID == speech else { throw Failure.modelActivation }
        let loadMS = milliseconds(loadStart)
        let cleanupStart = DispatchTime.now().uptimeNanoseconds
        if config.cleanupModel == "s1-mini", !(await S1MiniPolisher.shared.prepare()) { throw Failure.missingLocalModel }
        let cleanupLoadMS = milliseconds(cleanupStart)
        let manifestURL = URL(fileURLWithPath: config.manifest)
        let manifest = try JSONDecoder().decode(LocalASREvaluationHarness.Manifest.self, from: Data(contentsOf: manifestURL))
        let output = URL(fileURLWithPath: config.output, isDirectory: true)
        guard output.resolvingSymlinksInPath().standardizedFileURL == output.standardizedFileURL else { throw Failure.insecureOutput }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
        var results: [Prediction] = []
        var budgetStopped = false
        let runStart = DispatchTime.now().uptimeNanoseconds
        let vocabulary = ProperNounVocabulary.customTerms()
        outer: for pass in 1...(config.passes ?? 1) {
            for clip in manifest.clips {
                if milliseconds(runStart) > min(1200, max(10, config.maximumSeconds ?? 600)) * 1000 { budgetStopped = true; break outer }
                try Task.checkCancellation()
                guard let relative = clip.local_audio, let expected = clip.audio_sha256 else { throw Failure.invalidAudio }
                let audio = try LocalASREvaluationHarness.audioURL(relative: relative, directory: manifestURL.deletingLastPathComponent())
                let bytes = try Data(contentsOf: audio, options: .mappedIfSafe)
                guard bytes.count <= 50 * 1024 * 1024,
                      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected else { throw Failure.invalidAudio }
                let started = DispatchTime.now().uptimeNanoseconds
                do {
                    let segments = try await transcription.transcribeFile(url: audio)
                    let decodeMS = milliseconds(started)
                    let text = DictationTextPreparation.prepare(segments: segments, formatter: TextFormatter(),
                        pressEnterEnabled: false, autoPaste: true)
                    if let rejection = text.rejection {
                        results.append(Prediction(sourceID: clip.source_id, language: clip.language, pass: pass,
                            status: rejection.rawValue, raw: text.rawText, formatted: text.command.text, final: "",
                            effectiveSpeechModel: speech.rawValue, effectiveCleanupEngine: "not-run",
                            decodeMilliseconds: decodeMS, cleanupMilliseconds: 0, totalMilliseconds: milliseconds(started),
                            historicalASRAgreement: nil, cleanupAnchors: nil, finalAnchors: nil, delivery: nil))
                        continue
                    }
                    PolishStatus.shared.lastEngine = nil
                    let polishing = DispatchTime.now().uptimeNanoseconds
                    let polished: String
                    if config.cleanupModel == "none" { polished = text.command.text }
                    else {
                        polished = await Qwen3Polisher.shared.polish(text.command.text, context: .default,
                            userVocabulary: vocabulary.isEmpty ? nil : vocabulary,
                            cleanupLevel: "light", personalityStyle: style)
                    }
                    let cleanupMS = milliseconds(polishing)
                    let final = DictationTextPreparation.finalize(polished: polished, formatted: text.command.text)
                    let intent = DictationTextPreparation.delivery(autoCopy: true, autoPaste: true, skipPolish: config.cleanupModel == "none",
                        formatted: text.command.text, final: final, fieldContextProvided: false, command: text.command)
                    let reference = clip.history?.texts?.raw_asr_text
                    results.append(Prediction(sourceID: clip.source_id, language: clip.language, pass: pass,
                        status: final.isEmpty ? "empty" : "success", raw: text.rawText, formatted: text.command.text, final: final,
                        effectiveSpeechModel: transcription.activeModelID?.rawValue ?? "unknown",
                        effectiveCleanupEngine: config.cleanupModel == "none" ? "rules-only" : (PolishStatus.shared.lastEngine ?? "rules-or-language-bypass"),
                        decodeMilliseconds: decodeMS, cleanupMilliseconds: cleanupMS, totalMilliseconds: milliseconds(started),
                        historicalASRAgreement: reference.flatMap { LocalASREvaluationHarness.agreement(reference: $0, actual: text.rawText) },
                        cleanupAnchors: LocalCleanupEvaluationHarness.assessAnchors(input: text.command.text, output: final),
                        finalAnchors: LocalCleanupEvaluationHarness.assessAnchors(input: text.rawText, output: final), delivery: intent))
                } catch {
                    results.append(Prediction(sourceID: clip.source_id, language: clip.language, pass: pass, status: "error",
                        raw: "", formatted: "", final: "", effectiveSpeechModel: speech.rawValue, effectiveCleanupEngine: "not-run",
                        decodeMilliseconds: milliseconds(started), cleanupMilliseconds: 0, totalMilliseconds: milliseconds(started),
                        historicalASRAgreement: nil, cleanupAnchors: nil, finalAnchors: nil, delivery: nil))
                }
            }
        }
        let success = results.filter { $0.status == "success" }
        let receipt = Receipt(speechModel: speech.rawValue, cleanupModel: config.cleanupModel, personalityStyle: style,
            modelLoadMilliseconds: loadMS, cleanupLoadMilliseconds: cleanupLoadMS, selectedClips: manifest.clips.count,
            attempted: results.count, successful: success.count, empty: results.filter { $0.status == "empty" }.count,
            failed: results.filter { $0.status == "error" }.count, rejectedScript: results.filter { $0.status == "nonLatin" }.count,
            anchorFailures: success.filter { $0.cleanupAnchors?.passed == false }.count,
            effectiveEngines: Dictionary(grouping: results, by: \.effectiveCleanupEngine).mapValues(\.count),
            medianPipelineMilliseconds: LocalASREvaluationHarness.median(success.map(\.totalMilliseconds)),
            p95PipelineMilliseconds: LocalASREvaluationHarness.p95(success.map(\.totalMilliseconds)),
            medianCleanupMilliseconds: LocalASREvaluationHarness.median(success.map(\.cleanupMilliseconds)), stoppedForBudget: budgetStopped)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try privateWrite(encoder.encode(results), to: output.appendingPathComponent("private-predictions.json"))
        try privateWrite(encoder.encode(receipt), to: output.appendingPathComponent("receipt.json"))
    }
    private static func milliseconds(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    private static func privateWrite(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.insecureOutput }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
