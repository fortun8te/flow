import Foundation
import CoreML
import FluidAudio

/// Local artifact loading only. Downloading and activation are separate actions.
enum SpeechModelLoader {
    struct Prepared {
        let id: SpeechModelID
        let models: AsrModels
        let manager: AsrManager
        let decoderLayers: Int
    }
    enum Failure: Error { case missingArtifacts, invalidReceipt }

    static func version(for id: SpeechModelID) -> AsrModelVersion {
        switch id {
        case .parakeetV3, .fluidSpeechPro: return .v3
        case .parakeetUltra: return .ultra
        case .phonon2: return .phonon2
        }
    }

    /// The downloader verifies hashes before installing. This inexpensive check
    /// confirms the pinned receipt and sizes, not a new checksum verification.
    static func artifactsPresent(_ descriptor: SpeechModelDescriptor) -> Bool {
        let directory = descriptor.directory.standardizedFileURL
        guard directory.resolvingSymlinksInPath() == directory else { return false }
        let fm = FileManager.default
        let v3Family = descriptor.id == .parakeetV3 || descriptor.id == .fluidSpeechPro
        let joint = v3Family && !fm.fileExists(atPath: directory.appendingPathComponent("JointDecisionv3.mlmodelc").path)
            ? "JointDecision.mlmodelc" : "JointDecisionv3.mlmodelc"
        for component in ["Encoder.mlmodelc", "Decoder.mlmodelc", "Preprocessor.mlmodelc", joint] {
            let data = directory.appendingPathComponent(component).appendingPathComponent("coremldata.bin")
            guard fm.fileExists(atPath: data.path), data.resolvingSymlinksInPath() == data else { return false }
        }
        guard fm.fileExists(atPath: directory.appendingPathComponent("parakeet_vocab.json").path) else { return false }
        if descriptor.id == .parakeetV3 { return true }
        let receipt = directory.appendingPathComponent(".voice-model.json")
        guard let bytes = try? Data(contentsOf: receipt), bytes.count <= 1_048_576,
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              value["modelId"] as? String == descriptor.id.rawValue,
              value["repository"] as? String == descriptor.repository,
              value["revision"] as? String == descriptor.pinnedRevision,
              let entries = value["files"] as? [[String: Any]], !entries.isEmpty else { return false }
        return entries.allSatisfy { entry in
            guard let name = entry["path"] as? String, !name.hasPrefix("/"), !name.contains("\\"),
                  !name.split(separator: "/").contains(".."),
                  let size = entry["size"] as? NSNumber else { return false }
            let file = directory.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath() == file,
                  let attributes = try? fm.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return false }
            return (attributes[.size] as? NSNumber)?.int64Value == size.int64Value
        }
    }

    static func load(_ descriptor: SpeechModelDescriptor) throws -> AsrModels {
        guard artifactsPresent(descriptor) else { throw Failure.missingArtifacts }
        if descriptor.id == .parakeetV3 || descriptor.id == .fluidSpeechPro,
           !FileManager.default.fileExists(atPath: descriptor.directory.appendingPathComponent("JointDecisionv3.mlmodelc").path) {
            return try loadLegacyV3(directory: descriptor.directory)
        }
        return try AsrModels.loadLocal(from: descriptor.directory, version: version(for: descriptor.id),
                                      encoderComputeUnits: .cpuAndNeuralEngine)
    }

    static func prepare(_ descriptor: SpeechModelDescriptor) async throws -> Prepared {
        try Task.checkCancellation()
        let models = try await Task.detached(priority: .utility) { try load(descriptor) }.value
        try Task.checkCancellation()
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let layers = await manager.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)
        _ = try await manager.transcribe([Float](repeating: 0, count: 4_800), decoderState: &state, language: nil)
        try Task.checkCancellation()
        return Prepared(id: descriptor.id, models: models, manager: manager, decoderLayers: layers)
    }

    /// Preserve the user's already-tested cache exactly, including its legacy
    /// joint. Do not silently fetch a replacement joint or rename model files.
    static func loadLegacyV3(directory: URL) throws -> AsrModels {
        let bytes = try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        guard bytes.count <= 8 * 1_048_576,
              let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: String] else { throw Failure.missingArtifacts }
        let vocabulary = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
        guard !vocabulary.isEmpty else { throw Failure.missingArtifacts }
        func component(_ name: String, units: MLComputeUnits = .cpuAndNeuralEngine) throws -> MLModel {
            let config = MLModelConfiguration()
            config.computeUnits = units
            return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: config)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        return AsrModels(encoder: try component("Encoder.mlmodelc"),
                         preprocessor: try component("Preprocessor.mlmodelc", units: .cpuOnly),
                         decoder: try component("Decoder.mlmodelc"), joint: try component("JointDecision.mlmodelc"),
                         configuration: config, vocabulary: vocabulary, version: .v3)
    }
}
