import Foundation
import CoreML
import AVFoundation
import CryptoKit
import Darwin
import FluidAudio

/// Explicit saved-file evaluation. This never starts capture, playback, a
/// downloader, an app delegate, or a cloud provider. Private predictions and
/// the shareable aggregate are deliberately separate files.
@MainActor
enum LocalASREvaluationHarness {
    struct Manifest: Decodable {
        let schema_version: Int
        let clips: [Clip]
    }
    struct Clip: Decodable {
        let source_id: String
        let local_audio: String?
        let audio_sha256: String?
        let duration_seconds: Double
        let split: String
        let language: String?
        let history: History?
    }
    struct History: Decodable {
        let source: String?
        let texts: Texts?
    }
    struct Texts: Decodable { let raw_asr_text: String? }

    struct Agreement: Codable, Equatable {
        let editDistance: Int
        let referenceWords: Int
        var rate: Double? { referenceWords > 0 ? Double(editDistance) / Double(referenceWords) : nil }
    }
    struct Prediction: Codable {
        let sourceID: String
        let pass: Int
        let status: String
        let text: String?
        let durationSeconds: Double
        let preprocessingMilliseconds: Double
        let decodingMilliseconds: Double
        let historicalAgreement: Agreement?
    }
    struct Receipt: Codable {
        let schemaVersion = 1
        let evaluation = "Saved audio only; no microphone, playback, cloud or application UI"
        let reference = "Historical raw Wispr ASR hypotheses, not human ground truth; agreement is not accuracy"
        let timing = "Sequential passes after one synthetic warmup; decode excludes file conversion and model loading"
        let memory = "Sampled process resident bytes at call boundaries, not GPU allocation or peak physical footprint"
        let modelLabel: String
        let version: String
        let localLoader: String
        let requestedPasses: Int
        let selectedClips: Int
        let selectedAudioSeconds: Double
        let attemptedCalls: Int
        let successfulCalls: Int
        let emptyOutputs: Int
        let failedCalls: Int
        let loadMilliseconds: Double
        let warmupMilliseconds: Double
        let allCallsMedianDecodeMilliseconds: Double?
        let allCallsP95DecodeMilliseconds: Double?
        let allCallsMedianProcessingMilliseconds: Double?
        let allCallsP95ProcessingMilliseconds: Double?
        let successfulAudioSeconds: Double
        let successfulDecodeSeconds: Double
        let successfulRealtimeFactor: Double?
        let historicalAgreementCalls: Int
        let historicalReferenceWords: Int
        let historicalWordEdits: Int
        let historicalDisagreementRate: Double?
        let observedMaxResidentBytes: UInt64
        let stoppedForTimeBudget: Bool
    }
    enum Failure: Error { case invalidManifest, invalidBounds, noMaterializedAudio, invalidAudioPath, incompleteLocalModel, outputCreationFailed }

