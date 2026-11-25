import Foundation
import Testing
@testable import Voice

@Suite("Fluid Speech Pro is an optional speech model, off by default")
struct SpeechModelFluidProTests {
    private func emptyHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("flow-home-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Parakeet v3 stays the default, so Fluid Speech Pro is never on by itself")
    func defaultIsUnchanged() {
        #expect(SpeechModelCatalog.defaultID == .parakeetV3)
    }

    @Test("Fluid Speech Pro is listed, uses the v3 inputs, and is under 1 GB")
    func listedAndSmall() throws {
        let model = try #require(SpeechModelCatalog.models(homeDirectory: emptyHome()).first { $0.id == .fluidSpeechPro })
        #expect(model.name == "Fluid Speech Pro")
        #expect(model.repository == "FluidVoice-Labs/fluid-speech-pro-coreml")
        #expect(SpeechModelLoader.version(for: .fluidSpeechPro) == .v3)
        #expect((model.requiredDownloadBytes ?? 0) < 1_000_000_000)
    }

    @Test("With no folder installed, Fluid Speech Pro is not present, so the option reads 'not downloaded'")
    func missingFolderIsNotPresent() throws {
        let home = emptyHome()
        let model = try #require(SpeechModelCatalog.models(homeDirectory: home).first { $0.id == .fluidSpeechPro })
        #expect(SpeechModelLoader.artifactsPresent(model) == false)
    }
}
