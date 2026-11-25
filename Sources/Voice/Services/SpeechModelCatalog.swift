import Foundation

/// Stable application identifiers. Runtime enum cases and remote repository
/// names are deliberately not preferences or control-protocol identifiers.
enum SpeechModelID: String, CaseIterable, Codable, Sendable {
    case parakeetV3 = "parakeet-v3"
    case parakeetUltra = "parakeet-ultra"
    case phonon2 = "phonon-2"
    /// Fluid Speech Pro (Core ML). Same inputs and outputs as Parakeet v3. Off unless chosen, and
    /// shows "not downloaded" until its folder is installed. Credit: "Fluid Speech Pro by FluidVoice".
    case fluidSpeechPro = "fluid-speech-pro"
}

struct SpeechModelDescriptor: Identifiable, Equatable, Sendable {
    enum Languages: String, Codable, Sendable {
        case multilingual25
        case english

        var isEnglishOnly: Bool { self == .english }
    }

    enum ComputePolicy: String, Codable, Sendable {
        case cpuAndNeuralEngine
    }

    let id: SpeechModelID
    let name: String
    let languages: Languages
    let repository: String
    /// Nil for the existing baseline cache: its exact source revision has not
    /// been established. Never replace this with a guessed revision.
    let pinnedRevision: String?
    let requiredDownloadBytes: Int64?
    let minimumFluidAudioVersion: String
    let computePolicy: ComputePolicy
    let directory: URL
}

enum SpeechModelCatalog {
    static let defaultID: SpeechModelID = .parakeetV3

    static func models(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SpeechModelDescriptor] {
        let candidateRoot = homeDirectory.appendingPathComponent("Library/Application Support/VOICE/Models", isDirectory: true)
        return [
            SpeechModelDescriptor(
                id: .parakeetV3, name: "Parakeet v3", languages: .multilingual25,
                repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                pinnedRevision: nil, requiredDownloadBytes: nil,
                minimumFluidAudioVersion: "0.14.5", computePolicy: .cpuAndNeuralEngine,
                directory: homeDirectory.appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-v3", isDirectory: true)),
            SpeechModelDescriptor(
                id: .parakeetUltra, name: "Parakeet Ultra", languages: .multilingual25,
                repository: "FluidInference/parakeet-ultra-coreml",
                pinnedRevision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6", requiredDownloadBytes: 632_163_378,
                minimumFluidAudioVersion: "0.18.3", computePolicy: .cpuAndNeuralEngine,
                directory: candidateRoot.appendingPathComponent(SpeechModelID.parakeetUltra.rawValue, isDirectory: true)
                    .appendingPathComponent("95eaa59a39d4394f047a4dc5cce480388a60d1b6", isDirectory: true)),
            SpeechModelDescriptor(
                id: .phonon2, name: "Phonon-2", languages: .english,
                repository: "FluidInference/phonon-2-coreml",
                pinnedRevision: "1702fc22e76f203d5ca464cd5d3ef130a45ce2c0", requiredDownloadBytes: 378_098_390,
                minimumFluidAudioVersion: "0.18.3", computePolicy: .cpuAndNeuralEngine,
                directory: candidateRoot.appendingPathComponent(SpeechModelID.phonon2.rawValue, isDirectory: true)
                    .appendingPathComponent("1702fc22e76f203d5ca464cd5d3ef130a45ce2c0", isDirectory: true)),
            SpeechModelDescriptor(
                id: .fluidSpeechPro, name: "Fluid Speech Pro", languages: .multilingual25,
                repository: "FluidVoice-Labs/fluid-speech-pro-coreml",
                pinnedRevision: nil, requiredDownloadBytes: 652_000_000,
                minimumFluidAudioVersion: "0.18.3", computePolicy: .cpuAndNeuralEngine,
                directory: homeDirectory.appendingPathComponent("Library/Application Support/FluidAudio/Models/fluid-speech-pro", isDirectory: true))
        ]
    }

    static func descriptor(for id: SpeechModelID, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> SpeechModelDescriptor {
        // The typed list above contains every ID. Keep the lookup exhaustive if
        // another model is added rather than allowing arbitrary repository IDs.
        models(homeDirectory: homeDirectory).first { $0.id == id }!
    }
}