    /// Punctuation/casing-normalized token agreement, not an ASR quality grade.
    nonisolated static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    nonisolated static func agreement(reference: String, actual: String) -> Agreement? {
        let expected = words(reference), observed = words(actual)
        guard !expected.isEmpty, expected.count <= 5_000, observed.count <= 5_000 else { return nil }
        var previous = Array(0...observed.count)
        for (i, word) in expected.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: observed.count)
            for j in observed.indices {
                next[j + 1] = min(next[j] + 1, previous[j + 1] + 1,
                                  previous[j] + (word == observed[j] ? 0 : 1))
            }
            previous = next
        }
        return Agreement(editDistance: previous[observed.count], referenceWords: expected.count)
    }
    nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), mid = values.count / 2
        return values.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
    nonisolated static func p95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
    nonisolated static func audioURL(relative: String, directory: URL) throws -> URL {
        guard !relative.isEmpty, !(relative as NSString).isAbsolutePath,
              !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) else {
            throw Failure.invalidAudioPath
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.resolvingSymlinksInPath().path == file.path,
              file.path.hasPrefix(root.path + "/"),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw Failure.invalidAudioPath }
        return file
    }
    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    /// The optional loader must be local-only. On newer FluidAudio pass a
    /// closure using AsrModels.loadLocal to preserve that version's semantics.
    /// The default manually loads the existing v3 graph and cannot download.
    static func run(manifestURL: URL, modelDirectory: URL, version: AsrModelVersion = .v3,
                    receiptDirectory: URL, passes: Int = 3, modelLabel: String = "parakeet-v3",
                    maximumElapsedSeconds: Double = 1_200,
                    localModelsLoader: (() async throws -> AsrModels)? = nil) async throws -> URL {
        guard (1...3).contains(passes), maximumElapsedSeconds.isFinite, (1...1_800).contains(maximumElapsedSeconds),
              modelLabel.count <= 160 else { throw Failure.invalidBounds }
        let handle = try FileHandle(forReadingFrom: manifestURL)
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        try handle.close()
        guard data.count <= 16 * 1024 * 1024 else { throw Failure.invalidManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schema_version == 1, (1...24).contains(manifest.clips.count),
              manifest.clips.allSatisfy({ $0.duration_seconds.isFinite && $0.duration_seconds > 0 && $0.duration_seconds <= 300 }),
              manifest.clips.reduce(0, { $0 + $1.duration_seconds }) <= 600 else { throw Failure.invalidManifest }
        guard manifest.clips.allSatisfy({ $0.local_audio != nil }) else { throw Failure.noMaterializedAudio }
        let files = try manifest.clips.map { try audioURL(relative: $0.local_audio!, directory: manifestURL.deletingLastPathComponent()) }
        var actualDurations: [Double] = []
        for (index, file) in files.enumerated() {
            let audio = try AVAudioFile(forReading: file)
            let rate = audio.processingFormat.sampleRate
            guard rate.isFinite, rate > 0 else { throw Failure.invalidManifest }
            let duration = Double(audio.length) / rate
            guard duration.isFinite, duration > 0, duration <= 300,
                  abs(duration - manifest.clips[index].duration_seconds) < 0.05 else { throw Failure.invalidManifest }
            actualDurations.append(duration)
            if let expected = manifest.clips[index].audio_sha256 {
                guard expected.count == 64 else { throw Failure.invalidManifest }
                let input = try FileHandle(forReadingFrom: file)
                var digest = SHA256()
                do {
                    while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty { digest.update(data: chunk) }
                    try input.close()
                } catch { try? input.close(); throw error }
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected.lowercased() else { throw Failure.invalidManifest }
            }
        }
        guard actualDurations.reduce(0, +) <= 600 else { throw Failure.invalidManifest }
        var peak = residentBytes()
        let loadStart = DispatchTime.now().uptimeNanoseconds
        let models: AsrModels
        let loaderDescription: String
        if let localModelsLoader {
            models = try await localModelsLoader()
            loaderDescription = "Caller-supplied local-only loader"
        } else {
            guard String(describing: version) == "v3" else { throw Failure.incompleteLocalModel }
            let loaded = try loadV3Locally(directory: modelDirectory)
            models = loaded.models
            loaderDescription = "Explicit CoreML files; joint=" + loaded.joint
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let layers = await manager.decoderLayerCount
        let loadMilliseconds = milliseconds(since: loadStart)
        peak = max(peak, residentBytes())
        let warmupStart = DispatchTime.now().uptimeNanoseconds
        var warmupState = TdtDecoderState.make(decoderLayers: layers)
        _ = try await manager.transcribe([Float](repeating: 0, count: 4_800), decoderState: &warmupState, language: nil)
        let warmupMilliseconds = milliseconds(since: warmupStart)
        peak = max(peak, residentBytes())
        var predictions: [Prediction] = []
        var decodeTimes: [Double] = []
        var processingTimes: [Double] = []
        var successful = 0, empty = 0, failed = 0, agreementCalls = 0, referenceWords = 0, edits = 0
        var successfulSeconds = 0.0, successfulDecodeSeconds = 0.0
        var stopped = false
        let benchmarkStart = DispatchTime.now().uptimeNanoseconds
        outer: for pass in 1...passes {
            for (index, clip) in manifest.clips.enumerated() {
                try Task.checkCancellation()
                if milliseconds(since: benchmarkStart) >= maximumElapsedSeconds * 1_000 { stopped = true; break outer }
                let prepareStart = DispatchTime.now().uptimeNanoseconds
                var preprocessing = 0.0, decoding = 0.0
                var decodeStartedAt: UInt64?
                do {
                    let samples = try TranscriptionService.readSamplesAt16kMono(url: files[index])
                    preprocessing = milliseconds(since: prepareStart)
                    // Validate decoded length as well as untrusted manifest duration.
                    guard !samples.isEmpty, samples.count <= 300 * 16_000 else { throw Failure.invalidBounds }
                    let duration = Double(samples.count) / 16_000
                    var state = TdtDecoderState.make(decoderLayers: layers)
                    let decodeStart = DispatchTime.now().uptimeNanoseconds
                    decodeStartedAt = decodeStart
                    let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
                    decoding = milliseconds(since: decodeStart)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    decodeTimes.append(decoding)
                    let comparison: Agreement?
                    if let historical = clip.history?.texts?.raw_asr_text,
                       clip.history?.source == "local_wispr_history_read_only", !text.isEmpty {
                        comparison = agreement(reference: historical, actual: text)
                    } else { comparison = nil }
                    if text.isEmpty { empty += 1 }
                    else {
                        successful += 1
                        successfulSeconds += duration
                        successfulDecodeSeconds += decoding / 1_000
                        if let comparison { agreementCalls += 1; referenceWords += comparison.referenceWords; edits += comparison.editDistance }
                    }
                    predictions.append(Prediction(sourceID: clip.source_id, pass: pass, status: text.isEmpty ? "empty" : "success",
                        text: text, durationSeconds: duration, preprocessingMilliseconds: preprocessing,
                        decodingMilliseconds: decoding, historicalAgreement: comparison))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    failed += 1
                    if let decodeStartedAt {
                        decoding = milliseconds(since: decodeStartedAt)
                        decodeTimes.append(decoding)
                    } else { preprocessing = milliseconds(since: prepareStart) }
                    // No error text or private paths enter either result file.
                    predictions.append(Prediction(sourceID: clip.source_id, pass: pass, status: "failed", text: nil,
                        durationSeconds: clip.duration_seconds, preprocessingMilliseconds: preprocessing,
                        decodingMilliseconds: decoding, historicalAgreement: nil))
                }
                processingTimes.append(milliseconds(since: prepareStart))
                peak = max(peak, residentBytes())
            }
        }
        let receipt = Receipt(modelLabel: modelLabel, version: String(describing: version), localLoader: loaderDescription,
            requestedPasses: passes, selectedClips: manifest.clips.count,
            selectedAudioSeconds: manifest.clips.reduce(0) { $0 + $1.duration_seconds }, attemptedCalls: predictions.count,
            successfulCalls: successful, emptyOutputs: empty, failedCalls: failed, loadMilliseconds: loadMilliseconds,
            warmupMilliseconds: warmupMilliseconds, allCallsMedianDecodeMilliseconds: median(decodeTimes),
            allCallsP95DecodeMilliseconds: p95(decodeTimes),
            allCallsMedianProcessingMilliseconds: median(processingTimes), allCallsP95ProcessingMilliseconds: p95(processingTimes),
            successfulAudioSeconds: successfulSeconds,
            successfulDecodeSeconds: successfulDecodeSeconds,
            successfulRealtimeFactor: successfulDecodeSeconds > 0 ? successfulSeconds / successfulDecodeSeconds : nil,
            historicalAgreementCalls: agreementCalls, historicalReferenceWords: referenceWords, historicalWordEdits: edits,
            historicalDisagreementRate: referenceWords > 0 ? Double(edits) / Double(referenceWords) : nil,
            observedMaxResidentBytes: peak, stoppedForTimeBudget: stopped)
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: receiptDirectory.path)
        let runID = UUID().uuidString
        try writePrivate(predictions, to: receiptDirectory.appendingPathComponent("asr-predictions-\(runID).json"))
        let destination = receiptDirectory.appendingPathComponent("asr-receipt-\(runID).json")
        try writePrivate(receipt, to: destination)
        return destination
    }

    private static func loadV3Locally(directory: URL) throws -> (models: AsrModels, joint: String) {
        let fm = FileManager.default
        let jointName = fm.fileExists(atPath: directory.appendingPathComponent("JointDecisionv3.mlmodelc").path)
            ? "JointDecisionv3.mlmodelc" : "JointDecision.mlmodelc"
        for name in ["Encoder.mlmodelc", "Preprocessor.mlmodelc", "Decoder.mlmodelc", jointName] {
            let folder = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: folder.appendingPathComponent("coremldata.bin").path) else { throw Failure.incompleteLocalModel }
        }
        let vocabularyData = try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        guard vocabularyData.count <= 8 * 1024 * 1024,
              let rawVocabulary = try JSONSerialization.jsonObject(with: vocabularyData) as? [String: String] else {
            throw Failure.incompleteLocalModel
        }
        var vocabulary: [Int: String] = [:]
        for (key, value) in rawVocabulary { if let key = Int(key) { vocabulary[key] = value } }
        guard !vocabulary.isEmpty else { throw Failure.incompleteLocalModel }
        func load(_ name: String, cpuOnly: Bool = false) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = cpuOnly ? .cpuOnly : .cpuAndNeuralEngine
            return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: configuration)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        return (AsrModels(encoder: try load("Encoder.mlmodelc"), preprocessor: try load("Preprocessor.mlmodelc", cpuOnly: true),
            decoder: try load("Decoder.mlmodelc"), joint: try load(jointName), configuration: config,
            vocabulary: vocabulary, version: .v3), jointName)
    }

    private static func writePrivate<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw Failure.outputCreationFailed }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try file.write(contentsOf: data); try file.close() }
        catch { try? file.close(); try? FileManager.default.removeItem(at: destination); throw error }
    }
}
