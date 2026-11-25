import Foundation
import Testing
import FluidAudio

/// Explicit, file-only acceptance check. Never captures or plays audio, and
/// loads model files locally without the download API. Private paths come
/// only from the caller's environment and are never included in the receipt.
@Suite("Local speech engine acceptance")
struct LocalASRSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOICE_ASR_SMOKE"] == "1"))
    func savedRecordingProducesText() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = try #require(env["VOICE_ASR_MODEL_DIRECTORY"])
        let audio = try #require(env["VOICE_ASR_AUDIO_FILE"])
        let receipt = try #require(env["VOICE_ASR_RECEIPT"])
        let started = Date()
        let models = try await AsrModels.load(from: URL(fileURLWithPath: model), version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let loaded = Date()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(URL(fileURLWithPath: audio), decoderState: &state, language: nil)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!text.isEmpty)
        let summary: [String: Any] = ["modelLoadSeconds": loaded.timeIntervalSince(started),
            "decodeSeconds": Date().timeIntervalSince(loaded), "outputCharacters": text.count,
            "nonemptyOutput": !text.isEmpty, "microphoneUsed": false, "playbackUsed": false]
        let url = URL(fileURLWithPath: receipt)
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
